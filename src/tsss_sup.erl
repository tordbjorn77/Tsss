%% tsss_sup.erl — Root supervisor (one_for_one)
%%
%% Startup order is enforced by child ordering:
%%   cluster → election → registry → destruct → router → sessions → clients
%%
%% Each subsystem is a sub-supervisor, keeping failure isolation clean.
-module(tsss_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 5,
        period    => 10
    },
    Children = [
        sup_child(tsss_cluster_sup),
        sup_child(tsss_election_sup),
        sup_child(tsss_registry_sup),
        sup_child(tsss_destruct_sup),
        sup_child(tsss_router_sup),
        sup_child(tsss_session_sup),
        sup_child(tsss_client_sup)
    ],
    {ok, {SupFlags, Children}}.

sup_child(Module) ->
    #{
        id       => Module,
        start    => {Module, start_link, []},
        restart  => permanent,
        shutdown => infinity,
        type     => supervisor,
        modules  => [Module]
    }.
