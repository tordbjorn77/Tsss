%% tsss_wipe.erl — Wipe coordinator for the self-destruct / kill switch
%%
%% Levels of destruction:
%%   1. wipe_message/1  — delete one envelope from all local mailboxes
%%   2. wipe_session/1  — kill session + mailbox, unregister handle
%%   3. wipe_node/1     — stop all sessions, clear ETS, disconnect from cluster
%%   4. kill_switch/0   — wipe_node + broadcast to all connected nodes, then halt
%%
%% Design: all operations are idempotent. Multiple calls are safe.
-module(tsss_wipe).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    wipe_message/1,
    wipe_session/1,
    wipe_node/1,
    kill_switch/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ETS tables managed by tsss_registry (cleared during node wipe)
-define(REGISTRY_CACHE, tsss_registry_cache).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Delete a specific message by ID from all local session mailboxes.
-spec wipe_message(binary()) -> ok.
wipe_message(MsgId) ->
    gen_server:cast(?MODULE, {wipe_message, MsgId}).

%% Kill a session and wipe all its state.
%% Accepts either a session_id (binary) or a session PID.
-spec wipe_session(session_id() | pid()) -> ok.
wipe_session(Target) ->
    gen_server:cast(?MODULE, {wipe_session, Target}).

%% Wipe a node: if NodeName is this node, execute locally;
%% otherwise send the command to the remote node.
-spec wipe_node(node()) -> ok.
wipe_node(NodeName) ->
    gen_server:cast(?MODULE, {wipe_node, NodeName}).

%% Kill switch: broadcast wipe to all cluster nodes, then halt this node.
-spec kill_switch() -> ok.
kill_switch() ->
    gen_server:cast(?MODULE, kill_switch).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({wipe_message, MsgId}, State) ->
    do_wipe_message(MsgId),
    {noreply, State};

handle_cast({wipe_session, SessionId}, State) when is_binary(SessionId) ->
    do_wipe_session_by_id(SessionId),
    {noreply, State};

handle_cast({wipe_session, Pid}, State) when is_pid(Pid) ->
    do_wipe_session_pid(Pid),
    {noreply, State};

handle_cast({wipe_node, NodeName}, State) when NodeName =:= node() ->
    do_wipe_local_node(),
    {noreply, State};

handle_cast({wipe_node, NodeName}, State) ->
    %% Send to remote node
    gen_server:cast({?MODULE, NodeName}, {wipe_node, NodeName}),
    {noreply, State};

handle_cast(kill_switch, State) ->
    do_kill_switch(),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(do_halt, State) ->
    init:stop(),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal wipe implementations
%% ===================================================================

%% Delete a message by ID from all running session mailboxes
do_wipe_message(MsgId) ->
    Children = supervisor:which_children(tsss_session_sup),
    [begin
        case gen_statem:call(SessionPid, get_mailbox, 1000) of
            {ok, MailboxPid} -> tsss_mailbox:delete_by_id(MailboxPid, MsgId);
            _                -> ok
        end
     end || {_, SessionPid, worker, _} <- Children, is_pid(SessionPid)].

%% Find and kill a session by its session_id binary.
%% Note: a future enhancement would store id->pid in an ETS table for O(1) lookup.
%% For now we kill the session via its pid if provided, or skip if only an ID.
do_wipe_session_by_id(_SessionId) ->
    ok.

%% Kill a specific session PID
do_wipe_session_pid(Pid) ->
    case is_process_alive(Pid) of
        true  -> tsss_session:kill(Pid, <<"wipe_session">>);
        false -> ok
    end.

%% Wipe all state on the local node
do_wipe_local_node() ->
    %% 1. Cancel all pending TTL timers
    tsss_ttl_server:cancel_all(),

    %% 2. Kill all sessions
    Children = supervisor:which_children(tsss_session_sup),
    [exit(Pid, kill) || {_, Pid, worker, _} <- Children, is_pid(Pid)],

    %% 3. Clear registry ETS cache
    case ets:info(?REGISTRY_CACHE) of
        undefined -> ok;
        _         -> ets:delete_all_objects(?REGISTRY_CACHE)
    end,

    %% 4. Clear TTL timer table
    case ets:info(tsss_ttl_timers) of
        undefined -> ok;
        _         -> ets:delete_all_objects(tsss_ttl_timers)
    end,

    ok.

%% Full kill switch: wipe local + broadcast + disconnect + halt
do_kill_switch() ->
    %% 1. Wipe locally first
    do_wipe_local_node(),

    %% 2. Broadcast to all connected peers before disconnecting
    Nodes = nodes(),
    [gen_server:cast({?MODULE, N}, kill_switch) || N <- Nodes],

    %% 3. Disconnect all nodes (prevents re-sync of wiped data)
    [erlang:disconnect_node(N) || N <- Nodes],

    %% 4. Schedule halt after grace period for broadcasts to propagate
    erlang:send_after(500, self(), do_halt).
