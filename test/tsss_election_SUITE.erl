%% tsss_election_SUITE.erl — Common Test suite for leader election
-module(tsss_election_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    single_node_elects_itself/1,
    election_state_transitions/1
]).

all() -> [
    single_node_elects_itself,
    election_state_transitions
].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(tsss),
    Config.

end_per_suite(_Config) ->
    application:stop(tsss),
    ok.

%% ===================================================================
%% Test cases
%% ===================================================================

single_node_elects_itself(_Config) ->
    %% On a single-node cluster, the node should elect itself leader
    %% Allow time for the election to complete
    timer:sleep(application:get_env(tsss, election_timeout_ms, 5000) + 1000),
    Leader = tsss_election:current_leader(),
    node() = Leader.

election_state_transitions(_Config) ->
    %% Verify the election process reaches a stable state
    State = tsss_election:current_state(),
    true  = lists:member(State, [follower, leader, candidate]),
    %% On a single node it should eventually settle to leader
    timer:sleep(6000),
    leader = tsss_election:current_state().
