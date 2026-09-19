-module(lb_config).

-export([load/0, validate/1, format_error/1]).

-export_type([config/0, listener/0, pool/0, backend/0, health_check/0, admin/0, host/0, error/0]).

%% the whole configuration is validated before the supervision tree starts, so
%% a typo stops the node at boot instead of surfacing under traffic

-type host() :: inet:ip_address() | string().

-type backend() :: #{
    host := host(),
    port := 1..65535,
    weight := lb_balancer:weight()
}.

-type health_check() :: #{
    enabled := boolean(),
    interval := pos_integer(),
    timeout := pos_integer(),
    rise := pos_integer(),
    fall := pos_integer()
}.

-type pool() :: #{
    name := atom(),
    strategy := lb_balancer:strategy(),
    connect_timeout := pos_integer(),
    backends := [backend()],
    health_check := health_check()
}.

-type listener() :: #{
    name := atom(),
    ip := inet:ip_address(),
    port := inet:port_number(),
    pool := atom(),
    acceptors := pos_integer(),
    backlog := pos_integer(),
    max_connections := pos_integer(),
    idle_timeout := pos_integer(),
    connect_attempts := pos_integer()
}.

-type admin() :: #{
    enabled := boolean(),
    ip := inet:ip_address(),
    port := inet:port_number()
}.

-type config() :: #{listeners := [listener()], pools := [pool()], admin := admin()}.

-type reason() :: {duplicate, term()} | {unknown_pool, atom()} | {exceeds, interval, pos_integer()}.
-type error() :: lb_config_schema:error() | {lb_config_schema:path(), reason()}.

-spec load() -> {ok, config()} | {error, [error()]}.
load() ->
    validate(maps:from_list(application:get_all_env(lb))).

-spec validate(term()) -> {ok, config()} | {error, [error()]}.
validate(Raw) ->
    case lb_config_schema:validate(schema(), Raw) of
        {ok, Config} ->
            case cross_checks(Config) of
                [] -> {ok, Config};
                Errors -> {error, Errors}
            end;
        {error, Errors} ->
            {error, Errors}
    end.

-spec format_error(error()) -> binary().
format_error({Path, {duplicate, Value}}) ->
    text("~ts: ~0p is already used", [lb_config_schema:format_path(Path), Value]);
format_error({Path, {unknown_pool, Name}}) ->
    text("~ts: no pool named ~0p is configured", [lb_config_schema:format_path(Path), Name]);
format_error({Path, {exceeds, interval, Interval}}) ->
    text("~ts: must not exceed interval, which is ~p ms", [
        lb_config_schema:format_path(Path), Interval
    ]);
format_error(Error) ->
    lb_config_schema:format_error(Error).

schema() ->
    #{
        listeners => #{type => {list, {map, listener_schema()}}, default => []},
        pools => #{type => {list, {map, pool_schema()}}, default => []},
        admin => #{type => {map, admin_schema()}, default => #{}}
    }.

listener_schema() ->
    #{
        name => #{type => atom},
        %% port 0 lets the os pick a free one, which keeps tests off fixed ports
        port => #{type => {integer, 0, 65535}},
        pool => #{type => atom},
        ip => #{type => ip_address, default => {0, 0, 0, 0}},
        acceptors => #{type => {integer, 1, 1024}, default => 10},
        backlog => #{type => {integer, 1, 65535}, default => 1024},
        max_connections => #{type => {integer, 1, infinity}, default => 10000},
        idle_timeout => #{type => {integer, 1000, infinity}, default => 3600000},
        %% how many backends one client connection may try before giving up
        connect_attempts => #{type => {integer, 1, 10}, default => 3}
    }.

pool_schema() ->
    #{
        name => #{type => atom},
        strategy => #{type => {enum, lb_balancer:strategies()}, default => round_robin},
        connect_timeout => #{type => {integer, 10, infinity}, default => 5000},
        backends => #{type => {list, {map, backend_schema()}}, default => []},
        health_check => #{type => {map, health_check_schema()}, default => #{}}
    }.

backend_schema() ->
    #{
        host => #{type => host},
        port => #{type => {integer, 1, 65535}},
        weight => #{type => {integer, 1, 100}, default => 1}
    }.

%% off unless asked for; its bearer token comes from the LB_ADMIN_TOKEN
%% environment variable and never from a config file
admin_schema() ->
    #{
        enabled => #{type => boolean, default => false},
        ip => #{type => ip_address, default => {127, 0, 0, 1}},
        port => #{type => {integer, 0, 65535}, default => 9900}
    }.

health_check_schema() ->
    #{
        enabled => #{type => boolean, default => true},
        interval => #{type => {integer, 100, infinity}, default => 5000},
        timeout => #{type => {integer, 10, infinity}, default => 2000},
        %% consecutive probe results needed to flip a backend
        rise => #{type => {integer, 1, 100}, default => 2},
        fall => #{type => {integer, 1, 100}, default => 3}
    }.

%% checks that span several entries and cannot be expressed field by field
cross_checks(#{listeners := Listeners, pools := Pools}) ->
    Names = [Name || #{name := Name} <- Pools],
    lists:sort(
        duplicate_names(listeners, Listeners) ++
            duplicate_names(pools, Pools) ++
            [
                {[listeners, Index, pool], {unknown_pool, Pool}}
             || {Index, #{pool := Pool}} <- lists:enumerate(Listeners),
                not lists:member(Pool, Names)
            ] ++
            lists:append([pool_checks(Index, Pool) || {Index, Pool} <- lists:enumerate(Pools)])
    ).

duplicate_names(Section, Entries) ->
    [
        {[Section, Index, name], {duplicate, Name}}
     || {Index, Name} <- repeated([Name || #{name := Name} <- Entries])
    ].

pool_checks(PoolIndex, #{backends := Backends, health_check := HealthCheck}) ->
    [
        {[pools, PoolIndex, backends, Index], {duplicate, Address}}
     || {Index, Address} <- repeated([{Host, Port} || #{host := Host, port := Port} <- Backends])
    ] ++ health_check_checks(PoolIndex, HealthCheck).

%% a probe that outlives its interval would overlap the next one
health_check_checks(PoolIndex, #{interval := Interval, timeout := Timeout}) when
    Timeout > Interval
->
    [{[pools, PoolIndex, health_check, timeout], {exceeds, interval, Interval}}];
health_check_checks(_PoolIndex, _HealthCheck) ->
    [].

%% positions of values that repeat an earlier one
repeated(Values) ->
    {_, Repeated} = lists:foldl(
        fun({Index, Value}, {Seen, Acc}) ->
            case lists:member(Value, Seen) of
                true -> {Seen, [{Index, Value} | Acc]};
                false -> {[Value | Seen], Acc}
            end
        end,
        {[], []},
        lists:enumerate(Values)
    ),
    lists:reverse(Repeated).

text(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
