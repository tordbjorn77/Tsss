%% tsss_envelope.erl — Message envelope construction and parsing (pure module)
%%
%% An envelope is the unit of transport in the Tsss system.
%% It carries the encrypted ciphertext and routing metadata.
%% The plaintext is never stored in an envelope — only ciphertext.
-module(tsss_envelope).

-export([
    new/4,
    encode/1,
    decode/1,
    validate/1,
    expired/1
]).

-include("tsss_types.hrl").

%% ===================================================================
%% Construction
%% ===================================================================

%% Create a new envelope.
%%   FromHandle — sender's ephemeral handle
%%   ToHandle   — recipient's ephemeral handle
%%   Ciphertext — output of tsss_crypto:encrypt/2
%%   TTLms      — time-to-live in ms; 0 = no expiry
-spec new(handle(), handle(), ciphertext(), ttl_ms()) -> #envelope{}.
new(FromHandle, ToHandle, Ciphertext, TTLms) ->
    #envelope{
        id          = crypto:strong_rand_bytes(16),
        from_handle = FromHandle,
        to_handle   = ToHandle,
        ciphertext  = Ciphertext,
        ttl_ms      = TTLms,
        sent_at     = erlang:system_time(millisecond),
        routed_via  = [node()]
    }.

%% ===================================================================
%% Serialization
%% ===================================================================

%% Encode envelope to binary for storage or inter-node transport.
-spec encode(#envelope{}) -> binary().
encode(#envelope{} = E) ->
    erlang:term_to_binary(E, [compressed, {minor_version, 2}]).

%% Decode binary back to envelope.
%% Uses 'safe' mode to prevent atom exhaustion from untrusted input.
-spec decode(binary()) -> {ok, #envelope{}} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        #envelope{} = E -> {ok, E};
        _                -> {error, invalid_envelope}
    catch
        error:badarg -> {error, decode_failed};
        _:Reason     -> {error, Reason}
    end.

%% ===================================================================
%% Validation
%% ===================================================================

%% Validate structural integrity of an envelope.
%% Minimum ciphertext size: 12 (nonce) + 16 (tag) + 1 (payload) = 29 bytes.
-spec validate(#envelope{}) -> ok | {error, invalid_envelope}.
validate(#envelope{
    id          = Id,
    from_handle = From,
    to_handle   = To,
    ciphertext  = CT,
    ttl_ms      = TTL,
    sent_at     = At
})
  when is_binary(Id),   byte_size(Id)   =:= 16,
       is_binary(From), byte_size(From) > 0,
       is_binary(To),   byte_size(To)   > 0,
       is_binary(CT),   byte_size(CT)   >= 29,
       is_integer(TTL), TTL >= 0,
       is_integer(At),  At  > 0 ->
    ok;
validate(_) ->
    {error, invalid_envelope}.

%% Check whether a TTL-bearing envelope has already expired.
%% Returns true if expired, false if still valid or has no TTL.
-spec expired(#envelope{}) -> boolean().
expired(#envelope{ttl_ms = 0}) ->
    false;
expired(#envelope{ttl_ms = TTL, sent_at = SentAt}) ->
    erlang:system_time(millisecond) > SentAt + TTL.
