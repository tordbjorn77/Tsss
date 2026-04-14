%% tsss_registry.erl — Distributed handle registry using pg + ETS cache
%%
%% Each registered session joins a pg group named by its handle.
%% pg propagates group membership to all connected nodes automatically.
%% A local ETS table caches entries for O(1) local lookups.
%%
%% Why pg over global:
%%   global uses locking that can deadlock under network partition.
%%   pg is lock-free and eventually consistent — safe under partition.
-module(tsss_registry).
-behaviour(gen_server).

-include("tsss_types.hrl").

-export([
    start_link/0,
    register/3,
    unregister/1,
    lookup/1,
    all_handles/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CACHE_TAB, tsss_registry_cache).

-record(state, {
    scope :: atom()
}).

%% ===================================================================
%% API
%% ===================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Register a handle for a session process with its public key.
-spec register(handle(), pid(), pub_key()) -> ok.
register(Handle, SessionPid, PubKey) ->
    gen_server:call(?MODULE, {register, Handle, SessionPid, PubKey}).

%% Unregister a handle (called on session death or kill switch).
-spec unregister(handle()) -> ok.
unregister(Handle) ->
    gen_server:cast(?MODULE, {unregister, Handle}).

%% Look up a handle. Fast path: ETS cache. Fallback: pg query.
-spec lookup(handle()) -> {ok, #reg_entry{}} | {error, not_found}.
lookup(Handle) ->
    case ets:lookup(?CACHE_TAB, Handle) of
        [Entry] ->
            {ok, Entry};
        [] ->
            lookup_remote(Handle)
    end.

%% Return all currently registered handles cluster-wide.
-spec all_handles() -> [handle()].
all_handles() ->
    Scope = application:get_env(tsss, registry_pg_scope, tsss_registry),
    pg:which_groups(Scope).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    Scope = application:get_env(tsss, registry_pg_scope, tsss_registry),
    ets:new(?CACHE_TAB, [
        set, public, named_table,
        {keypos, #reg_entry.handle},
        {read_concurrency, true}
    ]),
    {ok, #state{scope = Scope}}.

handle_call({register, Handle, Pid, PubKey}, _From, #state{scope = Scope} = State) ->
    Entry = #reg_entry{
        handle  = Handle,
        node    = node(),
        pid     = Pid,
        pub_key = PubKey,
        ttl_ms  = application:get_env(tsss, presence_ttl_ms, 30000)
    },
    %% Join pg group — automatically propagates to all connected nodes
    pg:join(Scope, Handle, Pid),
    %% Insert into local ETS cache for fast lookups
    ets:insert(?CACHE_TAB, Entry),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({unregister, Handle}, #state{scope = Scope} = State) ->
    %% Remove from ETS cache
    ets:delete(?CACHE_TAB, Handle),
    %% Leave pg group (if still a member)
    Members = pg:get_local_members(Scope, Handle),
    [pg:leave(Scope, Handle, Pid) || Pid <- Members],
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================

lookup_remote(Handle) ->
    Scope = application:get_env(tsss, registry_pg_scope, tsss_registry),
    case pg:get_members(Scope, Handle) of
        [] ->
            {error, not_found};
        [Pid | _] ->
            %% Ask the session for its public key (it's the authoritative source)
            case catch tsss_session:get_pub_key(Pid) of
                {ok, PubKey} ->
                    Entry = #reg_entry{
                        handle  = Handle,
                        node    = node(Pid),
                        pid     = Pid,
                        pub_key = PubKey,
                        ttl_ms  = 0
                    },
                    ets:insert(?CACHE_TAB, Entry),
                    {ok, Entry};
                _ ->
                    {error, not_found}
            end
    end.
