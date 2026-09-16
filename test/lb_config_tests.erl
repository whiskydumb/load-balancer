-module(lb_config_tests).

-include_lib("eunit/include/eunit.hrl").

empty_config_is_valid_test() ->
    ?assertEqual({ok, #{listeners => [], pools => []}}, lb_config:validate(#{})).

defaults_fill_every_option_test() ->
    {ok, #{listeners := [Listener], pools := [Pool]}} = lb_config:validate(#{
        listeners => [base_listener()],
        pools => [maps:merge(base_pool(), #{backends => [#{host => "127.0.0.1", port => 9001}]})]
    }),
    ?assertEqual(
        #{
            name => web,
            port => 8080,
            pool => api,
            ip => {0, 0, 0, 0},
            acceptors => 10,
            backlog => 1024,
            max_connections => 10000,
            idle_timeout => 3600000,
            connect_attempts => 3
        },
        Listener
    ),
    ?assertEqual(
        #{
            name => api,
            strategy => round_robin,
            connect_timeout => 5000,
            backends => [#{host => {127, 0, 0, 1}, port => 9001, weight => 1}],
            health_check => #{
                enabled => true, interval => 5000, timeout => 2000, rise => 2, fall => 3
            }
        },
        Pool
    ).

host_forms_are_normalized_test_() ->
    [
        {"ipv4 string", ?_assertEqual({127, 0, 0, 1}, host_of("127.0.0.1"))},
        {"ipv4 binary", ?_assertEqual({10, 0, 0, 1}, host_of(<<"10.0.0.1">>))},
        {"ipv4 tuple", ?_assertEqual({10, 0, 0, 2}, host_of({10, 0, 0, 2}))},
        {"ipv6 string", ?_assertEqual({0, 0, 0, 0, 0, 0, 0, 1}, host_of("::1"))},
        {"host name lowercased", ?_assertEqual("db.internal", host_of(<<"DB.Internal">>))},
        {"atom host name", ?_assertEqual("localhost", host_of(localhost))}
    ].

rejected_values_test_() ->
    Cases = [
        {"port above the range", listeners_with(#{port => 70000}), [listeners, 1, port]},
        {"port as a string", listeners_with(#{port => "8080"}), [listeners, 1, port]},
        {"required option left out", listeners_without([name]), [listeners, 1, name]},
        {"misspelled option", listeners_with(#{acceptorz => 4}), [listeners, 1, acceptorz]},
        {"unknown strategy", pools_with(#{strategy => magic}), [pools, 1, strategy]},
        {"weight above the range", pools_with(#{backends => [backend(#{weight => 500})]}), [
            pools, 1, backends, 1, weight
        ]},
        {"host with a space", pools_with(#{backends => [backend(#{host => "not a host"})]}), [
            pools, 1, backends, 1, host
        ]},
        {"listeners is not a list", #{listeners => web}, [listeners]},
        {"config is not a map", 42, []}
    ],
    [
        {Title, ?_assertMatch({error, [{Path, _}]}, lb_config:validate(Input))}
     || {Title, Input, Path} <- Cases
    ].

cross_checks_test_() ->
    [
        {"listener points at a missing pool",
            ?_assertEqual(
                {error, [{[listeners, 1, pool], {unknown_pool, ghost}}]},
                lb_config:validate(#{
                    listeners => [maps:merge(base_listener(), #{pool => ghost})],
                    pools => [base_pool()]
                })
            )},
        {"pool names are unique",
            ?_assertEqual(
                {error, [{[pools, 2, name], {duplicate, api}}]},
                lb_config:validate(#{pools => [base_pool(), base_pool()]})
            )},
        {"the same address twice is one backend",
            ?_assertEqual(
                {error, [{[pools, 1, backends, 2], {duplicate, {{127, 0, 0, 1}, 9001}}}]},
                lb_config:validate(
                    pools_with(#{
                        backends => [
                            backend(#{host => "127.0.0.1"}),
                            backend(#{host => {127, 0, 0, 1}})
                        ]
                    })
                )
            )},
        {"probe timeout fits in the interval",
            ?_assertEqual(
                {error, [{[pools, 1, health_check, timeout], {exceeds, interval, 1000}}]},
                lb_config:validate(
                    pools_with(#{health_check => #{interval => 1000, timeout => 2000}})
                )
            )}
    ].

every_problem_is_reported_at_once_test() ->
    {error, Errors} = lb_config:validate(#{
        listeners => [maps:merge(base_listener(), #{port => 70000})],
        pools => [maps:merge(base_pool(), #{strategy => magic})]
    }),
    ?assertEqual([[listeners, 1, port], [pools, 1, strategy]], [Path || {Path, _} <- Errors]).

messages_explain_the_problem_test_() ->
    [
        ?_assertEqual(
            <<"listeners[1].port: expected an integer in 0..65535, got 70000">>,
            first_message(listeners_with(#{port => 70000}))
        ),
        ?_assertEqual(
            <<"listeners[1].name: required option is missing">>,
            first_message(listeners_without([name]))
        ),
        ?_assertEqual(
            <<"listeners[1].acceptorz: unknown option">>,
            first_message(listeners_with(#{acceptorz => 4}))
        ),
        ?_assertEqual(
            <<"pools[1].strategy: expected one of least_conn, round_robin, source_hash, got magic">>,
            first_message(pools_with(#{strategy => magic}))
        ),
        ?_assertEqual(
            <<"pools[1].backends[1].host: expected a host name or ip address, got \"not a host\"">>,
            first_message(pools_with(#{backends => [backend(#{host => "not a host"})]}))
        ),
        ?_assertEqual(
            <<"listeners[1].pool: no pool named ghost is configured">>,
            first_message(#{listeners => [maps:merge(base_listener(), #{pool => ghost})]})
        ),
        ?_assertEqual(<<"config: expected a map, got 42">>, first_message(42))
    ].

properties_test_() ->
    Options = [{numtests, 300}, {to_file, user}],
    {timeout, 300, ?_assertEqual([], proper:module(prop_lb_config, Options))}.

base_listener() ->
    #{name => web, port => 8080, pool => api}.

base_pool() ->
    #{name => api}.

backend(Overrides) ->
    maps:merge(#{host => "127.0.0.1", port => 9001}, Overrides).

listeners_with(Overrides) ->
    #{listeners => [maps:merge(base_listener(), Overrides)], pools => [base_pool()]}.

listeners_without(Keys) ->
    #{listeners => [maps:without(Keys, base_listener())], pools => [base_pool()]}.

pools_with(Overrides) ->
    #{pools => [maps:merge(base_pool(), Overrides)]}.

host_of(Host) ->
    {ok, #{pools := [#{backends := [#{host := Normalized}]}]}} = lb_config:validate(
        pools_with(#{backends => [backend(#{host => Host})]})
    ),
    Normalized.

first_message(Input) ->
    {error, [Error | _]} = lb_config:validate(Input),
    lb_config:format_error(Error).
