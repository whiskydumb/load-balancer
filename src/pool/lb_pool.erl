-module(lb_pool).
-behaviour(gen_server).

-export([start_link/1, tables/0]).
-export([pick/3, track/2, set_health/3, backends/1, pid/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, health/0, backend_status/0]).

-include_lib("kernel/include/logger.hrl").

%% membership lives in this process, but new connections never call it: picks
%% read the published selector from ets and accounting goes through shared
%% counters, so a busy or restarting pool does not stall traffic

-define(SELECTORS, lb_pool_selectors).
-define(COUNTERS, lb_pool_counters).
-define(CONNECTIONS, lb_pool_connections).

-type name() :: atom().
-type health() :: up | down.
-type backend_status() :: #{
    backend := lb_backend:id(),
    weight := lb_balancer:weight(),
    health := health(),
    active := non_neg_integer()
}.

-record(state, {
    name :: name(),
    strategy :: lb_balancer:strategy(),
    backends :: [{lb_backend:id(), lb_balancer:weight()}],
    health :: #{lb_backend:id() => health()}
}).

-spec start_link(lb_config:pool()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% selectors are read by every new connection and rewritten only when membership
%% changes; counters and connection rows are written concurrently by proxies
-spec tables() -> [lb_table_owner:table()].
tables() ->
    [
        {?SELECTORS, [set, public, {read_concurrency, true}]},
        {?COUNTERS, [set, public, {write_concurrency, true}]},
        {?CONNECTIONS, [set, public, {write_concurrency, true}]}
    ].

%% runs in the calling process
-spec pick(name(), term(), [lb_backend:id()]) -> {ok, lb_backend:id()} | {error, no_backend}.
pick(Pool, Key, Exclude) ->
    case ets:lookup_element(?SELECTORS, Pool, 3, undefined) of
        undefined ->
            {error, no_backend};
        Selector ->
            lb_balancer:pick(Selector, #{
                key => Key,
                exclude => Exclude,
                cursor => fun() ->
                    ets:update_counter(?COUNTERS, {cursor, Pool}, 1, {{cursor, Pool}, -1})
                end,
                load => fun(Backend) -> active(Pool, Backend) end
            })
    end.

%% counts the calling process as a connection to Backend until it exits; the
%% pool monitors the caller, so the slot is released however the process ends
-spec track(name(), lb_backend:id()) -> ok.
track(Pool, Backend) ->
    Conn = self(),
    %% the counter goes up before the row exists and a release needs the row, so
    %% the counter never drops below the number of tracked connections
    _ = ets:update_counter(?COUNTERS, {active, Pool, Backend}, 1, {{active, Pool, Backend}, 0}),
    true = ets:insert_new(?CONNECTIONS, {Conn, Pool, Backend}),
    case pid(Pool) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {monitor, Conn})
    end.

-spec set_health(name(), lb_backend:id(), health()) ->
    ok | {error, unknown_pool | unknown_backend}.
set_health(Pool, Backend, Health) ->
    call(Pool, {set_health, Backend, Health}).

-spec backends(name()) -> {ok, [backend_status()]} | {error, unknown_pool}.
backends(Pool) ->
    call(Pool, backends).

%% the pid stays published while the pool restarts, so it may point to a
%% process that is already gone
-spec pid(name()) -> pid() | undefined.
pid(Pool) ->
    ets:lookup_element(?SELECTORS, Pool, 2, undefined).

-spec init(lb_config:pool()) -> {ok, #state{}}.
init(#{name := Name, strategy := Strategy, backends := Backends}) ->
    Members = [{lb_backend:id(Backend), Weight} || #{weight := Weight} = Backend <- Backends],
    State = #state{
        name = Name,
        strategy = Strategy,
        backends = Members,
        health = maps:from_list([{Id, up} || {Id, _} <- Members])
    },
    publish(State),
    %% connections outlive a pool restart. publishing before scanning means one
    %% that registers meanwhile is either found here or casts to this process;
    %% being monitored twice is harmless because release is atomic
    Open = ets:select(?CONNECTIONS, [{{'$1', Name, '_'}, [], ['$1']}]),
    lists:foreach(fun(Conn) -> monitor(process, Conn) end, Open),
    ?LOG_INFO(#{
        event => pool_started,
        pool => Name,
        strategy => Strategy,
        backends => length(Members),
        open_connections => length(Open)
    }),
    {ok, State}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call({set_health, Backend, Health}, _From, #state{name = Name, health = Current} = State) ->
    case Current of
        #{Backend := Health} ->
            {reply, ok, State};
        #{Backend := _Previous} ->
            Next = State#state{health = Current#{Backend := Health}},
            publish(Next),
            ?LOG_NOTICE(#{
                event => backend_health_changed,
                pool => Name,
                backend => lb_backend:format(Backend),
                health => Health
            }),
            {reply, ok, Next};
        #{} ->
            {reply, {error, unknown_backend}, State}
    end;
handle_call(backends, _From, State) ->
    {reply, {ok, statuses(State)}, State};
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({monitor, Conn}, State) ->
    _ = monitor(process, Conn),
    {noreply, State};
handle_cast(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_cast, message => Message}),
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({'DOWN', _Ref, process, Conn, _Reason}, State) ->
    release(Conn),
    {noreply, State};
handle_info(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_message, message => Message}),
    {noreply, State}.

call(Pool, Request) ->
    case pid(Pool) of
        undefined -> {error, unknown_pool};
        Pid -> gen_server:call(Pid, Request)
    end.

%% take/2 is atomic, so a connection monitored twice is still released once
release(Conn) ->
    case ets:take(?CONNECTIONS, Conn) of
        [{Conn, Pool, Backend}] ->
            _ = ets:update_counter(?COUNTERS, {active, Pool, Backend}, -1),
            ok;
        [] ->
            ok
    end.

publish(#state{name = Name, strategy = Strategy, backends = Backends, health = Health}) ->
    Up = [Member || {Id, _Weight} = Member <- Backends, map_get(Id, Health) =:= up],
    true = ets:insert(?SELECTORS, {Name, self(), lb_balancer:new(Strategy, Up)}),
    ok.

active(Pool, Backend) ->
    ets:lookup_element(?COUNTERS, {active, Pool, Backend}, 2, 0).

statuses(#state{name = Name, backends = Backends, health = Health}) ->
    [
        #{
            backend => Id,
            weight => Weight,
            health => map_get(Id, Health),
            active => active(Name, Id)
        }
     || {Id, Weight} <- Backends
    ].
