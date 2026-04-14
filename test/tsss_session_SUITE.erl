%% tsss_session_SUITE.erl — Common Test suite for session lifecycle
-module(tsss_session_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("../include/tsss_types.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    new_session_generates_keypair/1,
    key_exchange_completes/1,
    session_ttl_kills_session/1,
    kill_wipes_state/1,
    session_crash_not_restarted/1,
    send_and_receive_message/1
]).

all() -> [
    new_session_generates_keypair,
    key_exchange_completes,
    session_ttl_kills_session,
    kill_wipes_state,
    session_crash_not_restarted,
    send_and_receive_message
].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(tsss),
    Config.

end_per_suite(_Config) ->
    application:stop(tsss),
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% ===================================================================
%% Test cases
%% ===================================================================

new_session_generates_keypair(_Config) ->
    {ok, Info} = tsss_api:new_session(),
    PubKey = maps:get(pub_key, Info),
    Handle = maps:get(handle, Info),
    _SID   = maps:get(session_id, Info),
    Pid    = maps:get(pid, Info),

    32   = byte_size(PubKey),
    true = is_binary(Handle),
    true = is_pid(Pid),
    true = is_process_alive(Pid),

    %% Clean up
    tsss_api:wipe_session(Pid).

key_exchange_completes(_Config) ->
    {ok, InfoA} = tsss_api:new_session(),
    {ok, InfoB} = tsss_api:new_session(),
    PidA   = maps:get(pid, InfoA),
    PidB   = maps:get(pid, InfoB),
    PubKeyA = maps:get(pub_key, InfoA),
    PubKeyB = maps:get(pub_key, InfoB),

    ok = tsss_session:exchange_keys(PidA, PubKeyB),
    ok = tsss_session:exchange_keys(PidB, PubKeyA),

    %% After exchange, both sessions should be active (no crash)
    true = is_process_alive(PidA),
    true = is_process_alive(PidB),

    tsss_api:wipe_session(PidA),
    tsss_api:wipe_session(PidB).

session_ttl_kills_session(_Config) ->
    %% Create session with 150ms TTL
    {ok, Info} = tsss_api:new_session(#{ttl_ms => 150}),
    Pid = maps:get(pid, Info),
    true = is_process_alive(Pid),
    %% Wait for TTL to expire
    timer:sleep(400),
    false = is_process_alive(Pid).

kill_wipes_state(_Config) ->
    {ok, Info}  = tsss_api:new_session(),
    Pid    = maps:get(pid, Info),
    Handle = maps:get(handle, Info),

    %% Register key exchange to get to active state
    {ok, InfoB} = tsss_api:new_session(),
    PidB   = maps:get(pid, InfoB),
    ok = tsss_session:exchange_keys(Pid, maps:get(pub_key, InfoB)),
    ok = tsss_session:exchange_keys(PidB, maps:get(pub_key, Info)),

    %% Handle should be in registry now
    timer:sleep(50),
    {ok, _} = tsss_registry:lookup(Handle),

    %% Kill session
    tsss_api:wipe_session(Pid),
    timer:sleep(100),

    %% Session should be dead
    false = is_process_alive(Pid),

    tsss_api:wipe_session(PidB).

session_crash_not_restarted(_Config) ->
    {ok, Info} = tsss_api:new_session(),
    Pid    = maps:get(pid, Info),
    Ref    = erlang:monitor(process, Pid),

    %% Force crash the session
    exit(Pid, kill),

    %% Wait for DOWN message
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 -> ct:fail(session_not_dead)
    end,

    %% Supervisor must NOT have restarted it (temporary child)
    timer:sleep(100),
    false = is_process_alive(Pid).

send_and_receive_message(_Config) ->
    Self = self(),
    {ok, InfoA} = tsss_api:new_session(#{client => Self}),
    {ok, InfoB} = tsss_api:new_session(#{client => Self}),
    PidA = maps:get(pid, InfoA),
    PidB = maps:get(pid, InfoB),
    PubA = maps:get(pub_key, InfoA),
    PubB = maps:get(pub_key, InfoB),
    HandleA = maps:get(handle, InfoA),

    ok = tsss_session:exchange_keys(PidA, PubB),
    ok = tsss_session:exchange_keys(PidB, PubA),

    timer:sleep(50),  %% Let registration complete

    Plaintext = <<"hello from A to B">>,
    ok = tsss_api:send(PidA, maps:get(handle, InfoB), Plaintext, 0),

    %% B should receive the message
    receive
        {tsss_event, {message, HandleA, Plaintext}} ->
            ok
    after 2000 ->
        ct:fail(message_not_received)
    end,

    tsss_api:wipe_session(PidA),
    tsss_api:wipe_session(PidB).
