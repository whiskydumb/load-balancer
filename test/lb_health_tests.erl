-module(lb_health_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POOL, probed_pool).

fresh_tracker_is_up_test() ->
    ?assertEqual(up, status_after([], 2, 3)).

falls_after_a_full_streak_of_failures_test() ->
    ?assertEqual(up, status_after([failure, failure], 2, 3)),
    ?assertEqual(down, status_after([failure, failure, failure], 2, 3)).

success_breaks_a_failure_streak_test() ->
    ?assertEqual(up, status_after([failure, failure, success, failure, failure], 2, 3)).

rises_after_a_full_streak_of_successes_test() ->
    Down = [failure, failure, failure],
    ?assertEqual(down, status_after(Down ++ [success], 2, 3)),
    ?assertEqual(down, status_after(Down ++ [success, failure, success], 2, 3)),
    ?assertEqual(up, status_after(Down ++ [success, success], 2, 3)).

properties_test_() ->
    Options = [{numtests, 500}, {to_file, user}],
    {timeout, 120, ?_assertEqual([], proper:module(prop_lb_health, Options))}.

probes_test_() ->
    {setup, fun start_probed_pool/0, fun stop_probed_pool/1, fun probes_follow_real_listeners/1}.

probers_follow_membership_changes_test_() ->
    Config = lb_pool_fixture:config(?POOL, round_robin, [{{127, 0, 0, 1}, 9001}], #{
        interval => 600000
    }),
    {setup, fun() -> lb_pool_fixture:start_supervised(Config) end, fun lb_pool_fixture:stop/1,
        fun probers_follow_membership/1}.

disabled_checks_start_no_probers_test_() ->
    Backend = {{127, 0, 0, 1}, lb_test_backend:reserve_port()},
    Config = lb_pool_fixture:config(?POOL, round_robin, [Backend], #{enabled => false}),
    {setup, fun() -> lb_pool_fixture:start_supervised(Config) end, fun lb_pool_fixture:stop/1,
        fun only_the_pool_is_started/1}.

probers_follow_membership(#{sup := Sup}) ->
    ?_test(begin
        Configured = {{127, 0, 0, 1}, 9001},
        Added = {{127, 0, 0, 1}, 9002},
        {ok, Backend} = lb_config:validate_backend(#{host => {127, 0, 0, 1}, port => 9002}),
        ok = lb_pool:add_backend(?POOL, Backend),
        ?assertEqual([Configured, Added], lists:sort(probed(Sup))),
        ok = lb_pool:remove_backend(?POOL, Configured),
        ?assertEqual([Added], probed(Sup))
    end).

probed(Sup) ->
    {lb_health_sup, Probers, supervisor, _} =
        lists:keyfind(lb_health_sup, 1, supervisor:which_children(Sup)),
    [Backend || {Backend, _Pid, _Type, _Modules} <- supervisor:which_children(Probers)].

only_the_pool_is_started(#{sup := Sup}) ->
    ?_assertEqual([lb_pool], [Id || {Id, _, _, _} <- supervisor:which_children(Sup)]).

%% real probes against real sockets: one backend listens, the other refuses
probes_follow_real_listeners(#{alive := Alive, refusing := Refusing}) ->
    {timeout, 30,
        ?_test(begin
            #{backend := Listening} = Alive,
            ?assert(settles(Refusing, down)),
            ?assertEqual(up, lb_pool_fixture:health(?POOL, Listening)),
            ?assertEqual({ok, Listening}, lb_pool:pick(?POOL, key, [])),
            {_, Port} = Refusing,
            Revived = lb_test_backend:start(Port),
            ?assert(settles(Refusing, up)),
            ok = lb_test_backend:stop(Alive),
            ?assert(settles(Listening, down)),
            ok = lb_test_backend:stop(Revived)
        end)}.

start_probed_pool() ->
    Alive = lb_test_backend:start(),
    Refusing = {{127, 0, 0, 1}, lb_test_backend:reserve_port()},
    Backends = [maps:get(backend, Alive), Refusing],
    Config = lb_pool_fixture:config(?POOL, round_robin, Backends, #{interval => 100, timeout => 50}),
    #{fixture => lb_pool_fixture:start_supervised(Config), alive => Alive, refusing => Refusing}.

stop_probed_pool(#{fixture := Fixture, alive := Alive}) ->
    ok = lb_test_backend:stop(Alive),
    lb_pool_fixture:stop(Fixture).

%% probes run every 100 ms with jitter, two seconds is a generous bound
settles(Backend, Health) ->
    lb_pool_fixture:eventually(
        fun() -> lb_pool_fixture:health(?POOL, Backend) =:= Health end,
        400
    ).

status_after(Outcomes, Rise, Fall) ->
    Tracker = lists:foldl(
        fun lb_health:observe/2, lb_health:new(#{rise => Rise, fall => Fall}), Outcomes
    ),
    lb_health:status(Tracker).
