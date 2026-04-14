%% tsss_crypto.erl — All cryptographic operations (pure module, no state)
%%
%% Primitives:
%%   Key exchange : ECDH x25519
%%   Key derivation: HKDF-SHA256 (manual extract+expand)
%%   Encryption  : AES-256-GCM (authenticated encryption)
%%
%% Every function in this module is pure (deterministic given same inputs,
%% or random only where explicitly documented).
-module(tsss_crypto).

-export([
    compute_shared_secret/2,
    derive_session_key/2,
    encrypt/2,
    decrypt/2,
    gen_nonce/0,
    hmac/2
]).

-include("tsss_types.hrl").

%% ===================================================================
%% Key Exchange
%% ===================================================================

%% Perform ECDH key agreement using x25519.
%%
%%   MyPrivKey   — our ephemeral private key (32 bytes)
%%   TheirPubKey — peer's public key (32 bytes)
%%
%% Returns a 32-byte shared secret.
%% IMPORTANT: pass the result through derive_session_key/2 before use.
-spec compute_shared_secret(binary(), pub_key()) -> binary().
compute_shared_secret(MyPrivKey, TheirPubKey) ->
    crypto:compute_key(ecdh, TheirPubKey, MyPrivKey, x25519).

%% ===================================================================
%% Key Derivation — HKDF-SHA256
%% ===================================================================

%% Derive a 32-byte AES-256 key from a shared secret using HKDF.
%%
%%   SharedSecret — output of compute_shared_secret/2 (32 bytes)
%%   Salt         — session_id; adds domain separation (32 bytes)
%%
%% HKDF two-step:
%%   Extract: PRK  = HMAC-SHA256(salt, IKM)
%%   Expand : OKM  = HMAC-SHA256(PRK, info || 0x01)
%%
%% The info string "tsss-msg-key-v1" prevents cross-context key reuse.
-spec derive_session_key(binary(), binary()) -> aes_key().
derive_session_key(SharedSecret, Salt) ->
    %% Extract phase
    PRK = crypto:mac(hmac, sha256, Salt, SharedSecret),
    %% Expand phase (single-block: 32 bytes = SHA256 output size)
    Info = <<"tsss-msg-key-v1">>,
    crypto:mac(hmac, sha256, PRK, <<Info/binary, 1>>).

%% ===================================================================
%% Symmetric Encryption — AES-256-GCM
%% ===================================================================

%% Encrypt Plaintext with AES-256-GCM.
%%
%%   Key       — 32-byte derived session key
%%   Plaintext — arbitrary binary
%%
%% Returns: <<Nonce:12/binary, Tag:16/binary, Ciphertext/binary>>
%% A fresh 12-byte random nonce is generated per call.
-spec encrypt(aes_key(), binary()) -> ciphertext().
encrypt(Key, Plaintext) ->
    Nonce = gen_nonce(),
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, Plaintext, <<>>, true
    ),
    <<Nonce:12/binary, Tag:16/binary, Ciphertext/binary>>.

%% Decrypt an AES-256-GCM envelope produced by encrypt/2.
%%
%% Returns {ok, Plaintext} on success,
%%         {error, authentication_failed} if the ciphertext or key is wrong.
-spec decrypt(aes_key(), ciphertext()) -> {ok, binary()} | {error, authentication_failed}.
decrypt(Key, <<Nonce:12/binary, Tag:16/binary, Ciphertext/binary>>) ->
    case crypto:crypto_one_time_aead(
        aes_256_gcm, Key, Nonce, Ciphertext, <<>>, Tag, false
    ) of
        error     -> {error, authentication_failed};
        Plaintext -> {ok, Plaintext}
    end;
decrypt(_Key, _Bad) ->
    {error, authentication_failed}.

%% ===================================================================
%% Utilities
%% ===================================================================

%% Generate a 12-byte cryptographically random nonce.
-spec gen_nonce() -> binary().
gen_nonce() ->
    crypto:strong_rand_bytes(12).

%% HMAC-SHA256 convenience wrapper.
-spec hmac(binary(), binary()) -> binary().
hmac(Key, Data) ->
    crypto:mac(hmac, sha256, Key, Data).
