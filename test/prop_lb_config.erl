-module(prop_lb_config).

-include_lib("proper/include/proper.hrl").

%% normalizing has to be a fixed point: whatever validate returns must pass
%% validation again unchanged, which keeps defaults and normalized hosts valid
%% as input
prop_normalized_config_revalidates() ->
    ?FORALL(
        Raw,
        config(),
        begin
            {ok, Config} = lb_config:validate(Raw),
            lb_config:validate(Config) =:= {ok, Config}
        end
    ).

%% the validator reads untrusted input, so it must never crash and must be able
%% to explain everything it rejects
prop_garbage_is_rejected_with_a_message() ->
    ?FORALL(
        Term,
        any(),
        case lb_config:validate(Term) of
            {ok, Config} ->
                is_map(Config);
            {error, Errors} ->
                lists:all(fun(Error) -> byte_size(lb_config:format_error(Error)) > 0 end, Errors)
        end
    ).

config() ->
    ?LET(
        {PoolNames, ListenerNames},
        {names([alpha, beta, gamma]), names([web, api, edge])},
        ?LET(
            {Pools, Listeners},
            {
                [pool(Name) || Name <- PoolNames],
                [
                    listener(Name, Index, PoolNames)
                 || {Index, Name} <- lists:enumerate(ListenerNames)
                ]
            },
            #{pools => Pools, listeners => Listeners}
        )
    ).

names(All) ->
    ?LET(Count, range(1, length(All)), lists:sublist(All, Count)).

pool(Name) ->
    ?LET(
        {Strategy, Backends, HealthCheck, ConnectTimeout},
        {elements(lb_balancer:strategies()), backends(), health_check(), range(10, 60000)},
        optional(
            #{
                name => Name,
                strategy => Strategy,
                backends => Backends,
                health_check => HealthCheck,
                connect_timeout => ConnectTimeout
            },
            [strategy, backends, health_check, connect_timeout]
        )
    ).

%% every backend gets its own port, so entries stay distinct whatever host form
%% the generator picked
backends() ->
    ?LET(Count, range(0, 4), [backend(9000 + Index) || Index <- lists:seq(1, Count)]).

backend(Port) ->
    ?LET(
        {Host, Weight},
        {host(), range(1, 100)},
        optional(#{host => Host, port => Port, weight => Weight}, [weight])
    ).

host() ->
    oneof([
        {127, 0, 0, 1},
        "127.0.0.2",
        <<"10.0.0.1">>,
        "::1",
        "backend.internal",
        <<"Backend.Internal">>,
        localhost
    ]).

health_check() ->
    ?LET(
        {Interval, Percent, Rise, Fall, Enabled},
        {range(100, 60000), range(1, 100), range(1, 100), range(1, 100), boolean()},
        optional(
            #{
                enabled => Enabled,
                interval => Interval,
                timeout => max(10, Interval * Percent div 100),
                rise => Rise,
                fall => Fall
            },
            [enabled, rise, fall]
        )
    ).

listener(Name, Index, PoolNames) ->
    ?LET(
        {Pool, Ip, Acceptors, MaxConnections, IdleTimeout, Attempts},
        {
            elements(PoolNames),
            oneof([{0, 0, 0, 0}, "127.0.0.1", <<"::1">>]),
            range(1, 1024),
            range(1, 1000000),
            range(1000, 3600000),
            range(1, 10)
        },
        optional(
            #{
                name => Name,
                port => 8000 + Index,
                pool => Pool,
                ip => Ip,
                acceptors => Acceptors,
                max_connections => MaxConnections,
                idle_timeout => IdleTimeout,
                connect_attempts => Attempts
            },
            [ip, acceptors, max_connections, idle_timeout, connect_attempts]
        )
    ).

optional(Map, Keys) ->
    ?LET(Dropped, lb_gen:subset(Keys), maps:without(Dropped, Map)).
