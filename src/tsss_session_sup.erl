%% tsss_session_sup.erl — simple_one_for_one supervisor for sessions
%%
%% Sessions are restart => temporary by design:
%%   - If a session crashes, its ephemeral key material is gone.
%%   - Restarting would create a new identity under the old PID — a security hazard.
%%   - Clients must explicitly create a new session via tsss_api:new_session/0.
-module(tsss_session_sup).
-behaviour(supervisor).

-export([start_link/0, init/1, start_session/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => simple_one_for_one,
        intensity => 100,
        period    => 60
    },
    Child = #{
        id       => tsss_session,
        start    => {tsss_session, start_link, []},
        restart  => temporary,
        shutdown => 5000,
        type     => worker,
        modules  => [tsss_session]
    },
    {ok, {SupFlags, [Child]}}.

-spec start_session(map()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    supervisor:start_child(?MODULE, [Opts]).
