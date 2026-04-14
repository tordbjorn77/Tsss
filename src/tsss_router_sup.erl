%% tsss_router_sup.erl — Supervisor for routing subsystem
-module(tsss_router_sup).
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
            id       => tsss_router,
            start    => {tsss_router, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_router]
        }
    ],
    {ok, {SupFlags, Children}}.
