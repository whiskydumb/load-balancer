-module(lb_proxy_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    relays_data_both_ways/1,
    survives_a_backend_that_writes_before_reading/1,
    forwards_half_close/1,
    spreads_connections_across_backends/1,
    keeps_a_client_on_one_backend_with_source_hash/1,
    retries_another_backend_when_one_refuses/1,
    closes_the_client_when_no_backend_is_available/1,
    closes_idle_connections/1,
    holds_clients_beyond_max_connections/1,
    releases_listener_slots_when_clients_leave/1
]).

%% the whole application against real sockets: echo backends, one that talks
%% before it listens, and a port where nothing listens

all() ->
    [
        relays_data_both_ways,
        survives_a_backend_that_writes_before_reading,
        forwards_half_close,
        spreads_connections_across_backends,
        keeps_a_client_on_one_backend_with_source_hash,
        retries_another_backend_when_one_refuses,
        closes_the_client_when_no_backend_is_available,
        closes_idle_connections,
        holds_clients_beyond_max_connections,
        releases_listener_slots_when_clients_leave
    ].

init_per_suite(Config) ->
    A = lb_test_backend:start(),
    B = lb_test_backend:start(),
    Speaker = lb_test_backend:start(0, preamble()),
    Backends = #{
        a => maps:get(backend, A),
        b => maps:get(backend, B),
        speaker => maps:get(backend, Speaker),
        dead => {{127, 0, 0, 1}, lb_test_backend:reserve_port()}
    },
    case application:load(lb) of
        ok -> ok;
        {error, {already_loaded, lb}} -> ok
    end,
    ok = application:set_env(lb, pools, pools(Backends)),
    ok = application:set_env(lb, listeners, listeners()),
    {ok, Started} = application:ensure_all_started(lb),
    [{servers, [A, B, Speaker]}, {backends, Backends}, {started, Started} | Config].

end_per_suite(Config) ->
    lists:foreach(fun application:stop/1, lists:reverse(?config(started, Config))),
    ok = application:unload(lb),
    lists:foreach(fun lb_test_backend:stop/1, ?config(servers, Config)).

relays_data_both_ways(_Config) ->
    Socket = connect(echo),
    ?assertEqual(<<"ping">>, echo(Socket, <<"ping">>)),
    ?assertEqual(<<"pong">>, echo(Socket, <<"pong">>)),
    ok = gen_tcp:close(Socket).

%% a single relay loop deadlocks here: it blocks sending the upload to a
%% backend that is busy writing, and so never reads what that backend writes
survives_a_backend_that_writes_before_reading(_Config) ->
    Preamble = preamble(),
    Upload = rand:bytes(byte_size(Preamble)),
    Socket = connect(speaker),
    Self = self(),
    _ = spawn_link(fun() -> Self ! {uploaded, gen_tcp:send(Socket, Upload)} end),
    {ok, Received} = gen_tcp:recv(Socket, 2 * byte_size(Preamble), 20000),
    ?assert(Received =:= <<Preamble/binary, Upload/binary>>),
    receive
        {uploaded, Sent} -> ?assertEqual(ok, Sent)
    after 5000 -> ct:fail(upload_stuck)
    end,
    ok = gen_tcp:close(Socket).

forwards_half_close(_Config) ->
    Socket = connect(echo),
    ok = gen_tcp:send(Socket, <<"last words">>),
    ok = gen_tcp:shutdown(Socket, write),
    ?assertEqual({ok, <<"last words">>}, gen_tcp:recv(Socket, 10, 2000)),
    ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 2000)).

spreads_connections_across_backends(Config) ->
    #{a := A, b := B} = ?config(backends, Config),
    ?assert(settled(echo, #{A => 0, B => 0})),
    Sockets = open_many(echo, 4),
    ?assertEqual(#{A => 2, B => 2}, active(echo)),
    lists:foreach(fun gen_tcp:close/1, Sockets).

keeps_a_client_on_one_backend_with_source_hash(_Config) ->
    Sockets = open_many(sticky, 4),
    ?assertEqual([0, 4], lists:sort(maps:values(active(sticky)))),
    lists:foreach(fun gen_tcp:close/1, Sockets).

retries_another_backend_when_one_refuses(Config) ->
    #{dead := Dead} = ?config(backends, Config),
    Socket = connect(flaky),
    ?assertEqual(<<"ping">>, echo(Socket, <<"ping">>)),
    %% the refused attempt counts against the backend like a failed probe
    ?assert(
        lb_pool_fixture:eventually(fun() -> lb_pool_fixture:health(flaky, Dead) =:= down end)
    ),
    ok = gen_tcp:close(Socket).

closes_the_client_when_no_backend_is_available(_Config) ->
    Socket = connect(broken),
    ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 5000)).

closes_idle_connections(_Config) ->
    Socket = connect(idle),
    ?assertEqual(<<"ping">>, echo(Socket, <<"ping">>)),
    Quiet = erlang:monotonic_time(millisecond),
    ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 5000)),
    ?assert(erlang:monotonic_time(millisecond) - Quiet >= 800).

