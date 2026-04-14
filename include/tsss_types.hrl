%% tsss_types.hrl — Shared types and records for the Tsss system
%% All records are defined here. Changes propagate to every module.

-ifndef(TSSS_TYPES_HRL).
-define(TSSS_TYPES_HRL, true).

%% ===================================================================
%% Type aliases
%% ===================================================================

%% Session identifier: random 256-bit binary (32 bytes), never reused
-type session_id() :: binary().

%% Ephemeral handle: short human-readable token for one session
%% e.g., <<"hawk-7f3a">>. Discarded when session ends.
-type handle() :: binary().

%% Encrypted payload: nonce ++ tag ++ ciphertext (all binary)
-type ciphertext() :: binary().

%% Public key for ECDH (x25519, 32 bytes)
-type pub_key() :: binary().

%% AES-256-GCM key (32 bytes)
-type aes_key() :: binary().

%% Message TTL in milliseconds (0 = no TTL / never expires)
-type ttl_ms() :: non_neg_integer().

%% ===================================================================
%% Records
%% ===================================================================

%% Envelope: the unit of transport between sessions and across nodes
-record(envelope, {
    id          :: binary(),        %% random 16-byte message ID
    from_handle :: handle(),        %% sender's ephemeral handle
    to_handle   :: handle(),        %% recipient's ephemeral handle
    ciphertext  :: ciphertext(),    %% encrypted body (nonce+tag+ct)
    ttl_ms      :: ttl_ms(),        %% 0 = no auto-destruct
    sent_at     :: integer(),       %% erlang:system_time(millisecond)
    routed_via  :: [node()]         %% routing hop audit (for this node)
}).

%% Session state record — held in gen_statem state data
-record(session, {
    id          :: session_id(),
    handle      :: handle(),
    pub_key     :: pub_key(),
    priv_key    :: binary(),        %% ephemeral private key, never leaves session
    peer_pub    :: pub_key() | undefined,
    shared_key  :: aes_key() | undefined,
    created_at  :: integer(),
    session_ttl :: ttl_ms()
}).

%% Leader election message (sent between tsss_election processes)
-record(elect_msg, {
    type    :: election | victory | alive | coordinator,
    from    :: node(),
    term_id :: integer()
}).

%% Registry entry (local ETS cache + result of lookups)
-record(reg_entry, {
    handle  :: handle(),
    node    :: node(),
    pid     :: pid(),
    pub_key :: pub_key(),
    ttl_ms  :: ttl_ms()
}).

%% Wipe command — broadcast to trigger destruction
-record(wipe_cmd, {
    scope     :: session | node | cluster,
    target    :: session_id() | node() | all,
    reason    :: binary(),
    issued_by :: node()
}).

-endif. %% TSSS_TYPES_HRL
