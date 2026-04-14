%% tsss_election.erl — Bully Algorithm leader election (gen_statem)
%%
%% States:
%%   follower  — normal state; watches for leader heartbeats
%%   candidate — election in progress; waiting for responses from higher nodes
%%   leader    — this node is the elected leader; sends heartbeats
%%
%% Protocol messages (sent as gen_statem casts):
%%   {election, FromNode, TermId}    — "I'm starting an election"
%%   {alive, FromNode, TermId}       — "I'm higher priority; back off"
%%   {victory, FromNode, TermId}     — "I won; I am the new leader"
%%   {coordinator, FromNode, TermId} — periodic heartbeat from the leader
%%
%% Priority: deterministic hash of node name. Higher hash = higher priority.
%% Configurable via {node_priorities, #{node() => integer()}} in sys.config.
%%
%% Quorum: a candidate only declares victory if no higher-priority node
%% responds, preventing a minority partition from electing a false leader.
-module(tsss_election).
-behaviour(gen_statem).

-include("tsss_types.hrl").

-export([
    start_link/0,
    %% External events
    recv_election/2,
    recv_alive/2,
    recv_victory/2,
    recv_coordinator/2,
    %% Introspection
    current_leader/0,
    current_state/0
]).

-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([follower/3, candidate/3, leader/3]).

-record(data, {
    term_id          :: integer(),
    leader_node      :: node() | undefined,
    all_nodes        :: [node()],
    election_tref    :: reference() | undefined,
    heartbeat_tref   :: reference() | undefined
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec recv_election(node(), integer()) -> ok.
recv_election(FromNode, TermId) ->
    gen_statem:cast(?MODULE, {election, FromNode, TermId}).

-spec recv_alive(node(), integer()) -> ok.
recv_alive(FromNode, TermId) ->
    gen_statem:cast(?MODULE, {alive, FromNode, TermId}).

-spec recv_victory(node(), integer()) -> ok.
recv_victory(FromNode, TermId) ->
    gen_statem:cast(?MODULE, {victory, FromNode, TermId}).

-spec recv_coordinator(node(), integer()) -> ok.
recv_coordinator(FromNode, TermId) ->
    gen_statem:cast(?MODULE, {coordinator, FromNode, TermId}).

-spec current_leader() -> node() | undefined.
current_leader() ->
    gen_statem:call(?MODULE, current_leader).

-spec current_state() -> follower | candidate | leader.
current_state() ->
    gen_statem:call(?MODULE, current_state).

%% ===================================================================
%% gen_statem callbacks
%% ===================================================================

callback_mode() -> state_functions.

init([]) ->
    AllNodes = application:get_env(tsss, known_nodes, []),
    Data = #data{
        term_id        = 0,
        leader_node    = undefined,
        all_nodes      = [node() | AllNodes],
        election_tref  = undefined,
        heartbeat_tref = undefined
    },
    %% Start an election immediately on node startup
    {ok, follower, Data, [{next_event, internal, start_election}]}.

%% ===================================================================
%% State: follower
%% ===================================================================

follower(internal, start_election, Data) ->
    {next_state, candidate, Data, [{next_event, internal, begin_election}]};

follower({call, From}, current_leader, #data{leader_node = L} = Data) ->
    {keep_state, Data, [{reply, From, L}]};

follower({call, From}, current_state, Data) ->
    {keep_state, Data, [{reply, From, follower}]};

follower(cast, {coordinator, LeaderNode, TermId}, Data) ->
    %% Received heartbeat from leader — reset our election timeout
    NewData = Data#data{
        leader_node   = LeaderNode,
        term_id       = max(Data#data.term_id, TermId),
        election_tref = reset_election_timer(Data#data.election_tref)
    },
    tsss_cluster:set_leader(LeaderNode),
    {keep_state, NewData};

follower(cast, {victory, LeaderNode, TermId}, Data) ->
    NewData = Data#data{
        leader_node   = LeaderNode,
        term_id       = max(Data#data.term_id, TermId),
        election_tref = reset_election_timer(Data#data.election_tref)
    },
    tsss_cluster:set_leader(LeaderNode),
    {keep_state, NewData};

follower(cast, {election, FromNode, TermId}, Data) ->
    %% A lower-priority node is starting an election
    %% If we have higher priority, send alive and start our own election
    case has_higher_priority(node(), FromNode) of
        true ->
            send_alive(FromNode, TermId),
            NewData = Data#data{term_id = max(Data#data.term_id, TermId) + 1},
            {next_state, candidate, NewData, [{next_event, internal, begin_election}]};
        false ->
            %% They have higher priority — just observe
            {keep_state, Data}
    end;

follower(cast, {cluster_event, {node_joined, _Node}}, Data) ->
    %% Update known nodes list
    KnownNodes = application:get_env(tsss, known_nodes, []),
    AllNodes   = lists:usort([node()] ++ nodes() ++ KnownNodes),
    {keep_state, Data#data{all_nodes = AllNodes}};

follower(cast, {cluster_event, {node_left, Node}}, #data{leader_node = Node} = Data) ->
    %% Leader left — start a new election
    {next_state, candidate, Data#data{leader_node = undefined},
     [{next_event, internal, begin_election}]};

follower(cast, {cluster_event, _}, Data) ->
    {keep_state, Data};

follower(info, election_timeout, Data) ->
    %% No heartbeat received within timeout — start election
    {next_state, candidate, Data, [{next_event, internal, begin_election}]};

follower(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% ===================================================================
%% State: candidate
%% ===================================================================

candidate(internal, begin_election, Data) ->
    NewTermId   = Data#data.term_id + 1,
    HigherNodes = higher_priority_nodes(Data#data.all_nodes),

    %% Send election message to all higher-priority nodes
    [send_election(N, NewTermId) || N <- HigherNodes],

    %% Set a timeout: if no 'alive' reply arrives, we win
    TRef = erlang:send_after(election_timeout_ms(), self(), election_timeout),

    %% Cancel any old election timer
    cancel_timer(Data#data.election_tref),

    NewData = Data#data{
        term_id       = NewTermId,
        election_tref = TRef
    },
    {keep_state, NewData};

candidate({call, From}, current_leader, #data{leader_node = L} = Data) ->
    {keep_state, Data, [{reply, From, L}]};

candidate({call, From}, current_state, Data) ->
    {keep_state, Data, [{reply, From, candidate}]};

candidate(cast, {alive, _FromNode, _TermId}, Data) ->
    %% A higher-priority node is alive — step down
    cancel_timer(Data#data.election_tref),
    %% Wait for their victory message
    TRef = erlang:send_after(election_timeout_ms() * 2, self(), election_timeout),
    {next_state, follower, Data#data{election_tref = TRef}};

candidate(cast, {victory, LeaderNode, TermId}, Data) ->
    cancel_timer(Data#data.election_tref),
    NewData = Data#data{
        leader_node   = LeaderNode,
        term_id       = max(Data#data.term_id, TermId),
        election_tref = reset_election_timer(undefined)
    },
    tsss_cluster:set_leader(LeaderNode),
    {next_state, follower, NewData};

candidate(cast, {election, FromNode, TermId}, Data) ->
    %% Another candidate — if we have higher priority, send alive
    case has_higher_priority(node(), FromNode) of
        true -> send_alive(FromNode, TermId);
        false -> ok
    end,
    {keep_state, Data};

candidate(cast, {coordinator, LeaderNode, TermId}, Data) ->
    %% Leader is already active — cancel our candidacy
    cancel_timer(Data#data.election_tref),
    NewData = Data#data{
        leader_node   = LeaderNode,
        term_id       = max(Data#data.term_id, TermId),
        election_tref = reset_election_timer(undefined)
    },
    tsss_cluster:set_leader(LeaderNode),
    {next_state, follower, NewData};

candidate(cast, {cluster_event, _}, Data) ->
    {keep_state, Data};

candidate(info, election_timeout, Data) ->
    %% No 'alive' response received — declare victory
    {next_state, leader, Data, [{next_event, internal, declare_victory}]};

candidate(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% ===================================================================
%% State: leader
%% ===================================================================

leader(internal, declare_victory, #data{all_nodes = AllNodes, term_id = TermId} = Data) ->
    %% Broadcast victory to all nodes
    [send_victory(N, TermId) || N <- AllNodes, N =/= node()],

    %% Tell the local cluster and leader process
    tsss_cluster:set_leader(node()),
    tsss_leader:activate(),

    %% Start sending heartbeats
    TRef = erlang:send_after(heartbeat_ms(), self(), send_heartbeat),

    {keep_state, Data#data{heartbeat_tref = TRef, leader_node = node()}};

leader({call, From}, current_leader, Data) ->
    {keep_state, Data, [{reply, From, node()}]};

leader({call, From}, current_state, Data) ->
    {keep_state, Data, [{reply, From, leader}]};

leader(info, send_heartbeat, #data{all_nodes = AllNodes, term_id = TermId} = Data) ->
    [send_coordinator(N, TermId) || N <- AllNodes, N =/= node()],
    TRef = erlang:send_after(heartbeat_ms(), self(), send_heartbeat),
    {keep_state, Data#data{heartbeat_tref = TRef}};

leader(cast, {election, FromNode, TermId}, #data{term_id = MyTermId} = Data) ->
    case has_higher_priority(FromNode, node()) of
        true ->
            %% A higher-priority node challenged us — step down
            cancel_timer(Data#data.heartbeat_tref),
            tsss_leader:deactivate(),
            send_alive(FromNode, max(TermId, MyTermId)),
            NewData = Data#data{
                heartbeat_tref = undefined,
                leader_node    = undefined
            },
            {next_state, follower, NewData,
             [{next_event, internal, start_election}]};
        false ->
            %% We have higher priority — assert leadership
            send_alive(FromNode, MyTermId),
            {keep_state, Data}
    end;

leader(cast, {coordinator, OtherLeader, OtherTerm}, #data{term_id = MyTerm} = Data) ->
    %% Another leader appeared — resolve by priority
    case has_higher_priority(OtherLeader, node()) of
        true when OtherTerm >= MyTerm ->
            %% Other leader wins
            cancel_timer(Data#data.heartbeat_tref),
            tsss_leader:deactivate(),
            tsss_cluster:set_leader(OtherLeader),
            NewData = Data#data{
                leader_node    = OtherLeader,
                term_id        = OtherTerm,
                heartbeat_tref = reset_election_timer(undefined)
            },
            {next_state, follower, NewData};
        _ ->
            %% We keep leadership
            {keep_state, Data}
    end;

leader(cast, {cluster_event, {node_joined, Node}}, #data{all_nodes = Nodes} = Data) ->
    %% New node joined — add to known nodes and send them a coordinator heartbeat
    NewNodes = lists:usort([Node | Nodes]),
    send_coordinator(Node, Data#data.term_id),
    {keep_state, Data#data{all_nodes = NewNodes}};

leader(cast, {cluster_event, _}, Data) ->
    {keep_state, Data};

leader(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% ===================================================================
%% Standard callbacks
%% ===================================================================

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

%% ===================================================================
%% Internal: message sending
%% ===================================================================

send_election(Node, TermId) ->
    safe_cast(Node, {election, node(), TermId}).

send_alive(Node, TermId) ->
    safe_cast(Node, {alive, node(), TermId}).

send_victory(Node, TermId) ->
    safe_cast(Node, {victory, node(), TermId}).

send_coordinator(Node, TermId) ->
    safe_cast(Node, {coordinator, node(), TermId}).

safe_cast(Node, Msg) when Node =:= node() ->
    gen_statem:cast(?MODULE, Msg);
safe_cast(Node, Msg) ->
    gen_statem:cast({?MODULE, Node}, Msg).

%% ===================================================================
%% Internal: priority and timer helpers
%% ===================================================================

%% Returns true if NodeA has strictly higher election priority than NodeB.
has_higher_priority(NodeA, NodeB) ->
    priority(NodeA) > priority(NodeB).

%% Node priority: check config first, fall back to deterministic hash.
priority(Node) ->
    Priorities = application:get_env(tsss, node_priorities, #{}),
    maps:get(Node, Priorities, erlang:phash2(Node, 16#7FFFFFFF)).

%% Return nodes from AllNodes that have strictly higher priority than us.
higher_priority_nodes(AllNodes) ->
    MyPriority = priority(node()),
    [N || N <- AllNodes, N =/= node(), priority(N) > MyPriority].

election_timeout_ms() ->
    application:get_env(tsss, election_timeout_ms, 5000).

heartbeat_ms() ->
    application:get_env(tsss, election_heartbeat_ms, 2000).

reset_election_timer(OldRef) ->
    cancel_timer(OldRef),
    erlang:send_after(election_timeout_ms(), self(), election_timeout).

cancel_timer(undefined) -> ok;
cancel_timer(Ref)       -> erlang:cancel_timer(Ref).