holds_clients_beyond_max_connections(_Config) ->
    [First, Second] = open_many(tight, 2),
    %% the handshake completes in the kernel backlog, but no proxy serves it
    Third = connect(tight),
    ok = gen_tcp:send(Third, <<"late">>),
    ?assertEqual({error, timeout}, gen_tcp:recv(Third, 4, 300)),
    ok = gen_tcp:close(First),
    ?assertEqual({ok, <<"late">>}, gen_tcp:recv(Third, 4, 2000)),
    lists:foreach(fun gen_tcp:close/1, [Second, Third]).

releases_listener_slots_when_clients_leave(_Config) ->
    ?assert(lb_pool_fixture:eventually(fun() -> lb_listener:connections(echo) =:= 0 end)),
    Sockets = open_many(echo, 3),
    ?assertEqual(3, lb_listener:connections(echo)),
    lists:foreach(fun gen_tcp:close/1, Sockets),
    ?assert(lb_pool_fixture:eventually(fun() -> lb_listener:connections(echo) =:= 0 end)).

%% well past what socket buffers absorb, so a relay that cannot move both
%% directions independently gets stuck. regenerated from a fixed seed rather
%% than kept in the suite config, which common test prints into every case log
preamble() ->
    _ = rand:seed(exsss, {16, 16, 16}),
    rand:bytes(16 * 1024 * 1024).

pools(#{a := A, b := B, speaker := Speaker, dead := Dead}) ->
    Unchecked = #{enabled => false},
    [
        pool(echo, round_robin, [A, B], Unchecked),
        pool(sticky, source_hash, [A, B], Unchecked),
        pool(speaker, round_robin, [Speaker], Unchecked),
        %% failed connects count only while checks are on; the long interval
        %% keeps probes from racing the test
        pool(flaky, round_robin, [Dead, A], #{interval => 600000, rise => 1, fall => 1}),
        pool(broken, round_robin, [Dead], Unchecked)
    ].

%% a short connect timeout, because windows retries a refused syn for a second
pool(Name, Strategy, Backends, HealthCheck) ->
    #{
        name => Name,
        strategy => Strategy,
        connect_timeout => 300,
        backends => [#{host => Host, port => Port} || {Host, Port} <- Backends],
        health_check => HealthCheck
    }.

listeners() ->
    [
        listener(echo, echo, #{}),
        listener(sticky, sticky, #{}),
        listener(speaker, speaker, #{}),
        listener(flaky, flaky, #{connect_attempts => 2}),
        listener(broken, broken, #{}),
        listener(idle, echo, #{idle_timeout => 1000}),
        listener(tight, echo, #{max_connections => 2, acceptors => 1})
    ].

listener(Name, Pool, Overrides) ->
    maps:merge(#{name => Name, pool => Pool, ip => "127.0.0.1", port => 0}, Overrides).

connect(Listener) ->
    Port = lb_listener:port(Listener),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    Socket.

%% a round trip on each connection proves its proxy reached a backend
open_many(Listener, Count) ->
    Sockets = [connect(Listener) || _ <- lists:seq(1, Count)],
    lists:foreach(fun(Socket) -> <<"x">> = echo(Socket, <<"x">>) end, Sockets),
    Sockets.

echo(Socket, Bytes) ->
    ok = gen_tcp:send(Socket, Bytes),
    {ok, Echoed} = gen_tcp:recv(Socket, byte_size(Bytes), 2000),
    Echoed.

active(Pool) ->
    {ok, Statuses} = lb_pool:backends(Pool),
    maps:from_list([{Backend, Active} || #{backend := Backend, active := Active} <- Statuses]).

settled(Pool, Expected) ->
    lb_pool_fixture:eventually(fun() -> active(Pool) =:= Expected end).
