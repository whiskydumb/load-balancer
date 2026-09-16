-module(lb_balancer_tests).

-include_lib("eunit/include/eunit.hrl").

empty_pool_has_no_backend_test_() ->
    [
        ?_assertEqual(
            {error, no_backend},
            lb_balancer:pick(lb_balancer:new(Strategy, []), lb_balancer_ctx:new())
        )
     || Strategy <- lb_balancer:strategies()
    ].

fully_excluded_pool_has_no_backend_test_() ->
    Context = lb_balancer_ctx:new(#{exclude => [a, b]}),
    [
        ?_assertEqual(
            {error, no_backend},
            lb_balancer:pick(lb_balancer:new(Strategy, [{a, 1}, {b, 2}]), Context)
        )
     || Strategy <- lb_balancer:strategies()
    ].

round_robin_interleaves_heavy_backend_test() ->
    Selector = lb_balancer:new(round_robin, [{a, 5}, {b, 1}, {c, 1}]),
    ?assertEqual([a, a, b, a, c, a, a], lb_balancer_ctx:picks(Selector, 7)).

round_robin_reduces_cycle_by_common_divisor_test() ->
    Selector = lb_balancer:new(round_robin, [{a, 2}, {b, 4}]),
    ?assertEqual([b, a, b, b, a, b], lb_balancer_ctx:picks(Selector, 6)).

round_robin_retry_walks_forward_from_cursor_test() ->
    Selector = lb_balancer:new(round_robin, [{a, 1}, {b, 1}, {c, 1}]),
    Context = lb_balancer_ctx:new(#{start => 1, exclude => [b]}),
    ?assertEqual({ok, c}, lb_balancer:pick(Selector, Context)).

least_conn_prefers_less_loaded_backend_test() ->
    Selector = lb_balancer:new(least_conn, [{a, 1}, {b, 1}]),
    Context = lb_balancer_ctx:new(#{loads => #{a => 10, b => 3}}),
    ?assertEqual({ok, b}, lb_balancer:pick(Selector, Context)).

least_conn_scales_load_by_weight_test() ->
    %% a holds twice the connections of b but has three times the capacity
    Selector = lb_balancer:new(least_conn, [{a, 3}, {b, 1}]),
    Context = lb_balancer_ctx:new(#{loads => #{a => 4, b => 2}}),
    ?assertEqual({ok, a}, lb_balancer:pick(Selector, Context)).

least_conn_breaks_idle_tie_by_weight_test() ->
    Selector = lb_balancer:new(least_conn, [{a, 1}, {b, 2}]),
    ?assertEqual({ok, b}, lb_balancer:pick(Selector, lb_balancer_ctx:new())).

source_hash_is_sticky_per_key_test() ->
    Selector = lb_balancer:new(source_hash, [{a, 1}, {b, 1}, {c, 1}]),
    Picks = [lb_balancer_ctx:pick_by_key(Selector, {10, 0, 0, 7}) || _ <- lists:seq(1, 20)],
    ?assertMatch([{ok, _}], lists:usort(Picks)).

source_hash_fallback_matches_owner_after_removal_test() ->
    Backends = [{a, 1}, {b, 1}, {c, 1}],
    Key = {10, 0, 0, 7},
    Selector = lb_balancer:new(source_hash, Backends),
    {ok, Owner} = lb_balancer_ctx:pick_by_key(Selector, Key),
    Fallback = lb_balancer:pick(Selector, lb_balancer_ctx:new(#{key => Key, exclude => [Owner]})),
    Shrunk = lb_balancer:new(source_hash, lists:keydelete(Owner, 1, Backends)),
    ?assertEqual(lb_balancer_ctx:pick_by_key(Shrunk, Key), Fallback).

source_hash_spreads_keys_by_weight_test() ->
    Backends = [{a, 1}, {b, 2}, {c, 3}, {d, 4}],
    Selector = lb_balancer:new(source_hash, Backends),
    Keys = [{10, 0, X, Y} || X <- lists:seq(0, 99), Y <- lists:seq(0, 199)],
    Owned = lists:foldl(
        fun(Key, Acc) ->
            {ok, Owner} = lb_balancer_ctx:pick_by_key(Selector, Key),
            maps:update_with(Owner, fun(N) -> N + 1 end, 1, Acc)
        end,
        #{},
        Keys
    ),
    [
        ?assert(abs(maps:get(Id, Owned) / length(Keys) - Weight / 10) < 0.01)
     || {Id, Weight} <- Backends
    ].

properties_test_() ->
    Options = [{numtests, 300}, {to_file, user}],
    {timeout, 300, ?_assertEqual([], proper:module(prop_lb_balancer, Options))}.
