%% tsss_api.erl — Public API facade (no OTP behaviour, pure function calls)
%%
%% This is the single entry point for all user-facing operations.
%% All state lives in supervised OTP processes; this module only delegates.
-module(tsss_api).

-include("tsss_types.hrl").

-export([
    %% Session lifecycle
    new_session/0,
    new_session/1,
    end_session/1,

    %% Key exchange
    get_my_pubkey/1,
    get_my_handle/1,
    exchange_keys/3,

    %% Messaging
    send/3,
    send/4,
    recv/1,
    recv_blocking/2,

    %% Service discovery
    lookup_handle/1,
    list_handles/0,

    %% Presence
    heartbeat/1,

    %% Destruction
    wipe_session/1,
    wipe_node/0,
    kill_switch/0
]).

%% ===================================================================
%% Session Lifecycle
%% ===================================================================

%% Create a new anonymous session with a random ephemeral handle.
%% Returns #{session_id, handle, pub_key}.
-spec new_session() -> {ok, map()} | {error, term()}.
new_session() ->
    new_session(#{}).

%% Create a session with options:
%%   handle   => binary()  — custom handle (default: random)
%%   ttl_ms   => integer() — session lifetime in ms (default: 0 = indefinite)
%%   client   => pid()     — process to receive {tsss_event, ...} notifications
-spec new_session(map()) -> {ok, map()} | {error, term()}.
new_session(Opts) ->
    SessionId = tsss_identity:gen_session_id(),
    Handle    = maps:get(handle, Opts, tsss_identity:gen_handle()),
    TTL       = maps:get(ttl_ms, Opts, 0),
    Client    = maps:get(client, Opts, undefined),
    {PubKey, PrivKey} = tsss_identity:generate(),
    Session = #session{
        id          = SessionId,
        handle      = Handle,
        pub_key     = PubKey,
        priv_key    = PrivKey,
        peer_pub    = undefined,
        shared_key  = undefined,
        created_at  = erlang:system_time(millisecond),
        session_ttl = TTL
    },
    case tsss_session_sup:start_session(#{session => Session, client => Client}) of
        {ok, Pid} ->
            {ok, #{
                session_id => SessionId,
                handle     => Handle,
                pub_key    => PubKey,
                pid        => Pid
            }};
        {error, _} = Err ->
            Err
    end.

%% End a session gracefully (calls kill/1).
-spec end_session(pid()) -> ok.
end_session(Pid) ->
    tsss_session:kill(Pid, <<"end_session">>).

%% ===================================================================
%% Key Exchange
%% ===================================================================

%% Return our session's public key (to share with peers).
-spec get_my_pubkey(pid()) -> {ok, pub_key()} | {error, term()}.
get_my_pubkey(SessionPid) ->
    tsss_session:get_pub_key(SessionPid).

%% Return our session's ephemeral handle.
-spec get_my_handle(pid()) -> {ok, handle()} | {error, term()}.
get_my_handle(SessionPid) ->
    tsss_session:get_handle(SessionPid).

%% Complete key exchange with a peer.
%%   SessionPid  — our session process
%%   _PeerHandle — peer's handle (for documentation; lookup done separately)
%%   PeerPubKey  — peer's public key obtained via lookup_handle/1
-spec exchange_keys(pid(), handle(), pub_key()) -> ok | {error, term()}.
exchange_keys(SessionPid, _PeerHandle, PeerPubKey) ->
    tsss_session:exchange_keys(SessionPid, PeerPubKey).

%% ===================================================================
%% Messaging
%% ===================================================================

%% Send a plaintext message to a handle (no TTL).
-spec send(pid(), handle(), binary()) -> ok | {error, term()}.
send(SessionPid, ToHandle, Plaintext) ->
    send(SessionPid, ToHandle, Plaintext, 0).

%% Send a plaintext message with a TTL in milliseconds.
%% TTL = 0 means no automatic deletion.
-spec send(pid(), handle(), binary(), ttl_ms()) -> ok | {error, term()}.
send(SessionPid, ToHandle, Plaintext, TTLms) ->
    tsss_session:send_message(SessionPid, ToHandle, Plaintext, TTLms).

%% Non-blocking receive: drain all messages from the session mailbox.
-spec recv(pid()) -> [#envelope{}].
recv(SessionPid) ->
    %% Ask the session for its mailbox pid, then drain
    case get_mailbox(SessionPid) of
        {ok, MailboxPid} -> tsss_mailbox:pop_all(MailboxPid);
        _                -> []
    end.

%% Blocking receive: wait up to TimeoutMs for a message notification.
-spec recv_blocking(pid(), pos_integer()) -> {ok, #envelope{}} | timeout.
recv_blocking(_SessionPid, TimeoutMs) ->
    receive
        {tsss_event, {message, _From, _Plaintext} = Msg} ->
            {ok, Msg}
    after TimeoutMs ->
        timeout
    end.

%% ===================================================================
%% Service Discovery
%% ===================================================================

%% Look up an online handle and return its public key.
-spec lookup_handle(handle()) -> {ok, pub_key()} | {error, not_found}.
lookup_handle(Handle) ->
    case tsss_registry:lookup(Handle) of
        {ok, #reg_entry{pub_key = PubKey}} -> {ok, PubKey};
        {error, _} = Err                   -> Err
    end.

%% List all currently registered handles across the cluster.
-spec list_handles() -> [handle()].
list_handles() ->
    tsss_registry:all_handles().

%% ===================================================================
%% Presence
%% ===================================================================

%% Send a heartbeat to keep the session handle visible in the registry.
%% Call this at least every presence_ttl_ms / 3 milliseconds.
-spec heartbeat(handle()) -> ok.
heartbeat(Handle) ->
    tsss_presence:heartbeat(Handle).

%% ===================================================================
%% Destruction
%% ===================================================================

%% Destroy a single session (wipes key material and unregisters handle).
-spec wipe_session(pid()) -> ok.
wipe_session(SessionPid) ->
    tsss_session:kill(SessionPid, <<"wipe_session">>).

%% Wipe this node: terminate all sessions, clear all ETS tables,
%% disconnect from the cluster.
-spec wipe_node() -> ok.
wipe_node() ->
    tsss_wipe:wipe_node(node()).

%% Kill switch: wipe this node AND broadcast wipe to all cluster nodes.
%% The node will halt after a 500ms grace period.
-spec kill_switch() -> ok.
kill_switch() ->
    tsss_wipe:kill_switch().

%% ===================================================================
%% Internal helpers
%% ===================================================================

get_mailbox(SessionPid) ->
    %% The session process holds the mailbox pid in its state data.
    %% We use a cast/call approach: ask the session for its mailbox.
    try gen_statem:call(SessionPid, get_mailbox, 5000) of
        Result -> Result
    catch
        _:_ -> {error, session_not_found}
    end.
