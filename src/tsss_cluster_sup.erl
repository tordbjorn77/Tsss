%% tsss_cluster_sup.erl — Supervisor for cluster subsystem
%%
%% Uses rest_for_one: if tsss_node_mon crashes, tsss_cluster (which
%% depends on it for membership events) also restarts to avoid stale state.
-module(tsss_cluster_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => rest_for_one,
        intensity => 3,
        period    => 30
    },
    Children = [
        #{
            id       => tsss_node_mon,
            start    => {tsss_node_mon, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_node_mon]
        },
        #{
            id       => tsss_cluster,
            start    => {tsss_cluster, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_cluster]
        }
    ],
    {ok, {SupFlags, Children}}.
