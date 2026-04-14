%% tsss_client_sup.erl — simple_one_for_one supervisor for client processes
%% Clients are temporary — they are not restarted on crash.
-module(tsss_client_sup).
-behaviour(supervisor).

-export([start_link/0, init/1, start_client/2]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => simple_one_for_one,
        intensity => 100,
        period    => 60
    },
    Child = #{
        id       => tsss_client,
        start    => {tsss_client, start_link, []},
        restart  => temporary,
        shutdown => 5000,
        type     => worker,
        modules  => [tsss_client]
    },
    {ok, {SupFlags, [Child]}}.

-spec start_client(pid(), pid()) -> {ok, pid()} | {error, term()}.
start_client(SessionPid, OwnerPid) ->
    supervisor:start_child(?MODULE, [SessionPid, OwnerPid]).
