%% tsss_app.erl — OTP application callback
-module(tsss_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Start the pg scope before any process tries to join groups.
    %% pg must exist before the registry supervisor starts.
    Scope = application:get_env(tsss, registry_pg_scope, tsss_registry),
    pg:start(Scope),
    tsss_sup:start_link().

stop(_State) ->
    ok.
