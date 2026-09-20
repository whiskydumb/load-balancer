-module(lb_pool).
-behaviour(gen_server).

-export([start_link/1, start_link/2, tables/0]).
-export([pick/3, track/2, connect_failed/3, observe/3]).
-export([add_backend/2, remove_backend/2, drain/2, enable/2]).
-export([backends/1, members/1, names/0, pid/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, observation/0, admin_state/0, backend_status/0]).

-include_lib("kernel/include/logger.hrl").

%% membership and health live in this process, but new connections never call
%% it: picks read the published selector from ets and accounting goes through
%% shared counters, so a busy or restarting pool does not stall traffic

-define(SELECTORS, lb_pool_selectors).
-define(MEMBERS, lb_pool_members).
-define(COUNTERS, lb_pool_counters).
-define(CONNECTIONS, lb_pool_connections).

-type name() :: atom().
-type observation() :: success | {failure, Reason :: term()}.
%% set by operators; a draining backend keeps its connections but gets no new ones
-type admin_state() :: enabled | draining.
-type backend_status() :: #{
    backend := lb_backend:id(),
    weight := lb_balancer:weight(),
    health := lb_health:status(),
    admin := admin_state(),
    active := non_neg_integer(),
    connections_total := non_neg_integer(),
    connect_failures_total := non_neg_integer()
}.

-record(state, {
    name :: name(),
    strategy :: lb_balancer:strategy(),
    health_check :: lb_config:health_check(),
    %% the per-pool supervisor that also runs the probers; undefined when the
    %% pool runs on its own
    parent :: pid() | undefined,
    backends :: [{lb_backend:id(), lb_balancer:weight()}],
    admin :: #{lb_backend:id() => admin_state()},
    trackers :: #{lb_backend:id() => lb_health:tracker()}
}).

-spec start_link(lb_config:pool()) -> gen_server:start_ret().
start_link(Config) ->
    start_link(Config, undefined).

-spec start_link(lb_config:pool(), pid() | undefined) -> gen_server:start_ret().
start_link(Config, Parent) ->
    gen_server:start_link(?MODULE, {Config, Parent}, []).

%% selectors are read by every new connection and rewritten only when membership
%% changes; counters and connection rows are written concurrently by proxies.
%% every backend has one counter row: {Key, Active, Connected, Failed}
-spec tables() -> [lb_table_owner:table()].
tables() ->
    [
        {?SELECTORS, [set, public, {read_concurrency, true}]},
        {?MEMBERS, [set, public]},
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
    _ = ets:update_counter(
        ?COUNTERS, counter_key(Pool, Backend), [{2, 1}, {3, 1}], counter_row(Pool, Backend)
    ),
    true = ets:insert_new(?CONNECTIONS, {Conn, Pool, Backend}),
    case pid(Pool) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {monitor, Conn})
    end.

%% counts a failed connect against the backend and feeds it into its health
-spec connect_failed(name(), lb_backend:id(), term()) -> ok.
connect_failed(Pool, Backend, Reason) ->
    _ = ets:update_counter(
        ?COUNTERS, counter_key(Pool, Backend), {4, 1}, counter_row(Pool, Backend)
    ),
    observe(Pool, Backend, {failure, Reason}).

%% feeds a probe result or a failed client connection into the backend health
-spec observe(name(), lb_backend:id(), observation()) -> ok.
observe(Pool, Backend, Observation) ->
    case pid(Pool) of
        undefined -> ok;
        Pid -> gen_server:cast(Pid, {observe, Backend, Observation})
    end.

-spec add_backend(name(), lb_config:backend()) -> ok | {error, unknown_pool | already_exists}.
add_backend(Pool, Backend) ->
    call(Pool, {add_backend, Backend}).

%% the backend gets no new connections; open ones run their course
-spec remove_backend(name(), lb_backend:id()) -> ok | {error, unknown_pool | unknown_backend}.
remove_backend(Pool, Backend) ->
    call(Pool, {remove_backend, Backend}).

