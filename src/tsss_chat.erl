%% tsss_chat.erl — Interactive terminal chat client
%%
%% Entry point: tsss_chat:start(PeerNodes) — called from bash via -eval.
%% Runs as a plain blocking loop in the calling process (no gen_server),
%% keeping terminal I/O straightforward.
%%
%% Flow:
%%   1. Silence OTP noise
%%   2. Connect to configured peer nodes
%%   3. Create an ephemeral session (client => self())
%%   4. Self-exchange bootstrap so our handle appears in list_handles/0
%%   5. Auto-discover and exchange keys with online peers
%%   6. Print banner and enter the REPL loop
%%
%% Commands:
%%   /help  /? /peers  /to <handle> <text>  /quit  /q  /wipe
%%   <text>  — broadcast to all key-exchanged peers
-module(tsss_chat).

-export([start/1]).

-define(DISCOVERY_INTERVAL_MS, 5000).
-define(MSG_TTL_MS, 0).

-record(state, {
    session_pid      :: pid(),
    my_handle        :: binary(),
    peer_nodes       :: [node()],
    %% handle => true (exchanged) | false (seen but no pubkey yet)
    peers            :: #{binary() => boolean()},
    last_discover_ms :: integer()
}).

%% ===================================================================
%% Public API
%% ===================================================================

%% Called from bash: tsss_chat:start(['node@ip', ...]).
-spec start([node()]) -> no_return().
start(PeerNodes) ->
    silence_otp_noise(),
    print_line(""),
    connect_peers(PeerNodes),
    {ok, Info} = tsss_api:new_session(#{client => self()}),
    SessionPid = maps:get(pid, Info),
    MyHandle   = maps:get(handle, Info),
    MyPubKey   = maps:get(pub_key, Info),

    %% Bootstrap: exchange_keys transitions init_keyx -> active AND registers
    %% our handle in tsss_registry (pg group). Without this, list_handles/0
    %% on peer nodes never sees us.
    ok = tsss_api:exchange_keys(SessionPid, MyHandle, MyPubKey),

    InitState = #state{
        session_pid      = SessionPid,
        my_handle        = MyHandle,
        peer_nodes       = PeerNodes,
        peers            = #{},
        last_discover_ms = 0
    },
    State1 = discover_and_exchange(InitState),
    print_banner(State1),
    loop(State1).

%% ===================================================================
%% REPL loop
%% ===================================================================

loop(State) ->
    State1 = drain_inbox(State),
    State2 = maybe_discover(State1),
    case io:get_line("You> ") of
        eof ->
            wipe_and_exit(State2);
        {error, _} ->
            wipe_and_exit(State2);
        Line ->
            Trimmed = string:trim(Line, trailing, "\r\n"),
            State3 = handle_input(Trimmed, State2),
            loop(State3)
    end.

handle_input("", State) ->
    State;
handle_input("/quit", State) ->
    wipe_and_exit(State);
handle_input("/q", State) ->
    wipe_and_exit(State);
