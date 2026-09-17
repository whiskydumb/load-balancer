-module(lb_pool_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POOL, test_pool).
-define(A, {{127, 0, 0, 1}, 9001}).
-define(B, {{127, 0, 0, 1}, 9002}).
-define(C, {{127, 0, 0, 1}, 9003}).

round_robin_pool_test_() ->
    {foreach, fun() -> lb_pool_fixture:start(?POOL, round_robin, [?A, ?B, ?C]) end,
        fun lb_pool_fixture:stop/1, [
            fun cursor_is_shared_between_callers/1,
            fun down_backend_is_skipped_until_it_is_up/1,
            fun pool_without_healthy_backends_has_no_backend/1,
            fun unknown_names_are_rejected/1,
            fun connection_counts_until_it_closes/1,
            fun crashed_connection_releases_its_slot/1,
            fun restarted_pool_keeps_counting_open_connections/1,
            fun connection_closed_while_pool_was_down_is_released/1,
            fun connection_monitored_twice_is_released_once/1
        ]}.

least_conn_pool_test_() ->
    {setup, fun() -> lb_pool_fixture:start(?POOL, least_conn, [?A, ?B]) end,
        fun lb_pool_fixture:stop/1, fun busy_backend_is_avoided/1}.

application_supervises_pools_test_() ->
    {setup, fun start_application/0, fun stop_application/1,
        fun supervisor_restarts_a_crashed_pool/1}.

cursor_is_shared_between_callers(_) ->
    ?_test(begin
        Picks = [pick_from_new_process() || _ <- lists:seq(1, 6)],
        ?assertEqual([?A, ?B, ?C, ?A, ?B, ?C], Picks)
    end).

down_backend_is_skipped_until_it_is_up(_) ->
    ?_test(begin
        ok = lb_pool:set_health(?POOL, ?B, down),
        ?assertNot(lists:member(?B, picks(6))),
        ok = lb_pool:set_health(?POOL, ?B, up),
        ?assert(lists:member(?B, picks(3)))
    end).

pool_without_healthy_backends_has_no_backend(_) ->
    ?_test(begin
        [ok = lb_pool:set_health(?POOL, Backend, down) || Backend <- [?A, ?B, ?C]],
        ?assertEqual({error, no_backend}, lb_pool:pick(?POOL, key, []))
    end).

unknown_names_are_rejected(_) ->
    [
        ?_assertEqual({error, no_backend}, lb_pool:pick(ghost, key, [])),
        ?_assertEqual({error, unknown_pool}, lb_pool:backends(ghost)),
        ?_assertEqual(
            {error, unknown_backend}, lb_pool:set_health(?POOL, {{10, 0, 0, 1}, 1}, down)
        )
    ].

connection_counts_until_it_closes(_) ->
    ?_test(begin
        Conn = lb_pool_fixture:open(?POOL, ?A),
        ?assertEqual(1, lb_pool_fixture:active(?POOL, ?A)),
        lb_pool_fixture:close(Conn),
        ?assert(settles_at(0))
    end).

crashed_connection_releases_its_slot(_) ->
    ?_test(begin
        Conn = lb_pool_fixture:open(?POOL, ?A),
        lb_pool_fixture:crash(Conn),
        ?assert(settles_at(0))
    end).

restarted_pool_keeps_counting_open_connections(Fixture) ->
    ?_test(begin
        Conn = lb_pool_fixture:open(?POOL, ?A),
        ok = lb_pool_fixture:restart_pool(Fixture),
        ?assertEqual(1, lb_pool_fixture:active(?POOL, ?A)),
        lb_pool_fixture:close(Conn),
        ?assert(settles_at(0))
    end).

connection_closed_while_pool_was_down_is_released(Fixture) ->
    ?_test(begin
        Conn = lb_pool_fixture:open(?POOL, ?A),
        ok = lb_pool_fixture:stop_pool(Fixture),
        lb_pool_fixture:close(Conn),
        ok = lb_pool_fixture:start_pool(Fixture),
        ?assert(settles_at(0))
    end).

%% white box: repeats the monitor request a connection sends, as happens when
%% it registers while the pool starts and is also found by the startup scan
connection_monitored_twice_is_released_once(_) ->
    ?_test(begin
        Conn = lb_pool_fixture:open(?POOL, ?A),
        gen_server:cast(lb_pool:pid(?POOL), {monitor, Conn}),
        Other = lb_pool_fixture:open(?POOL, ?A),
        lb_pool_fixture:close(Conn),
        ?assert(settles_at(1)),
        ?assertEqual(1, lb_pool_fixture:active(?POOL, ?A)),
        lb_pool_fixture:close(Other)
    end).

busy_backend_is_avoided(_) ->
    ?_test(begin
        Conns = [lb_pool_fixture:open(?POOL, ?A) || _ <- lists:seq(1, 3)],
        ?assertEqual({ok, ?B}, lb_pool:pick(?POOL, key, [])),
        lists:foreach(fun lb_pool_fixture:close/1, Conns)
    end).

supervisor_restarts_a_crashed_pool(_) ->
    ?_test(begin
        Crashed = lb_pool:pid(app_pool),
        lb_pool_fixture:crash(Crashed),
        ?assert(lb_pool_fixture:eventually(fun() -> restarted(app_pool, Crashed) end)),
        ?assertEqual({ok, {{127, 0, 0, 1}, 9001}}, lb_pool:pick(app_pool, key, []))
    end).

properties_test_() ->
    Options = [{numtests, 100}, {to_file, user}],
    {timeout, 300, ?_assertEqual([], proper:module(prop_lb_pool, Options))}.

settles_at(Expected) ->
    lb_pool_fixture:eventually(fun() -> lb_pool_fixture:active(?POOL, ?A) =:= Expected end).

picks(Count) ->
    [Backend || _ <- lists:seq(1, Count), {ok, Backend} <- [lb_pool:pick(?POOL, key, [])]].

pick_from_new_process() ->
    Parent = self(),
    spawn(fun() -> Parent ! {picked, lb_pool:pick(?POOL, key, [])} end),
    receive
        {picked, {ok, Backend}} -> Backend
    end.

restarted(Pool, Crashed) ->
    case lb_pool:pid(Pool) of
        Crashed -> false;
        Pid -> is_process_alive(Pid)
    end.

%% env set before the application is loaded would be overwritten by the
%% defaults in lb.app, so it is loaded first
start_application() ->
    case application:load(lb) of
        ok -> ok;
        {error, {already_loaded, lb}} -> ok
    end,
    ok = application:set_env(lb, pools, [
        #{name => app_pool, backends => [#{host => "127.0.0.1", port => 9001}]}
    ]),
    {ok, Started} = application:ensure_all_started(lb),
    Started.

stop_application(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)),
    ok = application:unload(lb).