-spec drain(name(), lb_backend:id()) -> ok | {error, unknown_pool | unknown_backend}.
drain(Pool, Backend) ->
    call(Pool, {set_admin, Backend, draining}).

-spec enable(name(), lb_backend:id()) -> ok | {error, unknown_pool | unknown_backend}.
enable(Pool, Backend) ->
    call(Pool, {set_admin, Backend, enabled}).

-spec backends(name()) -> {ok, [backend_status()]} | {error, unknown_pool}.
backends(Pool) ->
    call(Pool, backends).

%% the current membership, including changes made at runtime
-spec members(name()) -> [lb_backend:id()].
members(Pool) ->
    case ets:lookup(?MEMBERS, Pool) of
        [{Pool, Members}] -> [Id || {Id, _Weight, _Admin} <- Members];
        [] -> []
    end.

-spec names() -> [name()].
names() ->
    ets:select(?SELECTORS, [{{'$1', '_', '_'}, [], ['$1']}]).

%% the pid stays published while the pool restarts, so it may point to a
%% process that is already gone
-spec pid(name()) -> pid() | undefined.
pid(Pool) ->
    ets:lookup_element(?SELECTORS, Pool, 2, undefined).

-spec init({lb_config:pool(), pid() | undefined}) -> {ok, #state{}}.
init({Config, Parent}) ->
    #{name := Name, strategy := Strategy, backends := Configured, health_check := HealthCheck} =
        Config,
    %% changes made through the admin api survive a pool restart; the config
    %% file takes over again only when the node restarts
    Members =
        case ets:lookup(?MEMBERS, Name) of
            [{Name, Saved}] -> Saved;
            [] -> [{lb_backend:id(Backend), W, enabled} || #{weight := W} = Backend <- Configured]
        end,
    State = #state{
        name = Name,
        strategy = Strategy,
        health_check = HealthCheck,
        parent = Parent,
        backends = [{Id, Weight} || {Id, Weight, _Admin} <- Members],
        admin = maps:from_list([{Id, Admin} || {Id, _Weight, Admin} <- Members]),
        trackers = maps:from_list([{Id, lb_health:new(HealthCheck)} || {Id, _, _} <- Members])
    },
    commit(State),
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
handle_call({add_backend, #{weight := Weight} = Backend}, _From, State) ->
    #state{backends = Backends, admin = Admin, trackers = Trackers} = State,
    Id = lb_backend:id(Backend),
    case lists:keymember(Id, 1, Backends) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            Next = State#state{
                backends = Backends ++ [{Id, Weight}],
                admin = Admin#{Id => enabled},
                trackers = Trackers#{Id => lb_health:new(State#state.health_check)}
            },
            commit(Next),
            ok = start_probe(Id, Next),
            log_change(backend_added, Id, Next),
            {reply, ok, Next}
    end;
handle_call({remove_backend, Id}, _From, #state{backends = Backends} = State) ->
    case lists:keymember(Id, 1, Backends) of
        false ->
            {reply, {error, unknown_backend}, State};
        true ->
            ok = stop_probe(Id, State),
            Next = State#state{
                backends = lists:keydelete(Id, 1, Backends),
                admin = maps:remove(Id, State#state.admin),
                trackers = maps:remove(Id, State#state.trackers)
            },
            commit(Next),
            log_change(backend_removed, Id, Next),
            {reply, ok, Next}
    end;
handle_call({set_admin, Id, Mode}, _From, #state{admin = Admin} = State) ->
    case Admin of
        #{Id := Mode} ->
            {reply, ok, State};
        #{Id := _Other} ->
            Next = State#state{admin = Admin#{Id := Mode}},
            commit(Next),
            log_change(admin_event(Mode), Id, Next),
            {reply, ok, Next};
        #{} ->
            {reply, {error, unknown_backend}, State}
    end;
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast({monitor, Conn}, State) ->
    _ = monitor(process, Conn),
    {noreply, State};
%% without active probes nothing could bring a backend back up, so failures
%% reported by connections are ignored too
handle_cast({observe, _Backend, _Observation}, #state{health_check = #{enabled := false}} = State) ->
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

call(Pool, Request) ->
    case pid(Pool) of
        undefined -> {error, unknown_pool};
        Pid -> gen_server:call(Pid, Request)
    end.

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

admin_event(draining) -> backend_draining;
admin_event(enabled) -> backend_enabled.

log_change(Event, Backend, #state{name = Pool}) ->
    ?LOG_NOTICE(#{event => Event, pool => Pool, backend => lb_backend:format(Backend)}).

%% the per-pool supervisor starts the probers after this process, so their
%% supervisor is looked up when a change arrives, never during init
start_probe(_Backend, #state{parent = undefined}) ->
    ok;
start_probe(_Backend, #state{health_check = #{enabled := false}}) ->
    ok;
start_probe(Backend, #state{parent = Parent, name = Name, health_check = HealthCheck}) ->
    Spec = lb_health_sup:child_spec(Name, Backend, HealthCheck),
    {ok, _Prober} = supervisor:start_child(probers(Parent), Spec),
    ok.

stop_probe(_Backend, #state{parent = undefined}) ->
    ok;
stop_probe(_Backend, #state{health_check = #{enabled := false}}) ->
    ok;
stop_probe(Backend, #state{parent = Parent}) ->
    Probers = probers(Parent),
    ok = supervisor:terminate_child(Probers, Backend),
    supervisor:delete_child(Probers, Backend).

probers(Parent) ->
    {lb_health_sup, Probers, supervisor, _Modules} =
        lists:keyfind(lb_health_sup, 1, supervisor:which_children(Parent)),
    Probers.

%% take/2 is atomic, so a connection monitored twice is still released once
release(Conn) ->
    case ets:take(?CONNECTIONS, Conn) of
        [{Conn, Pool, Backend}] ->
            _ = ets:update_counter(?COUNTERS, counter_key(Pool, Backend), {2, -1}),
            ok;
        [] ->
            ok
    end.

%% saves the membership, so a restarted pool resumes it, and publishes the
%% selector new connections read
commit(#state{name = Name, backends = Backends, admin = Admin} = State) ->
    Members = [{Id, Weight, map_get(Id, Admin)} || {Id, Weight} <- Backends],
    true = ets:insert(?MEMBERS, {Name, Members}),
    publish(State).

publish(#state{name = Name, strategy = Strategy, backends = Backends} = State) ->
    Serving = [Member || {Id, _Weight} = Member <- Backends, serving(Id, State)],
    true = ets:insert(?SELECTORS, {Name, self(), lb_balancer:new(Strategy, Serving)}),
    ok.

%% new connections go to backends that are healthy and not drained
serving(Backend, #state{admin = Admin} = State) ->
    health(Backend, State) =:= up andalso map_get(Backend, Admin) =:= enabled.

health(Backend, #state{trackers = Trackers}) ->
    lb_health:status(map_get(Backend, Trackers)).

active(Pool, Backend) ->
    ets:lookup_element(?COUNTERS, counter_key(Pool, Backend), 2, 0).

counter_key(Pool, Backend) ->
    {backend, Pool, Backend}.

counter_row(Pool, Backend) ->
    {counter_key(Pool, Backend), 0, 0, 0}.

statuses(#state{name = Name, backends = Backends, admin = Admin} = State) ->
    [
        begin
            {_Key, Active, Connected, Failed} =
                case ets:lookup(?COUNTERS, counter_key(Name, Id)) of
                    [Row] -> Row;
                    [] -> counter_row(Name, Id)
                end,
            #{
                backend => Id,
                weight => Weight,
                health => health(Id, State),
                admin => map_get(Id, Admin),
                active => Active,
                connections_total => Connected,
                connect_failures_total => Failed
            }
        end
     || {Id, Weight} <- Backends
    ].
