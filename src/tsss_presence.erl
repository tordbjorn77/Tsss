%% tsss_presence.erl — TTL-based online presence tracking
%%
%% Every registered handle has a timer. If no heartbeat arrives before
%% the timer fires, the handle is unregistered (simulating dropped connection).
%% Clients must call heartbeat/1 periodically to stay visible.
-module(tsss_presence).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    heartbeat/1,
    start_tracking/1,
    stop_tracking/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    timers  :: #{handle() => reference()},
    ttl_ms  :: pos_integer()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Renew a handle's presence timer (call at least every ttl_ms / 3 ms).
-spec heartbeat(handle()) -> ok.
heartbeat(Handle) ->
    gen_server:cast(?MODULE, {heartbeat, Handle}).

%% Start tracking a new handle with a fresh timer.
-spec start_tracking(handle()) -> ok.
start_tracking(Handle) ->
    gen_server:cast(?MODULE, {start_tracking, Handle}).

%% Stop tracking a handle and cancel its timer.
-spec stop_tracking(handle()) -> ok.
stop_tracking(Handle) ->
    gen_server:cast(?MODULE, {stop_tracking, Handle}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    TTL = application:get_env(tsss, presence_ttl_ms, 30000),
    {ok, #state{timers = #{}, ttl_ms = TTL}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({start_tracking, Handle}, #state{timers = Timers, ttl_ms = TTL} = State) ->
    State2 = cancel_timer(Handle, State),
    Ref = erlang:send_after(TTL, self(), {presence_expired, Handle}),
    {noreply, State2#state{timers = maps:put(Handle, Ref, Timers)}};

handle_cast({heartbeat, Handle}, #state{timers = Timers, ttl_ms = TTL} = State) ->
    case maps:is_key(Handle, Timers) of
        false ->
            %% Not tracking this handle; ignore stale heartbeat
            {noreply, State};
        true ->
            State2 = cancel_timer(Handle, State),
            Ref = erlang:send_after(TTL, self(), {presence_expired, Handle}),
            {noreply, State2#state{timers = maps:put(Handle, Ref, State2#state.timers)}}
    end;

handle_cast({stop_tracking, Handle}, State) ->
    State2 = cancel_timer(Handle, State),
    {noreply, State2};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({presence_expired, Handle}, #state{timers = Timers} = State) ->
    %% Presence TTL fired — unregister the handle
    tsss_registry:unregister(Handle),
    {noreply, State#state{timers = maps:remove(Handle, Timers)}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================

cancel_timer(Handle, #state{timers = Timers} = State) ->
    case maps:get(Handle, Timers, undefined) of
        undefined -> State;
        Ref ->
            erlang:cancel_timer(Ref),
            State#state{timers = maps:remove(Handle, Timers)}
    end.
