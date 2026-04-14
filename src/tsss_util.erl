%% tsss_util.erl — General-purpose utilities (no OTP behaviour)
-module(tsss_util).

-export([
    timestamp_ms/0,
    random_bytes/1,
    node_id/0,
    retry/3
]).

%% Returns current time in milliseconds
-spec timestamp_ms() -> integer().
timestamp_ms() ->
    erlang:system_time(millisecond).

%% Generates N cryptographically secure random bytes
-spec random_bytes(pos_integer()) -> binary().
random_bytes(N) ->
    crypto:strong_rand_bytes(N).

%% Returns a deterministic integer ID for this node
-spec node_id() -> non_neg_integer().
node_id() ->
    erlang:phash2(node(), 16#FFFFFFFF).

%% Retry Fun up to MaxAttempts times with exponential backoff.
%% Fun must return {ok, _} | {error, _}.
%% Returns last result (success or final error).
-spec retry(fun(() -> term()), non_neg_integer(), pos_integer()) -> term().
retry(Fun, 0, _DelayMs) ->
    Fun();
retry(Fun, MaxAttempts, DelayMs) when MaxAttempts > 0 ->
    case Fun() of
        {ok, _} = Ok ->
            Ok;
        _ ->
            timer:sleep(DelayMs),
            retry(Fun, MaxAttempts - 1, DelayMs * 2)
    end.
