%% tsss_ttl_server.erl — Centralized TTL timer management
%%
%% All message and session TTL timers are registered here.
%% The kill switch calls cancel_all/0 to stop all pending destruction in O(n).
%% On timer expiry, dispatches to tsss_wipe for the appropriate wipe action.
-module(tsss_ttl_server).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    register_ttl/3,
    cancel_ttl/2,
    cancel_session_timers/1,
    cancel_all/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ETS table: timer_ref -> {type, id, session_id | undefined}
-define(TAB, tsss_ttl_timers).

-record(state, {
    tab :: ets:tid()
}).

%% Timer types:
%%   message — delete envelope by ID
%%   session — kill session by ID
%%   node    — disconnect/wipe a node

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Register a TTL timer.
%%   Type  — message | session | node
%%   Id    — binary() for message/session, node() for node type
%%   TTLms — milliseconds until expiry
-spec register_ttl(message | session | node, term(), pos_integer()) -> ok.
register_ttl(Type, Id, TTLms) ->
    gen_server:cast(?MODULE, {register, Type, Id, TTLms}).

%% Cancel a specific TTL timer.
-spec cancel_ttl(message | session | node, term()) -> ok.
cancel_ttl(Type, Id) ->
    gen_server:cast(?MODULE, {cancel, Type, Id}).

%% Cancel all TTL timers associated with a session ID.
-spec cancel_session_timers(session_id()) -> ok.
cancel_session_timers(SessionId) ->
    gen_server:cast(?MODULE, {cancel_session, SessionId}).

%% Cancel ALL pending TTL timers (used by kill switch).
-spec cancel_all() -> ok.
cancel_all() ->
    gen_server:cast(?MODULE, cancel_all).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    Tab = ets:new(?TAB, [set, protected, named_table, {keypos, 1}]),
    {ok, #state{tab = Tab}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({register, Type, Id, TTLms}, #state{tab = Tab} = State) ->
    Ref = erlang:send_after(TTLms, self(), {ttl_expired, Type, Id}),
    ets:insert(Tab, {Ref, Type, Id}),
    {noreply, State};

handle_cast({cancel, Type, Id}, #state{tab = Tab} = State) ->
    %% Find and cancel all timers matching this type+id
    Matches = ets:match_object(Tab, {'_', Type, Id}),
    [begin
        erlang:cancel_timer(Ref),
        ets:delete(Tab, Ref)
     end || {Ref, _, _} <- Matches],
    {noreply, State};

handle_cast({cancel_session, SessionId}, #state{tab = Tab} = State) ->
    %% Cancel all timers for the given session
    Matches = ets:match_object(Tab, {'_', session, SessionId}),
    MsgMatches = ets:match_object(Tab, {'_', message, '_'}),
    %% We can only cancel session-type entries directly; message timers
    %% don't store their session id, so just cancel the session entries.
    [begin
        erlang:cancel_timer(Ref),
        ets:delete(Tab, Ref)
     end || {Ref, _, _} <- Matches ++ MsgMatches],
    {noreply, State};

handle_cast(cancel_all, #state{tab = Tab} = State) ->
    All = ets:tab2list(Tab),
    [erlang:cancel_timer(Ref) || {Ref, _, _} <- All],
    ets:delete_all_objects(Tab),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ttl_expired, Type, Id}, #state{tab = Tab} = State) ->
    %% Find the timer ref and remove it (timer may have fired after cancel)
    Matches = ets:match_object(Tab, {'_', Type, Id}),
    [ets:delete(Tab, Ref) || {Ref, _, _} <- Matches],
    dispatch_expiry(Type, Id),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================

dispatch_expiry(message, MsgId) ->
    tsss_wipe:wipe_message(MsgId);
dispatch_expiry(session, SessionId) ->
    tsss_wipe:wipe_session(SessionId);
dispatch_expiry(node, NodeName) ->
    tsss_wipe:wipe_node(NodeName).
