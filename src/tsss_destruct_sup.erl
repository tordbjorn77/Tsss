%% tsss_destruct_sup.erl — Supervisor for destruct/TTL subsystem
-module(tsss_destruct_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 3,
        period    => 30
    },
    Children = [
        #{
            id       => tsss_ttl_server,
            start    => {tsss_ttl_server, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_ttl_server]
        },
        #{
            id       => tsss_wipe,
            start    => {tsss_wipe, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [tsss_wipe]
        }
    ],
    {ok, {SupFlags, Children}}.
