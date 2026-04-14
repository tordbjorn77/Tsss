%% prop_tsss_crypto.erl — PropEr property-based tests for tsss_crypto
-module(prop_tsss_crypto).

-include_lib("proper/include/proper.hrl").
-include_lib("../include/tsss_types.hrl").

-export([
    prop_encrypt_decrypt_identity/0,
    prop_wrong_key_fails/0,
    prop_different_nonces/0,
    prop_ecdh_symmetric/0
]).

%% AES-256 key: exactly 32 bytes
key() -> binary(32).

%% Arbitrary plaintext (0-1024 bytes)
plaintext() -> binary().

%% ===================================================================
%% Properties
%% ===================================================================

%% Encrypt then decrypt always returns the original plaintext
prop_encrypt_decrypt_identity() ->
    ?FORALL({Key, Plain}, {key(), plaintext()},
        begin
            Cipher = tsss_crypto:encrypt(Key, Plain),
            tsss_crypto:decrypt(Key, Cipher) =:= {ok, Plain}
        end).

%% Decrypting with the wrong key always fails
prop_wrong_key_fails() ->
    ?FORALL({Key1, Key2, Plain}, {key(), key(), plaintext()},
        begin
            case Key1 =:= Key2 of
                true ->
                    %% Skip equal keys — this is fine, just an unusual case
                    true;
                false ->
                    Cipher = tsss_crypto:encrypt(Key1, Plain),
                    tsss_crypto:decrypt(Key2, Cipher) =:= {error, authentication_failed}
            end
        end).

%% Each call to encrypt produces a different ciphertext (nonce randomness)
prop_different_nonces() ->
    ?FORALL({Key, Plain}, {key(), plaintext()},
        begin
            C1 = tsss_crypto:encrypt(Key, Plain),
            C2 = tsss_crypto:encrypt(Key, Plain),
            C1 =/= C2
        end).

%% ECDH is commutative: shared_secret(PrivA, PubB) = shared_secret(PrivB, PubA)
prop_ecdh_symmetric() ->
    ?FORALL(_Seed, integer(),
        begin
            {PubA, PrivA} = tsss_identity:generate(),
            {PubB, PrivB} = tsss_identity:generate(),
            SecretA = tsss_crypto:compute_shared_secret(PrivA, PubB),
            SecretB = tsss_crypto:compute_shared_secret(PrivB, PubA),
            SecretA =:= SecretB
        end).