handle_input("/wipe", State) ->
    print_line("  Wiping session. All key material destroyed."),
    tsss_api:wipe_session(State#state.session_pid),
    timer:sleep(200),
    print_line("  Goodbye."),
    init:stop(),
    State;
handle_input("/peers", State) ->
    print_peers(State),
    State;
handle_input("/help", State) ->
    print_help(),
    State;
handle_input("/?", State) ->
    print_help(),
    State;
handle_input(Line, State) ->
    case Line of
        "/to " ++ Rest ->
            handle_to_command(Rest, State);
        [$/, _ | _] ->
            print_line("  Unknown command. Type /help for a list."),
            State;
        _ ->
            send_to_all(list_to_binary(Line), State),
            State
    end.

handle_to_command(Rest, State) ->
    case string:split(Rest, " ") of
        [Handle, Text] when Text =/= "" ->
            H = list_to_binary(Handle),
            case maps:get(H, State#state.peers, undefined) of
                true ->
                    tsss_api:send(State#state.session_pid, H,
                                  list_to_binary(Text), ?MSG_TTL_MS),
                    State;
                _ ->
                    io:format("  [err] Unknown or not-yet-exchanged peer: ~s~n", [H]),
                    State
            end;
        _ ->
            print_line("  Usage: /to <handle> <message>"),
            State
    end.

%% ===================================================================
%% Peer discovery and key exchange
%% ===================================================================

discover_and_exchange(State) ->
    AllHandles   = tsss_api:list_handles(),
    %% list_handles/0 returns all pg groups in the scope, which includes
    %% internal atoms like tsss_cluster_members — keep only binary handles.
    OtherHandles = [H || H <- AllHandles,
                         is_binary(H),
                         H =/= State#state.my_handle],
    NewPeers = lists:foldl(fun(H, Acc) ->
        case maps:get(H, Acc, not_seen) of
            true ->
                Acc;   %% already exchanged
            _ ->
                case tsss_api:lookup_handle(H) of
                    {ok, PubKey} ->
                        ok = tsss_api:exchange_keys(State#state.session_pid, H, PubKey),
                        io:format("~n  [key-exchange] ~s~n", [H]),
                        maps:put(H, true, Acc);
                    {error, not_found} ->
                        Acc
                end
        end
    end, State#state.peers, OtherHandles),
    Now = erlang:monotonic_time(millisecond),
    State#state{peers = NewPeers, last_discover_ms = Now}.

maybe_discover(State) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - State#state.last_discover_ms > ?DISCOVERY_INTERVAL_MS of
        true  -> discover_and_exchange(State);
        false -> State
    end.

%% ===================================================================
%% Inbox draining — display any queued incoming messages
%% ===================================================================

drain_inbox(State) ->
    receive
        {tsss_event, {message, From, Text}} ->
            io:format("~n  ~s: ~s~n", [From, Text]),
            drain_inbox(State);
        {tsss_event, {session_terminated, _}} ->
            print_line("  [session terminated remotely]"),
            init:stop(),
            State
    after 0 ->
        State
    end.

%% ===================================================================
%% Messaging
%% ===================================================================

send_to_all(Text, State) ->
    Exchanged = [H || {H, true} <- maps:to_list(State#state.peers)],
    case Exchanged of
        [] ->
            print_line("  [no peers] No key-exchanged peers yet. "
                       "Use /peers to check status.");
        _ ->
            [tsss_api:send(State#state.session_pid, H, Text, ?MSG_TTL_MS)
             || H <- Exchanged],
            ok
    end,
    State.

%% ===================================================================
%% Node connection
%% ===================================================================

connect_peers([]) ->
    ok;
connect_peers(PeerNodes) ->
    print_line("  Connecting to peers..."),
    lists:foreach(fun(Node) ->
        case net_kernel:connect_node(Node) of
            true    -> io:format("  [ok] ~s~n", [Node]);
            false   -> io:format("  [--] ~s  (unreachable — will retry on key exchange)~n", [Node]);
            ignored -> io:format("  [--] ~s  (distribution not running)~n", [Node])
        end
    end, PeerNodes),
    %% Brief pause so pg groups can propagate after new connections
    timer:sleep(500).

%% ===================================================================
%% Exit
%% ===================================================================

wipe_and_exit(State) ->
    print_line(""),
    print_line("  Wiping session and exiting..."),
    tsss_api:wipe_session(State#state.session_pid),
    timer:sleep(200),
    print_line("  Goodbye."),
    init:stop(),
    State.

%% ===================================================================
%% Display helpers
%% ===================================================================

print_banner(State) ->
    PeerCount = maps:size(State#state.peers),
    print_line(""),
    print_line("  +------------------------------------------+"),
    print_line("  |  Tsss Encrypted Chat                     |"),
    io:format("  |  Handle : ~s~n", [State#state.my_handle]),
    io:format("  |  Peers  : ~w key-exchanged and ready~n", [PeerCount]),
    print_line("  +------------------------------------------+"),
    print_line("  Type /help for commands. Typing sends to all ready peers."),
    print_line("").

print_peers(State) ->
    case maps:size(State#state.peers) of
        0 ->
            print_line("  No peers discovered yet.");
        _ ->
            print_line("  Online peers:"),
            maps:foreach(fun(H, Exchanged) ->
                Status = case Exchanged of true -> "ready"; false -> "key-pending" end,
                io:format("    ~s  (~s)~n", [H, Status])
            end, State#state.peers)
    end.

print_help() ->
    print_line(""),
    print_line("  Commands:"),
    print_line("    /peers            List known peers and key-exchange status"),
    print_line("    /to <handle> msg  Send a message to one specific peer"),
    print_line("    /quit  /q         Wipe session and exit"),
    print_line("    /wipe             Destroy session keys and exit immediately"),
    print_line("    /help  /?         Show this help"),
    print_line("    <text>            Send to all key-exchanged peers"),
    print_line("").

print_line(S) ->
    io:format("~s~n", [S]).

silence_otp_noise() ->
    error_logger:tty(false),
    %% OTP 21+ structured logger
    catch logger:set_primary_config(level, none).
