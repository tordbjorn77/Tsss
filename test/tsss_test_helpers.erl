%% tsss_test_helpers.erl — Shared test utilities
-module(tsss_test_helpers).

-export([
    start_app/0,
    stop_app/0,
    make_session/0,
    make_paired_sessions/0,
    random_plaintext/0,
    random_plaintext/1
]).

-include_lib("../include/tsss_types.hrl").

start_app() ->
    application:ensure_all_started(crypto),
    application:ensure_all_started(tsss).

stop_app() ->
    application:stop(tsss).

%% Create a new session and return {SessionPid, Info}
make_session() ->
    {ok, Info} = tsss_api:new_session(#{client => self()}),
    Pid = maps:get(pid, Info),
    {Pid, Info}.

%% Create two sessions and complete a full key exchange between them.
%% Returns {{PidA, InfoA}, {PidB, InfoB}}.
make_paired_sessions() ->
    {PidA, InfoA} = make_session(),
    {PidB, InfoB} = make_session(),
    PubA = maps:get(pub_key, InfoA),
    PubB = maps:get(pub_key, InfoB),
    ok = tsss_session:exchange_keys(PidA, PubB),
    ok = tsss_session:exchange_keys(PidB, PubA),
    {{PidA, InfoA}, {PidB, InfoB}}.

random_plaintext() ->
    random_plaintext(rand:uniform(256)).

random_plaintext(Len) ->
    crypto:strong_rand_bytes(Len).
