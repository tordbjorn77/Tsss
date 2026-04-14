%% tsss_session_agent.erl — Autonomous agent running alongside each session
%%
%% Responsibilities:
%%   1. Presence heartbeats — keeps the session handle alive in tsss_presence
%%   2. Delivery retry     — retries unacked envelopes with exponential backoff
%%   3. Session monitoring — cleans up on session process death
%%
%% "Agentic" in the sense that it acts independently without being called.
-module(tsss_session_agent).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/2,
    track_envelope/2,
    ack_envelope/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(HEARTBEAT_INTERVAL, 10000).   %% 10 seconds
-define(RETRY_DELAYS, [5000, 15000, 45000]).

-record(state, {
    session_pid   :: pid(),
    handle        :: handle(),
    pending       :: #{binary() => {#envelope{}, [pos_integer()]}}, %% id -> {env, remaining_delays}
    retry_timers  :: #{binary() => reference()},
    heartbeat_ref :: reference()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link(pid(), handle()) -> {ok, pid()}.
start_link(SessionPid, Handle) ->
    gen_server:start_link(?MODULE, {SessionPid, Handle}, []).

%% Register an envelope for delivery tracking / retry
-spec track_envelope(pid(), #envelope{}) -> ok.
track_envelope(AgentPid, Envelope) ->
    gen_server:cast(AgentPid, {track, Envelope}).

%% Acknowledge successful delivery (cancels retry)
-spec ack_envelope(pid(), binary()) -> ok.
ack_envelope(AgentPid, MsgId) ->
    gen_server:cast(AgentPid, {ack, MsgId}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init({SessionPid, Handle}) ->
    %% Monitor the session process — clean up if it dies
    erlang:monitor(process, SessionPid),
    HRef = erlang:send_after(?HEARTBEAT_INTERVAL, self(), heartbeat),
    {ok, #state{
        session_pid   = SessionPid,
        handle        = Handle,
        pending       = #{},
        retry_timers  = #{},
        heartbeat_ref = HRef
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({track, #envelope{id = Id} = Env}, State) ->
    %% Schedule first retry
    [First | Rest] = ?RETRY_DELAYS,
    Ref = erlang:send_after(First, self(), {retry, Id}),
    Pending2 = maps:put(Id, {Env, Rest}, State#state.pending),
    Timers2  = maps:put(Id, Ref, State#state.retry_timers),
    {noreply, State#state{pending = Pending2, retry_timers = Timers2}};

handle_cast({ack, MsgId}, State) ->
    State2 = cancel_retry(MsgId, State),
    {noreply, State2};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(heartbeat, #state{handle = Handle} = State) ->
    %% Send presence heartbeat to keep handle registered
    tsss_presence:heartbeat(Handle),
    HRef = erlang:send_after(?HEARTBEAT_INTERVAL, self(), heartbeat),
    {noreply, State#state{heartbeat_ref = HRef}};

handle_info({retry, MsgId}, #state{pending = Pending} = State) ->
    case maps:get(MsgId, Pending, undefined) of
        undefined ->
            %% Already acked or dropped
            {noreply, State};
        {_Env, []} ->
            %% No more retries — give up, notify session
            State#state.session_pid ! {delivery_failed, MsgId},
            Pending2 = maps:remove(MsgId, Pending),
            Timers2  = maps:remove(MsgId, State#state.retry_timers),
            {noreply, State#state{pending = Pending2, retry_timers = Timers2}};
        {Env, [NextDelay | RestDelays]} ->
            %% Retry routing
            tsss_router:route(Env),
            Ref = erlang:send_after(NextDelay, self(), {retry, MsgId}),
            Pending2 = maps:put(MsgId, {Env, RestDelays}, Pending),
            Timers2  = maps:put(MsgId, Ref, State#state.retry_timers),
            {noreply, State#state{pending = Pending2, retry_timers = Timers2}}
    end;

handle_info({'DOWN', _Ref, process, SessionPid, _Reason},
            #state{session_pid = SessionPid} = State) ->
    %% Session process died — clean up pending retries and stop
    [erlang:cancel_timer(R) || R <- maps:values(State#state.retry_timers)],
    erlang:cancel_timer(State#state.heartbeat_ref),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal helpers
%% ===================================================================

cancel_retry(MsgId, State) ->
    case maps:get(MsgId, State#state.retry_timers, undefined) of
        undefined -> State;
        Ref ->
            erlang:cancel_timer(Ref),
            State#state{
                pending      = maps:remove(MsgId, State#state.pending),
                retry_timers = maps:remove(MsgId, State#state.retry_timers)
            }
    end.
