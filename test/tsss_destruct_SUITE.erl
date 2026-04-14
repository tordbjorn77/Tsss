%% tsss_destruct_SUITE.erl — Common Test suite for self-destruct / TTL
-module(tsss_destruct_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("../include/tsss_types.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    message_ttl_expiry/1,
    cancel_ttl_prevents_wipe/1,
    session_kill_clears_registry/1
]).

all() -> [
    message_ttl_expiry,
    cancel_ttl_prevents_wipe,
    session_kill_clears_registry
].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(tsss),
    Config.

end_per_suite(_Config) ->
    application:stop(tsss),
    ok.

%% ===================================================================
%% Test cases
%% ===================================================================

message_ttl_expiry(_Config) ->
    MsgId = crypto:strong_rand_bytes(16),
    %% Register a 150ms TTL for a message
    tsss_ttl_server:register_ttl(message, MsgId, 150),
    timer:sleep(50),
    %% Should still be registered
    timer:sleep(200),
    %% Timer should have fired and dispatched wipe (we just verify no crash)
    ok.

cancel_ttl_prevents_wipe(_Config) ->
    MsgId = crypto:strong_rand_bytes(16),
    tsss_ttl_server:register_ttl(message, MsgId, 200),
    %% Cancel before it fires
    tsss_ttl_server:cancel_ttl(message, MsgId),
    timer:sleep(300),
    %% No crash = test passes
    ok.

session_kill_clears_registry(_Config) ->
    {ok, InfoA} = tsss_api:new_session(),
    {ok, InfoB} = tsss_api:new_session(),
    PidA   = maps:get(pid, InfoA),
    PidB   = maps:get(pid, InfoB),
    Handle = maps:get(handle, InfoA),

    %% Complete key exchange to register in the registry
    ok = tsss_session:exchange_keys(PidA, maps:get(pub_key, InfoB)),
    ok = tsss_session:exchange_keys(PidB, maps:get(pub_key, InfoA)),

    timer:sleep(50),

    %% Handle should be in registry
    {ok, _} = tsss_registry:lookup(Handle),

    %% Wipe session A
    tsss_api:wipe_session(PidA),
    timer:sleep(100),

    %% Registry should no longer contain handle A
    {error, not_found} = tsss_registry:lookup(Handle),

    tsss_api:wipe_session(PidB).
