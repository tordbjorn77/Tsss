%% tsss_cluster.erl — Cluster membership registry
%%
%% Maintains an authoritative view of which nodes are in the cluster
%% and what the current leader is. Uses pg for group management.
%% This is the single source of truth for membership state.
-module(tsss_cluster).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    node_joined/1,
    node_left/1,
    members/0,
    set_leader/1,
    get_leader/0,
    is_leader/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CLUSTER_GROUP, tsss_cluster_members).

-record(state, {
    members     :: #{node() => #{joined_at := integer(), status := up | degraded}},
    pg_scope    :: atom(),
    leader_node :: node() | undefined
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Called by tsss_node_mon when a new node connects.
-spec node_joined(node()) -> ok.
node_joined(Node) ->
    gen_server:cast(?MODULE, {node_joined, Node}).

%% Called by tsss_node_mon when a node disconnects.
-spec node_left(node()) -> ok.
node_left(Node) ->
    gen_server:cast(?MODULE, {node_left, Node}).

%% Return the list of known cluster member nodes.
-spec members() -> [node()].
members() ->
    gen_server:call(?MODULE, members).

%% Set the current leader (called by tsss_election on victory).
-spec set_leader(node()) -> ok.
set_leader(LeaderNode) ->
    gen_server:cast(?MODULE, {set_leader, LeaderNode}).

%% Return the current leader node.
-spec get_leader() -> node() | undefined.
get_leader() ->
    gen_server:call(?MODULE, get_leader).

%% Return true if this node is the current leader.
-spec is_leader() -> boolean().
is_leader() ->
    get_leader() =:= node().

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    Scope = application:get_env(tsss, registry_pg_scope, tsss_pg),
    %% Register this node in the cluster members group
    pg:join(Scope, ?CLUSTER_GROUP, self()),
    Members = #{node() => #{joined_at => erlang:system_time(millisecond), status => up}},
    {ok, #state{
        members     = Members,
        pg_scope    = Scope,
        leader_node = undefined
    }}.

handle_call(members, _From, #state{members = M} = State) ->
    {reply, maps:keys(M), State};

handle_call(get_leader, _From, #state{leader_node = L} = State) ->
    {reply, L, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({node_joined, Node}, #state{members = M} = State) ->
    NewEntry = #{joined_at => erlang:system_time(millisecond), status => up},
    NewM = maps:put(Node, NewEntry, M),
    %% Notify election subsystem that membership changed
    notify_election({node_joined, Node}),
    {noreply, State#state{members = NewM}};

handle_cast({node_left, Node}, #state{members = M, leader_node = Leader} = State) ->
    NewM = case maps:get(Node, M, undefined) of
        undefined -> M;
        Entry     -> maps:put(Node, Entry#{status => degraded}, M)
    end,
    %% If the leader left, notify election to trigger re-election
    NewLeader = case Leader of
        Node -> undefined;
        _    -> Leader
    end,
    notify_election({node_left, Node}),
    {noreply, State#state{members = NewM, leader_node = NewLeader}};

handle_cast({set_leader, LeaderNode}, State) ->
    {noreply, State#state{leader_node = LeaderNode}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{pg_scope = Scope} = _State) ->
    pg:leave(Scope, ?CLUSTER_GROUP, self()),
    ok.

%% ===================================================================
%% Internal helpers
%% ===================================================================

notify_election(Event) ->
    case whereis(tsss_election) of
        undefined -> ok;
        Pid       -> gen_statem:cast(Pid, {cluster_event, Event})
    end.
