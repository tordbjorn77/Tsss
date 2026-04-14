%% tsss_session.erl — Per-session gen_statem FSM
%%
%% States:
%%   init_keyx — waiting for peer public key to complete ECDH
%%   active    — session is live; messages can be sent/received
%%   dying     — kill switch triggered; wiping in progress
%%
%% Key design:
%%   - Private key lives only on this process's heap (never shared, never persisted)
%%   - restart => temporary in supervisor (crash = lost session, by design)
%%   - Monitors its own mailbox and agent processes
-module(tsss_session).
-behaviour(gen_statem).

-include("tsss_types.hrl").

-export([
    start_link/1,
    exchange_keys/2,
    send_message/4,
    get_pub_key/1,
    get_handle/1,
    deliver/2,
    kill/1,
    kill/2
]).

-export([callback_mode/0, init/1, terminate/3]).
-export([init_keyx/3, active/3, dying/3]).

-record(data, {
    session     :: #session{},
    mailbox     :: pid() | undefined,
    agent       :: pid() | undefined,
    client      :: pid() | undefined,    %% process to notify on message arrival
    nonce_ctr   :: non_neg_integer()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% Provide peer's public key to complete the key exchange.
-spec exchange_keys(pid(), pub_key()) -> ok | {error, term()}.
exchange_keys(Pid, PeerPubKey) ->
    gen_statem:call(Pid, {exchange_keys, PeerPubKey}).

%% Send an encrypted message to a handle with optional TTL.
-spec send_message(pid(), handle(), binary(), ttl_ms()) -> ok | {error, term()}.
send_message(Pid, ToHandle, Plaintext, TTLms) ->
    gen_statem:call(Pid, {send, ToHandle, Plaintext, TTLms}).

%% Return this session's public key (for registry publication).
-spec get_pub_key(pid()) -> {ok, pub_key()} | {error, term()}.
get_pub_key(Pid) ->
    gen_statem:call(Pid, get_pub_key).

%% Return this session's ephemeral handle.
-spec get_handle(pid()) -> {ok, handle()} | {error, term()}.
get_handle(Pid) ->
    gen_statem:call(Pid, get_handle).

%% Deliver an arriving envelope to this session (called by router).
-spec deliver(pid(), #envelope{}) -> ok.
deliver(Pid, Envelope) ->
    gen_statem:cast(Pid, {recv_envelope, Envelope}).

%% Trigger session self-destruction.
-spec kill(pid()) -> ok.
kill(Pid) -> kill(Pid, <<"kill">>).

-spec kill(pid(), binary()) -> ok.
kill(Pid, Reason) ->
    gen_statem:cast(Pid, {kill, Reason}).

%% ===================================================================
%% gen_statem callbacks
%% ===================================================================

callback_mode() -> state_functions.

init(Opts) ->
    Session = maps:get(session, Opts),
    Client  = maps:get(client, Opts, undefined),
    %% Start session TTL if configured
    case Session#session.session_ttl of
        0   -> ok;
        TTL -> tsss_ttl_server:register_ttl(session, Session#session.id, TTL)
    end,
    Data = #data{
        session   = Session,
        client    = Client,
        nonce_ctr = 0
    },
    {ok, init_keyx, Data}.

%% ===================================================================
%% State: init_keyx
%% ===================================================================

init_keyx({call, From}, {exchange_keys, PeerPubKey}, #data{session = S} = Data) ->
    SharedSecret = tsss_crypto:compute_shared_secret(S#session.priv_key, PeerPubKey),
    SessionKey   = tsss_crypto:derive_session_key(SharedSecret, S#session.id),
    NewSession   = S#session{peer_pub = PeerPubKey, shared_key = SessionKey},

    %% Start mailbox (holds incoming encrypted envelopes)
    {ok, MailboxPid} = tsss_mailbox:start_link(self(), SessionKey),
    erlang:monitor(process, MailboxPid),

    %% Register handle in the distributed registry
    ok = tsss_registry:register(S#session.handle, self(), S#session.pub_key),
    ok = tsss_presence:start_tracking(S#session.handle),

    %% Drain any offline messages that arrived before we registered
    tsss_mailbox:deliver_for_handle(S#session.handle, self()),

    %% Start the autonomous agent
    {ok, AgentPid} = tsss_session_agent:start_link(self(), S#session.handle),
    erlang:monitor(process, AgentPid),

    NewData = Data#data{
        session = NewSession,
        mailbox = MailboxPid,
        agent   = AgentPid
    },
    {next_state, active, NewData, [{reply, From, ok}]};

init_keyx({call, From}, get_pub_key, #data{session = S} = Data) ->
    {keep_state, Data, [{reply, From, {ok, S#session.pub_key}}]};

init_keyx({call, From}, get_handle, #data{session = S} = Data) ->
    {keep_state, Data, [{reply, From, {ok, S#session.handle}}]};

init_keyx(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% ===================================================================
%% State: active
%% ===================================================================

active({call, From}, {send, ToHandle, Plaintext, TTLms}, #data{session = S} = Data) ->
    Ciphertext = tsss_crypto:encrypt(S#session.shared_key, Plaintext),
    Envelope   = tsss_envelope:new(S#session.handle, ToHandle, Ciphertext, TTLms),
    ok = tsss_router:route(Envelope),
    %% Track for retry (agent handles exponential backoff)
    tsss_session_agent:track_envelope(Data#data.agent, Envelope),
    NewData = Data#data{nonce_ctr = Data#data.nonce_ctr + 1},
    {keep_state, NewData, [{reply, From, ok}]};

active({call, From}, get_pub_key, #data{session = S} = Data) ->
    {keep_state, Data, [{reply, From, {ok, S#session.pub_key}}]};

active({call, From}, get_handle, #data{session = S} = Data) ->
    {keep_state, Data, [{reply, From, {ok, S#session.handle}}]};

active({call, From}, get_mailbox, #data{mailbox = Mailbox} = Data) ->
    {keep_state, Data, [{reply, From, {ok, Mailbox}}]};

active(cast, {recv_envelope, Envelope}, #data{mailbox = Mailbox} = Data) ->
    %% Push to mailbox; mailbox will notify our client process
    tsss_mailbox:push(Mailbox, Envelope),
    {keep_state, Data};

active(cast, {kill, Reason}, Data) ->
    {next_state, dying, Data, [{next_event, internal, {do_wipe, Reason}}]};

active(info, {mailbox_message, Envelope}, #data{session = S, client = Client} = Data) ->
    %% Attempt to decrypt and forward to client
    case S#session.shared_key of
        undefined ->
            {keep_state, Data};
        Key ->
            case tsss_crypto:decrypt(Key, Envelope#envelope.ciphertext) of
                {ok, Plaintext} ->
                    notify_client(Client, {message, Envelope#envelope.from_handle, Plaintext}),
                    {keep_state, Data};
                {error, _} ->
                    {keep_state, Data}
            end
    end;

active(info, {delivery_failed, MsgId}, #data{client = Client} = Data) ->
    notify_client(Client, {delivery_failed, MsgId}),
    {keep_state, Data};

active(info, {'DOWN', _Ref, process, _Pid, _Reason}, Data) ->
    %% A linked child (mailbox/agent) died — transition to dying
    {next_state, dying, Data, [{next_event, internal, {do_wipe, <<"linked_process_died">>}}]};

active(info, session_ttl_expired, Data) ->
    {next_state, dying, Data, [{next_event, internal, {do_wipe, <<"ttl_expired">>}}]};

active(_EventType, _Event, Data) ->
    {keep_state, Data}.

%% ===================================================================
%% State: dying
%% ===================================================================

dying(internal, {do_wipe, _Reason}, #data{session = S, mailbox = Mailbox} = Data) ->
    %% Unregister from service discovery
    tsss_registry:unregister(S#session.handle),
    tsss_presence:stop_tracking(S#session.handle),
    %% Wipe mailbox
    case Mailbox of
        undefined -> ok;
        _         -> tsss_mailbox:wipe(Mailbox)
    end,
    %% Cancel all TTL timers for this session
    tsss_ttl_server:cancel_session_timers(S#session.id),
    {stop, normal, Data};

dying(_EventType, _Event, Data) ->
    {keep_state, Data}.

terminate(_Reason, _State, _Data) ->
    ok.

%% ===================================================================
%% Internal helpers
%% ===================================================================

notify_client(undefined, _Msg) -> ok;
notify_client(Pid, Msg)        -> Pid ! {tsss_event, Msg}.
