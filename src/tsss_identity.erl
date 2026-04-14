%% tsss_identity.erl — Ephemeral identity generation (pure module, no state)
%%
%% All identities are ephemeral: keypairs are generated per session,
%% handles are random short tokens, and nothing is persisted to disk.
-module(tsss_identity).

-export([
    generate/0,
    gen_handle/0,
    gen_session_id/0
]).

-include("tsss_types.hrl").

%% Generate an ephemeral x25519 keypair.
%% Returns {PubKey, PrivKey} — both 32-byte binaries.
%% The PrivKey must remain inside the session process; never share it.
-spec generate() -> {pub_key(), binary()}.
generate() ->
    {PubKey, PrivKey} = crypto:generate_key(ecdh, x25519),
    {PubKey, PrivKey}.

%% Generate a random ephemeral handle of the form <<"word-XXXX">>.
%% e.g., <<"hawk-4a2f">>, <<"lynx-c31b">>.
%% Handles are single-session only; discard on session end.
-spec gen_handle() -> handle().
gen_handle() ->
    Words = [<<"fox">>, <<"hawk">>, <<"lynx">>, <<"wolf">>, <<"bear">>,
             <<"rook">>, <<"pike">>, <<"wren">>, <<"crow">>, <<"ibis">>,
             <<"kite">>, <<"vole">>, <<"mink">>, <<"puma">>, <<"kudu">>],
    Word   = lists:nth(rand:uniform(length(Words)), Words),
    Suffix = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(2))),
    <<Word/binary, $-, Suffix/binary>>.

%% Generate a 256-bit (32-byte) random session identifier.
-spec gen_session_id() -> session_id().
gen_session_id() ->
    crypto:strong_rand_bytes(32).
