%% tsss_demo.erl — Interactive demonstration of the Tsss system
%%
%% Run from the Erlang shell after starting the application:
%%   tsss_demo:run().           — Full send/receive walkthrough
%%   tsss_demo:help().          — Show all demo commands
%%   tsss_demo:ttl_demo().      — Message with self-destruct timer
%%   tsss_demo:wipe_demo().     — Session wipe demonstration
-module(tsss_demo).

-include("tsss_types.hrl").

-export([run/0, help/0, send_receive/0, ttl_demo/0, wipe_demo/0]).

help() ->
    io:format("~n"
              "  tsss_demo:run()           Full demo (key exchange + messaging + wipe)~n"
              "  tsss_demo:send_receive()  Send one message, print on receipt~n"
              "  tsss_demo:ttl_demo()      Send a message with a 3s self-destruct TTL~n"
              "  tsss_demo:wipe_demo()     Demonstrate session wipe and registry cleanup~n"
              "~n").

run() ->
    io:format("~n=== Tsss Demo ===~n~n"),

    io:format("[1/4] Creating two anonymous sessions...~n"),
    {ok, InfoA} = tsss_api:new_session(#{client => self()}),
    {ok, InfoB} = tsss_api:new_session(#{client => self()}),

    PidA    = maps:get(pid,     InfoA),
    PidB    = maps:get(pid,     InfoB),
    HandleA = maps:get(handle,  InfoA),
    HandleB = maps:get(handle,  InfoB),
    PubA    = maps:get(pub_key, InfoA),
    PubB    = maps:get(pub_key, InfoB),

    io:format("  Alice handle : ~s~n", [HandleA]),
    io:format("  Bob   handle : ~s~n", [HandleB]),

    io:format("~n[2/4] Performing ECDH key exchange (x25519)...~n"),
    ok = tsss_api:exchange_keys(PidA, HandleB, PubB),
    ok = tsss_api:exchange_keys(PidB, HandleA, PubA),
    timer:sleep(100),
    io:format("  Shared secrets derived. Private keys remain on process heaps only.~n"),

    io:format("~n[3/4] Alice sends an encrypted message to Bob...~n"),
    Msg = <<"Hello from Alice — this message is encrypted end-to-end.">>,
    ok = tsss_api:send(PidA, HandleB, Msg, 0),
    io:format("  Sent (encrypted AES-256-GCM): ~s~n", [Msg]),

    receive
        {tsss_event, {message, HandleA, Plaintext}} ->
            io:format("  Bob received (decrypted): ~s~n", [Plaintext])
    after 3000 ->
        io:format("  (timeout waiting for message)~n")
    end,

    io:format("~n[4/4] Wiping both sessions (key material destroyed)...~n"),
    tsss_api:wipe_session(PidA),
    tsss_api:wipe_session(PidB),
    timer:sleep(100),
    io:format("  Sessions wiped. Handles unregistered from service discovery.~n"),
    io:format("~n=== Demo complete ===~n~n").

send_receive() ->
    {ok, InfoA} = tsss_api:new_session(#{client => self()}),
    {ok, InfoB} = tsss_api:new_session(#{client => self()}),
    PidA = maps:get(pid, InfoA),
    PidB = maps:get(pid, InfoB),
    ok = tsss_api:exchange_keys(PidA, maps:get(handle, InfoB), maps:get(pub_key, InfoB)),
    ok = tsss_api:exchange_keys(PidB, maps:get(handle, InfoA), maps:get(pub_key, InfoA)),
    timer:sleep(50),
    ok = tsss_api:send(PidA, maps:get(handle, InfoB), <<"ping">>, 0),
    receive
        {tsss_event, {message, _From, Body}} ->
            io:format("Received: ~s~n", [Body])
    after 3000 ->
        io:format("No message received within 3 seconds~n")
    end,
    tsss_api:wipe_session(PidA),
    tsss_api:wipe_session(PidB).

ttl_demo() ->
    io:format("Sending a message with a 3-second self-destruct TTL...~n"),
    {ok, InfoA} = tsss_api:new_session(#{client => self()}),
    {ok, InfoB} = tsss_api:new_session(#{client => self()}),
    PidA = maps:get(pid, InfoA),
    PidB = maps:get(pid, InfoB),
    ok = tsss_api:exchange_keys(PidA, maps:get(handle, InfoB), maps:get(pub_key, InfoB)),
    ok = tsss_api:exchange_keys(PidB, maps:get(handle, InfoA), maps:get(pub_key, InfoA)),
    timer:sleep(50),
    ok = tsss_api:send(PidA, maps:get(handle, InfoB), <<"self-destruct in 3s">>, 3000),
    receive
        {tsss_event, {message, _, Body}} ->
            io:format("Received: ~s~n", [Body]),
            io:format("Waiting 4 seconds for the TTL to fire...~n"),
            timer:sleep(4000),
            io:format("Message TTL has fired. The message no longer exists in memory.~n")
    after 3000 ->
        io:format("Timeout~n")
    end,
    tsss_api:wipe_session(PidA),
    tsss_api:wipe_session(PidB).

wipe_demo() ->
    io:format("Creating session, then wiping it...~n"),
    {ok, Info}   = tsss_api:new_session(),
    {ok, InfoB}  = tsss_api:new_session(),
    Pid    = maps:get(pid, Info),
    PidB   = maps:get(pid, InfoB),
    Handle = maps:get(handle, Info),

    %% Complete key exchange so the handle gets registered
    ok = tsss_api:exchange_keys(Pid,  maps:get(handle, InfoB), maps:get(pub_key, InfoB)),
    ok = tsss_api:exchange_keys(PidB, Handle, maps:get(pub_key, Info)),
    timer:sleep(50),

    io:format("  Session handle : ~s~n", [Handle]),
    io:format("  Process alive  : ~p~n", [is_process_alive(Pid)]),
    io:format("  Registry entry : ~p~n", [tsss_registry:lookup(Handle)]),

    tsss_api:wipe_session(Pid),
    timer:sleep(100),

    io:format("  After wipe:~n"),
    io:format("    Process alive  : ~p~n", [is_process_alive(Pid)]),
    io:format("    Registry entry : ~p~n", [tsss_registry:lookup(Handle)]),
    tsss_api:wipe_session(PidB).
