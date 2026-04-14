%% tsss_router.erl — Message routing across nodes
%%
%% Routing algorithm:
%%   1. Look up recipient handle in registry (ETS fast path first).
%%   2. If found locally: send directly to session process.
%%   3. If found on remote node: send to remote session PID (dist Erlang handles transport).
%%   4. If not found (offline): store in offline mailbox for deferred delivery.
%%
%% The router is stateless — all persistent state lives in tsss_registry/tsss_mailbox.
-module(tsss_router).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    route/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Route an envelope to its destination.
%% Delivery is asynchronous (cast-based). Returns ok immediately.
-spec route(#envelope{}) -> ok.
route(Envelope) ->
    gen_server:cast(?MODULE, {route, Envelope}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({route, Envelope}, State) ->
    do_route(Envelope),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal routing logic
%% ===================================================================

do_route(#envelope{to_handle = ToHandle} = Envelope) ->
    %% Skip expired envelopes
    case tsss_envelope:expired(Envelope) of
        true ->
            ok;
        false ->
            case tsss_registry:lookup(ToHandle) of
                {ok, #reg_entry{pid = Pid}} ->
                    %% Deliver to session (works for both local and remote PIDs)
                    tsss_session:deliver(Pid, Envelope),
                    %% Register message TTL if applicable
                    start_ttl_if_needed(Envelope);
                {error, not_found} ->
                    %% Recipient offline: store for deferred delivery
                    store_offline(Envelope)
            end
    end.

start_ttl_if_needed(#envelope{ttl_ms = 0}) ->
    ok;
start_ttl_if_needed(#envelope{id = Id, ttl_ms = TTL}) ->
    tsss_ttl_server:register_ttl(message, Id, TTL).

store_offline(Envelope) ->
    tsss_mailbox:store_for_handle(Envelope#envelope.to_handle, Envelope).
