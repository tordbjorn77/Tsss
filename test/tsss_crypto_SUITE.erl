%% tsss_crypto_SUITE.erl — Common Test suite for tsss_crypto and tsss_identity
-module(tsss_crypto_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("../include/tsss_types.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

%% Test cases
-export([
    encrypt_decrypt_roundtrip/1,
    wrong_key_fails/1,
    nonce_uniqueness/1,
    ecdh_key_agreement/1,
    hkdf_deterministic/1,
    tampered_ciphertext_rejected/1,
    identity_generate_returns_valid_keys/1,
    handle_format/1,
    session_id_length/1
]).

all() -> [
    {group, crypto},
    {group, identity}
].

groups() -> [
    {crypto, [parallel], [
        encrypt_decrypt_roundtrip,
        wrong_key_fails,
        nonce_uniqueness,
        ecdh_key_agreement,
        hkdf_deterministic,
        tampered_ciphertext_rejected
    ]},
    {identity, [parallel], [
        identity_generate_returns_valid_keys,
        handle_format,
        session_id_length
    ]}
].

init_per_suite(Config) ->
    application:ensure_all_started(crypto),
    Config.

end_per_suite(_Config) ->
    ok.

%% ===================================================================
%% Crypto tests
%% ===================================================================

encrypt_decrypt_roundtrip(_Config) ->
    Key       = crypto:strong_rand_bytes(32),
    Plaintext = <<"Hello, anonymous world!">>,
    Ciphertext = tsss_crypto:encrypt(Key, Plaintext),
    {ok, Decrypted} = tsss_crypto:decrypt(Key, Ciphertext),
    Plaintext = Decrypted.

wrong_key_fails(_Config) ->
    Key1 = crypto:strong_rand_bytes(32),
    Key2 = crypto:strong_rand_bytes(32),
    Plaintext  = <<"secret message">>,
    Ciphertext = tsss_crypto:encrypt(Key1, Plaintext),
    {error, authentication_failed} = tsss_crypto:decrypt(Key2, Ciphertext).

nonce_uniqueness(_Config) ->
    Key = crypto:strong_rand_bytes(32),
    Pt  = <<"same plaintext">>,
    %% Encrypt 500 times — nonces must all be unique
    Ciphertexts = [tsss_crypto:encrypt(Key, Pt) || _ <- lists:seq(1, 500)],
    Unique = length(lists:usort(Ciphertexts)),
    500 = Unique.

ecdh_key_agreement(_Config) ->
    {PubA, PrivA} = tsss_identity:generate(),
    {PubB, PrivB} = tsss_identity:generate(),
    SecretA = tsss_crypto:compute_shared_secret(PrivA, PubB),
    SecretB = tsss_crypto:compute_shared_secret(PrivB, PubA),
    %% Both sides must derive the same shared secret
    SecretA = SecretB,
    32 = byte_size(SecretA).

hkdf_deterministic(_Config) ->
    Secret  = crypto:strong_rand_bytes(32),
    Salt    = crypto:strong_rand_bytes(32),
    Key1    = tsss_crypto:derive_session_key(Secret, Salt),
    Key2    = tsss_crypto:derive_session_key(Secret, Salt),
    Key1    = Key2,
    32      = byte_size(Key1).

tampered_ciphertext_rejected(_Config) ->
    Key        = crypto:strong_rand_bytes(32),
    Plaintext  = <<"tamper me if you dare">>,
    Ciphertext = tsss_crypto:encrypt(Key, Plaintext),
    %% Flip the last byte
    Size = byte_size(Ciphertext),
    <<Head:(Size-1)/binary, LastByte>> = Ciphertext,
    Tampered = <<Head/binary, (LastByte bxor 16#FF)>>,
    {error, authentication_failed} = tsss_crypto:decrypt(Key, Tampered).

%% ===================================================================
%% Identity tests
%% ===================================================================

identity_generate_returns_valid_keys(_Config) ->
    {PubKey, PrivKey} = tsss_identity:generate(),
    32 = byte_size(PubKey),
    32 = byte_size(PrivKey).

handle_format(_Config) ->
    Handle = tsss_identity:gen_handle(),
    true   = is_binary(Handle),
    true   = byte_size(Handle) > 4,
    %% Must contain a dash
    true   = binary:match(Handle, <<"-">>) =/= nomatch.

session_id_length(_Config) ->
    Id = tsss_identity:gen_session_id(),
    32 = byte_size(Id).
