-module(lb_pool).
-behaviour(gen_server).

-export([start_link/1, tables/0]).
-export([pick/3, track/2, observe/3, backends/1, pid/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, observation/0, backend_status/0]).

-include_lib("kernel/include/logger.hrl").

%% membership and health live in this process, but new connections never call
%% it: picks read the published selector from ets and accounting goes through
%% shared counters, so a busy or restarting pool does not stall traffic

-define(SELECTORS, lb_pool_selectors).
-define(COUNTERS, lb_pool_counters).
-define(CONNECTIONS, lb_pool_connections).

-type name() :: atom().
-type observation() :: success | {failure, Reason :: term()}.
-type backend_status() :: #{
    backend := lb_backend:id(),
    weight := lb_balancer:weight(),
    health := lb_health:status(),
    active := non_neg_integer()
}.

-record(state, {
    name :: name(),
    strategy :: lb_balancer:strategy(),
    backends :: [{lb_backend:id(), lb_balancer:weight()}],
    %% without active probes nothing could bring a backend back up, so failures
    %% reported by connections are ignored too
    checks :: boolean(),
    trackers :: #{lb_backend:id() => lb_health:tracker()}
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

%% feeds a probe result or a failed client connection into the backend health
-spec observe(name(), lb_backend:id(), observation()) -> ok.
observe(Pool, Backend, Observation) ->
    case pid(Pool) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {observe, Backend, Observation})
    end.

-spec backends(name()) -> {ok, [backend_status()]} | {error, unknown_pool}.
backends(Pool) ->
    case pid(Pool) of
        undefined -> {error, unknown_pool};
        Pid -> gen_server:call(Pid, backends)
    end.

%% the pid stays published while the pool restarts, so it may point to a
%% process that is already gone
-spec pid(name()) -> pid() | undefined.
pid(Pool) ->
    ets:lookup_element(?SELECTORS, Pool, 2, undefined).

-spec init(lb_config:pool()) -> {ok, #state{}}.
init(#{
    name := Name,
    strategy := Strategy,
    backends := Backends,
    health_check := #{enabled := Checks} = HealthCheck
}) ->
    Members = [{lb_backend:id(Backend), Weight} || #{weight := Weight} = Backend <- Backends],
    State = #state{
        name = Name,
        strategy = Strategy,
        backends = Members,
        checks = Checks,
        trackers = maps:from_list([{Id, lb_health:new(HealthCheck)} || {Id, _} <- Members])
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
handle_call(backends, _From, State) ->
    {reply, {ok, statuses(State)}, State};
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({monitor, Conn}, State) ->
    _ = monitor(process, Conn),
    {noreply, State};
handle_cast({observe, _Backend, _Observation}, #state{checks = false} = State) ->
    {noreply, State};
handle_cast({observe, Backend, Observation}, #state{trackers = Trackers} = State) ->
    case Trackers of
        #{Backend := Tracker} -> {noreply, observed(Backend, Observation, Tracker, State)};
        #{} -> {noreply, State}
    end;
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

observed(Backend, Observation, Tracker, #state{name = Name, trackers = Trackers} = State) ->
    Next = lb_health:observe(outcome(Observation), Tracker),
    Observed = State#state{trackers = Trackers#{Backend := Next}},
    case lb_health:status(Next) =:= lb_health:status(Tracker) of
        true ->
            Observed;
        false ->
            publish(Observed),
            log_transition(Name, Backend, Observation),
            Observed
    end.

outcome(success) -> success;
outcome({failure, _Reason}) -> failure.

%% a backend only goes down on a failure and only comes up on a success
log_transition(Pool, Backend, {failure, Reason}) ->
    ?LOG_WARNING(#{
        event => backend_down,
        pool => Pool,
        backend => lb_backend:format(Backend),
        reason => Reason
    });
log_transition(Pool, Backend, success) ->
    ?LOG_NOTICE(#{event => backend_up, pool => Pool, backend => lb_backend:format(Backend)}).

%% take/2 is atomic, so a connection monitored twice is still released once
release(Conn) ->
    case ets:take(?CONNECTIONS, Conn) of
        [{Conn, Pool, Backend}] ->
            _ = ets:update_counter(?COUNTERS, {active, Pool, Backend}, -1),
            ok;
        [] ->
            ok
    end.

publish(#state{name = Name, strategy = Strategy, backends = Backends} = State) ->
    Up = [Member || {Id, _Weight} = Member <- Backends, health(Id, State) =:= up],
    true = ets:insert(?SELECTORS, {Name, self(), lb_balancer:new(Strategy, Up)}),
    ok.

health(Backend, #state{trackers = Trackers}) ->
    lb_health:status(map_get(Backend, Trackers)).

active(Pool, Backend) ->
    ets:lookup_element(?COUNTERS, {active, Pool, Backend}, 2, 0).

statuses(#state{name = Name, backends = Backends} = State) ->
    [
        #{
            backend => Id,
            weight => Weight,
            health => health(Id, State),
            active => active(Name, Id)
        }
     || {Id, Weight} <- Backends
    ].
