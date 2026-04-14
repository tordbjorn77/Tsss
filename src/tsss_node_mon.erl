%% tsss_node_mon.erl — Erlang node connection monitor
%%
%% Subscribes to nodeup/nodedown kernel events and maintains the set of
%% connected cluster nodes. Drives initial cluster join with exponential
%% backoff retries.
%%
%% Design note: dist_auto_connect is disabled in vm.args, so this process
%% is the sole controller of when nodes connect. This is required for the
%% kill switch to truly isolate a node — no automatic reconnection.
-module(tsss_node_mon).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    connected_nodes/0,
    force_disconnect/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(INITIAL_RETRY_MS, 2000).
-define(MAX_RETRIES, 10).

-record(state, {
    known_nodes     :: [node()],
    connected       :: sets:set(node()),
    retry_ref       :: reference() | undefined,
    retry_count     :: non_neg_integer(),
    retry_delay_ms  :: pos_integer()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns the set of currently connected nodes.
-spec connected_nodes() -> [node()].
connected_nodes() ->
    gen_server:call(?MODULE, connected_nodes).

%% Force-disconnect a node (used by kill switch — does not trigger reconnect).
-spec force_disconnect(node()) -> ok.
force_disconnect(NodeName) ->
    gen_server:cast(?MODULE, {force_disconnect, NodeName}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    %% Subscribe to all node up/down events
    ok = net_kernel:monitor_nodes(true, [{node_type, all}]),

    KnownNodes = application:get_env(tsss, known_nodes, []),
    State = #state{
        known_nodes    = KnownNodes,
        connected      = sets:new(),
        retry_ref      = undefined,
        retry_count    = 0,
        retry_delay_ms = ?INITIAL_RETRY_MS
    },
    %% Trigger initial connection attempt
    self() ! connect_nodes,
    {ok, State}.

handle_call(connected_nodes, _From, #state{connected = C} = State) ->
    {reply, sets:to_list(C), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({force_disconnect, NodeName}, #state{connected = C} = State) ->
    erlang:disconnect_node(NodeName),
    {noreply, State#state{connected = sets:del_element(NodeName, C)}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node, _InfoList}, #state{connected = C} = State) ->
    NewC = sets:add_element(Node, C),
    tsss_cluster:node_joined(Node),
    %% Reset retry backoff on successful connection
    {noreply, State#state{
        connected      = NewC,
        retry_count    = 0,
        retry_delay_ms = ?INITIAL_RETRY_MS
    }};

handle_info({nodedown, Node, _InfoList}, #state{connected = C} = State) ->
    NewC = sets:del_element(Node, C),
    tsss_cluster:node_left(Node),
    %% Schedule reconnect attempt
    State2 = schedule_reconnect(State#state{connected = NewC}),
    {noreply, State2};

handle_info(connect_nodes, #state{known_nodes = Known, connected = C} = State) ->
    %% Try to connect to all known nodes not yet connected
    Unconnected = [N || N <- Known,
                        N =/= node(),
                        not sets:is_element(N, C)],
    Results = [{N, net_kernel:connect_node(N)} || N <- Unconnected],
    Failed  = [N || {N, false} <- Results],
    case Failed of
        [] ->
            %% All connected (or nothing to connect to)
            {noreply, State#state{retry_ref = undefined}};
        _ ->
            %% Some failed — schedule retry with backoff
            State2 = schedule_reconnect(State),
            {noreply, State2}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    net_kernel:monitor_nodes(false),
    ok.

%% ===================================================================
%% Internal helpers
%% ===================================================================

schedule_reconnect(#state{retry_count = Count} = State)
  when Count >= ?MAX_RETRIES ->
    %% Give up retrying — cluster may be intentionally partitioned
    State#state{retry_ref = undefined};
schedule_reconnect(#state{retry_delay_ms = Delay, retry_count = Count} = State) ->
    %% Cancel any existing retry timer
    case State#state.retry_ref of
        undefined -> ok;
        OldRef    -> erlang:cancel_timer(OldRef)
    end,
    Ref = erlang:send_after(Delay, self(), connect_nodes),
    %% Exponential backoff: cap at 60 seconds
    NextDelay = min(Delay * 2, 60000),
    State#state{
        retry_ref      = Ref,
        retry_count    = Count + 1,
        retry_delay_ms = NextDelay
    }.
