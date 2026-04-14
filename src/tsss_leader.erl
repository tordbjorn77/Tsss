%% tsss_leader.erl — Leader role handler
%%
%% Runs on every node but only performs active duties when activate/0 is called.
%% When active, it:
%%   1. Periodically syncs the registry across the cluster
%%   2. Starts the offline mailbox (store-and-forward for offline recipients)
%%   3. Serves as the cluster coordinator for registry reconciliation
%%
%% When deactivate/0 is called (e.g., on re-election), it stops these duties.
-module(tsss_leader).
-behaviour(gen_server).

-export([
    start_link/0,
    activate/0,
    deactivate/0,
    is_active/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SYNC_INTERVAL_MS, 10000).  %% Registry sync every 10 seconds

-record(state, {
    active      :: boolean(),
    sync_tref   :: reference() | undefined,
    offline_pid :: pid() | undefined
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Activate leader duties (called by tsss_election on victory).
-spec activate() -> ok.
activate() ->
    gen_server:cast(?MODULE, activate).

%% Deactivate leader duties (called when stepping down).
-spec deactivate() -> ok.
deactivate() ->
    gen_server:cast(?MODULE, deactivate).

%% Check if this node is currently the active leader.
-spec is_active() -> boolean().
is_active() ->
    gen_server:call(?MODULE, is_active).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, #state{
        active      = false,
        sync_tref   = undefined,
        offline_pid = undefined
    }}.

handle_call(is_active, _From, #state{active = A} = State) ->
    {reply, A, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(activate, #state{active = false} = State) ->
    %% Start offline mailbox for store-and-forward
    {ok, OfflinePid} = tsss_mailbox:start_link_offline(),
    %% Schedule first sync
    TRef = erlang:send_after(?SYNC_INTERVAL_MS, self(), sync_registry),
    {noreply, State#state{
        active      = true,
        sync_tref   = TRef,
        offline_pid = OfflinePid
    }};

handle_cast(activate, State) ->
    %% Already active — idempotent
    {noreply, State};

handle_cast(deactivate, #state{active = true, sync_tref = TRef, offline_pid = OffPid} = State) ->
    cancel_timer(TRef),
    %% Stop offline mailbox
    case OffPid of
        undefined -> ok;
        _         -> exit(OffPid, shutdown)
    end,
    {noreply, State#state{active = false, sync_tref = undefined, offline_pid = undefined}};

handle_cast(deactivate, State) ->
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sync_registry, #state{active = true} = State) ->
    %% Broadcast our local registry handles to all connected nodes
    %% This ensures eventual consistency without a Raft log
    %% pg propagates membership automatically; we trigger a presence heartbeat
    %% for each locally registered handle to refresh remote caches.
    Handles = tsss_registry:all_handles(),
    [tsss_presence:heartbeat(H) || H <- Handles],
    TRef = erlang:send_after(?SYNC_INTERVAL_MS, self(), sync_registry),
    {noreply, State#state{sync_tref = TRef}};

handle_info(sync_registry, State) ->
    %% Not active — skip sync
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================

cancel_timer(undefined) -> ok;
cancel_timer(Ref)       -> erlang:cancel_timer(Ref).
