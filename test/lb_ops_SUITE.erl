-module(lb_ops_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    adds_and_removes_backends_over_the_api/1,
    explains_rejected_backends/1,
    drained_backend_keeps_its_connections/1,
    stop_waits_for_open_connections/1,
    stop_cuts_connections_left_after_the_drain_timeout/1
]).

%% operating a running node: backends changed through the admin api, and an
%% orderly stop that drains the open connections

-define(TOKEN, "ops-token").
-define(DRAIN_TIMEOUT, 1000).

all() ->
    [
        adds_and_removes_backends_over_the_api,
        explains_rejected_backends,
        drained_backend_keeps_its_connections,
        stop_waits_for_open_connections,
        stop_cuts_connections_left_after_the_drain_timeout
    ].

init_per_suite(Config) ->
    true = os:putenv("LB_ADMIN_TOKEN", ?TOKEN),
    [{servers, [lb_test_backend:start() || _ <- [a, b, spare]]} | Config].

end_per_suite(Config) ->
    true = os:unsetenv("LB_ADMIN_TOKEN"),
    lists:foreach(fun lb_test_backend:stop/1, ?config(servers, Config)).

%% a fresh node for every case, since some of them stop it
init_per_testcase(_Case, Config) ->
    [{AHost, APort}, {BHost, BPort}, _Spare] = backends(Config),
    case application:load(lb) of
        ok -> ok;
        {error, {already_loaded, lb}} -> ok
    end,
    ok = application:set_env(lb, pools, [
        #{
            name => web,
            backends => [#{host => AHost, port => APort}, #{host => BHost, port => BPort}],
            health_check => #{enabled => false}
        }
    ]),
    ok = application:set_env(lb, listeners, [
        #{
            name => front,
            pool => web,
            ip => "127.0.0.1",
            port => 0,
            drain_timeout => ?DRAIN_TIMEOUT
        }
    ]),
    ok = application:set_env(lb, admin, #{enabled => true, port => 0}),
    {ok, Started} = application:ensure_all_started(lb),
    [{started, Started} | Config].

%% stopping twice is harmless for the cases that already stopped the node
end_per_testcase(_Case, Config) ->
    lists:foreach(
        fun(App) -> _ = application:stop(App) end, lists:reverse(?config(started, Config))
    ),
    ok = application:unload(lb).

adds_and_removes_backends_over_the_api(Config) ->
    [_A, _B, Spare] = backends(Config),
    Name = lb_backend:format(Spare),
    ?assertMatch({201, #{<<"added">> := Name}}, api("POST", "/pools/web/backends", body(Spare))),
    ?assertEqual(3, length(pool_backends())),
    %% round robin over three backends gives the new one every third client
    Sockets = open_many(3),
    ?assertEqual(1, maps:get(Spare, active())),
    ?assertMatch({200, #{<<"removed">> := Name}}, api("DELETE", backend_path(Spare), <<>>)),
    ?assertEqual(2, length(pool_backends())),
    lists:foreach(fun gen_tcp:close/1, Sockets).

explains_rejected_backends(Config) ->
    [A, _B, _Spare] = backends(Config),
    Invalid = <<"{\"host\": \"127.0.0.1\", \"port\": 70000, \"colour\": \"red\"}">>,
    {400, #{<<"problems">> := Problems}} = api("POST", "/pools/web/backends", Invalid),
    ?assertEqual(
        [<<"colour: unknown option">>, <<"port: expected an integer in 1..65535, got 70000">>],
        lists:sort(Problems)
    ),
    ?assertMatch({400, _}, api("POST", "/pools/web/backends", <<"not json">>)),
    ?assertMatch({409, _}, api("POST", "/pools/web/backends", body(A))),
    ?assertMatch({404, _}, api("POST", "/pools/nope/backends", body(A))),
    ?assertMatch({404, _}, api("DELETE", "/pools/web/backends/10.9.9.9:1", <<>>)),
    ?assertMatch({413, _}, api("POST", "/pools/web/backends", binary:copy(<<"x">>, 20000))).

drained_backend_keeps_its_connections(Config) ->
    [A, B, _Spare] = backends(Config),
    %% the first client of a fresh pool lands on the first backend
    [Open] = open_many(1),
    ?assertEqual(#{A => 1, B => 0}, active()),
    ?assertMatch(
        {200, #{<<"admin">> := <<"draining">>}}, api("POST", backend_path(A, "/drain"), <<>>)
    ),
    Fresh = open_many(2),
    ?assertEqual(#{A => 1, B => 2}, active()),
    ?assertEqual(<<"still here">>, echo(Open, <<"still here">>)),
    ?assertMatch(
        {200, #{<<"admin">> := <<"enabled">>}}, api("POST", backend_path(A, "/enable"), <<>>)
    ),
    lists:foreach(fun gen_tcp:close/1, [Open | Fresh]).

stop_waits_for_open_connections(_Config) ->
    [Open] = open_many(1),
    Port = lb_listener:port(front),
    ok = stop_in_background(),
    %% the listener closes its socket first, so newcomers are turned away
    ?assert(lb_pool_fixture:eventually(fun() -> refused(Port) end)),
    ?assertEqual(<<"still served">>, echo(Open, <<"still served">>)),
    ok = gen_tcp:close(Open),
    %% the node stops as soon as the last connection is gone
    ?assert(stopped_within(?DRAIN_TIMEOUT)).

stop_cuts_connections_left_after_the_drain_timeout(_Config) ->
    [Open] = open_many(1),
    ok = stop_in_background(),
    ?assertEqual({error, closed}, gen_tcp:recv(Open, 0, 3 * ?DRAIN_TIMEOUT)),
    receive
        {stopped, Took} -> ?assert(Took >= ?DRAIN_TIMEOUT - 50)
    after 5000 -> ct:fail(stop_did_not_finish)
    end.

backends(Config) ->
    [maps:get(backend, Server) || Server <- ?config(servers, Config)].

body({Host, Port}) ->
    json:encode(#{host => list_to_binary(inet:ntoa(Host)), port => Port}).

backend_path(Backend) ->
    backend_path(Backend, "").

backend_path(Backend, Action) ->
    ["/pools/web/backends/", lb_backend:format(Backend), Action].

api(Method, Path, Body) ->
    {Status, _Headers, Response} = lb_test_http:request(Method, Path, ?TOKEN, Body),
    {Status, json:decode(Response)}.

pool_backends() ->
    {200, #{<<"pools">> := [#{<<"backends">> := Backends}]}} = api("GET", "/pools", <<>>),
    Backends.

active() ->
    {ok, Statuses} = lb_pool:backends(web),
    maps:from_list([{Backend, Active} || #{backend := Backend, active := Active} <- Statuses]).

%% a round trip on each connection proves its proxy reached a backend
open_many(Count) ->
    Port = lb_listener:port(front),
    Sockets = [connect(Port) || _ <- lists:seq(1, Count)],
    lists:foreach(fun(Socket) -> <<"x">> = echo(Socket, <<"x">>) end, Sockets),
    Sockets.

connect(Port) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    Socket.

echo(Socket, Bytes) ->
    ok = gen_tcp:send(Socket, Bytes),
    {ok, Echoed} = gen_tcp:recv(Socket, byte_size(Bytes), 2000),
    Echoed.

%% windows answers a closed port only after retrying the syn, so any failure
%% within the short timeout counts as refused
refused(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary], 200) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            false;
        {error, _Refused} ->
            true
    end.

stop_in_background() ->
    Parent = self(),
    Started = erlang:monotonic_time(millisecond),
    _ = spawn_link(fun() ->
        ok = application:stop(lb),
        Parent ! {stopped, erlang:monotonic_time(millisecond) - Started}
    end),
    ok.

stopped_within(Budget) ->
    receive
        {stopped, Took} -> Took < Budget
    after 5000 -> false
    end.
