%% tsss_registry_sup.erl — Supervisor for registry subsystem
-module(tsss_registry_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 5,
        period    => 30
    },
    Children = [
        #{
            id       => tsss_registry,
            start    => {tsss_registry, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_registry]
        },
        #{
            id       => tsss_presence,
            start    => {tsss_presence, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_presence]
        }
    ],
    {ok, {SupFlags, Children}}.
