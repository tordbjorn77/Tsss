%% tsss_election_sup.erl — Supervisor for election subsystem
%%
%% Both tsss_election and tsss_leader start on every node.
%% tsss_leader is idle until tsss_election calls activate/0 on victory.
-module(tsss_election_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 60
    },
    Children = [
        #{
            id       => tsss_election,
            start    => {tsss_election, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_election]
        },
        #{
            id       => tsss_leader,
            start    => {tsss_leader, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_leader]
        }
    ],
    {ok, {SupFlags, Children}}.
