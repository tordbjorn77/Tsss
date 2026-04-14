%% tsss_client.erl — Client handle (one per connected user/process)
%%
%% Wraps a session for an external caller. Monitors the session process
%% and notifies the caller if the session dies unexpectedly.
%% Also relays incoming message notifications from the session.
-module(tsss_client).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/2,
    get_session_pid/1,
    stop/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    session_pid :: pid(),
    owner       :: pid()   %% process to notify on session events
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(pid(), pid()) -> {ok, pid()}.
start_link(SessionPid, OwnerPid) ->
    gen_server:start_link(?MODULE, {SessionPid, OwnerPid}, []).

-spec get_session_pid(pid()) -> {ok, pid()}.
get_session_pid(ClientPid) ->
    gen_server:call(ClientPid, get_session_pid).

-spec stop(pid()) -> ok.
stop(ClientPid) ->
    gen_server:stop(ClientPid).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init({SessionPid, OwnerPid}) ->
    erlang:monitor(process, SessionPid),
    erlang:monitor(process, OwnerPid),
    {ok, #state{session_pid = SessionPid, owner = OwnerPid}}.

handle_call(get_session_pid, _From, #state{session_pid = Pid} = State) ->
    {reply, {ok, Pid}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, Reason},
            #state{session_pid = Pid, owner = Owner} = State) ->
    Owner ! {tsss_event, {session_terminated, Reason}},
    {stop, normal, State};

handle_info({'DOWN', _Ref, process, Pid, _Reason},
            #state{owner = Pid} = State) ->
    %% Owner died — shut down gracefully
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
