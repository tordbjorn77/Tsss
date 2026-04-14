%% tsss_mailbox.erl — Per-session encrypted inbox + offline store-and-forward
%%
%% Two operational modes:
%%   session  — started by tsss_session; decrypts arriving envelopes for a client
%%   offline  — leader-managed; holds envelopes for offline recipients until they connect
-module(tsss_mailbox).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/2,           %% session mode
    start_link_offline/0,   %% offline store-and-forward mode
    push/2,
    pop/1,
    pop_all/1,
    store_for_handle/2,     %% offline mode: store for unregistered handle
    deliver_for_handle/2,   %% offline mode: drain stored messages for handle
    delete_by_id/2,
    wipe/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_DEPTH, 1000).

-record(state, {
    mode        :: session | offline,
    session_pid :: pid() | undefined,
    messages    :: queue:queue(#envelope{}),
    depth       :: non_neg_integer(),
    max_depth   :: pos_integer(),
    %% offline mode: handle -> queue of envelopes
    offline_store :: #{handle() => queue:queue(#envelope{})} | undefined
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(pid(), aes_key()) -> {ok, pid()}.
start_link(SessionPid, _SessionKey) ->
    gen_server:start_link(?MODULE, {session, SessionPid}, []).

-spec start_link_offline() -> {ok, pid()}.
start_link_offline() ->
    gen_server:start_link({local, tsss_mailbox_offline}, ?MODULE, {offline}, []).

-spec push(pid(), #envelope{}) -> ok.
push(Pid, Envelope) ->
    gen_server:cast(Pid, {push, Envelope}).

-spec pop(pid()) -> {ok, #envelope{}} | empty.
pop(Pid) ->
    gen_server:call(Pid, pop).

-spec pop_all(pid()) -> [#envelope{}].
pop_all(Pid) ->
    gen_server:call(Pid, pop_all).

-spec store_for_handle(handle(), #envelope{}) -> ok.
store_for_handle(Handle, Envelope) ->
    case whereis(tsss_mailbox_offline) of
        undefined -> ok;  %% offline store not started yet (non-leader node)
        Pid       -> gen_server:cast(Pid, {store_offline, Handle, Envelope})
    end.

-spec deliver_for_handle(handle(), pid()) -> ok.
deliver_for_handle(Handle, SessionPid) ->
    case whereis(tsss_mailbox_offline) of
        undefined -> ok;
        Pid       -> gen_server:cast(Pid, {deliver_offline, Handle, SessionPid})
    end.

-spec delete_by_id(pid(), binary()) -> ok.
delete_by_id(Pid, MsgId) ->
    gen_server:cast(Pid, {delete_by_id, MsgId}).

-spec wipe(pid()) -> ok.
wipe(Pid) ->
    gen_server:cast(Pid, wipe).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init({session, SessionPid}) ->
    MaxDepth = application:get_env(tsss, mailbox_max_depth, ?MAX_DEPTH),
    {ok, #state{
        mode        = session,
        session_pid = SessionPid,
        messages    = queue:new(),
        depth       = 0,
        max_depth   = MaxDepth
    }};
init({offline}) ->
    {ok, #state{
        mode          = offline,
        messages      = queue:new(),
        depth         = 0,
        max_depth     = ?MAX_DEPTH * 10,
        offline_store = #{}
    }}.

handle_call(pop, _From, #state{messages = Q, depth = D} = State) ->
    case queue:out(Q) of
        {empty, _} ->
            {reply, empty, State};
        {{value, Envelope}, Q2} ->
            {reply, {ok, Envelope}, State#state{messages = Q2, depth = D - 1}}
    end;

handle_call(pop_all, _From, #state{messages = Q} = State) ->
    Items = queue:to_list(Q),
    {reply, Items, State#state{messages = queue:new(), depth = 0}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({push, Envelope}, #state{mode = session, depth = D, max_depth = Max} = State) ->
    if D >= Max ->
        %% Drop oldest to make room (mailbox overflow policy)
        {_, Q2} = queue:out(State#state.messages),
        Q3 = queue:in(Envelope, Q2),
        {noreply, State#state{messages = Q3}};
    true ->
        Q2 = queue:in(Envelope, State#state.messages),
        %% Notify the session process a message arrived
        State#state.session_pid ! {mailbox_message, Envelope},
        {noreply, State#state{messages = Q2, depth = D + 1}}
    end;

handle_cast({store_offline, Handle, Envelope}, #state{mode = offline, offline_store = Store} = State) ->
    Queue  = maps:get(Handle, Store, queue:new()),
    Queue2 = queue:in(Envelope, Queue),
    {noreply, State#state{offline_store = maps:put(Handle, Queue2, Store)}};

handle_cast({deliver_offline, Handle, SessionPid}, #state{mode = offline, offline_store = Store} = State) ->
    case maps:get(Handle, Store, undefined) of
        undefined ->
            {noreply, State};
        Queue ->
            Envelopes = queue:to_list(Queue),
            [SessionPid ! {mailbox_message, E} || E <- Envelopes],
            {noreply, State#state{offline_store = maps:remove(Handle, Store)}}
    end;

handle_cast({delete_by_id, MsgId}, #state{messages = Q} = State) ->
    List     = queue:to_list(Q),
    Filtered = [E || E <- List, E#envelope.id =/= MsgId],
    NewD     = length(Filtered),
    {noreply, State#state{messages = queue:from_list(Filtered), depth = NewD}};

handle_cast(wipe, #state{mode = session} = State) ->
    {noreply, State#state{messages = queue:new(), depth = 0}};

handle_cast(wipe, #state{mode = offline} = State) ->
    {noreply, State#state{messages = queue:new(), depth = 0, offline_store = #{}}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
