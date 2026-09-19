-module(lb_admin_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    health_answers_without_a_token/1,
    protected_routes_need_the_token/1,
    metrics_follow_proxied_traffic/1,
    pools_and_listeners_are_reported_as_json/1,
    unknown_routes_and_methods_are_rejected/1,
    malformed_requests_get_bad_request/1
]).

%% the admin api over real http, next to a proxied echo backend

-define(TOKEN, "token-for-tests").

all() ->
    [
        health_answers_without_a_token,
        protected_routes_need_the_token,
        metrics_follow_proxied_traffic,
        pools_and_listeners_are_reported_as_json,
        unknown_routes_and_methods_are_rejected,
        malformed_requests_get_bad_request
    ].

init_per_suite(Config) ->
    #{backend := {Host, Port}} = Backend = lb_test_backend:start(),
    true = os:putenv("LB_ADMIN_TOKEN", ?TOKEN),
    case application:load(lb) of
        ok -> ok;
        {error, {already_loaded, lb}} -> ok
    end,
    ok = application:set_env(lb, pools, [
        #{
            name => echo,
            backends => [#{host => Host, port => Port}],
            health_check => #{enabled => false}
        }
    ]),
    ok = application:set_env(lb, listeners, [
        #{name => front, pool => echo, ip => "127.0.0.1", port => 0}
    ]),
    ok = application:set_env(lb, admin, #{enabled => true, port => 0}),
    {ok, Started} = application:ensure_all_started(lb),
    [{server, Backend}, {started, Started} | Config].

end_per_suite(Config) ->
    lists:foreach(fun application:stop/1, lists:reverse(?config(started, Config))),
    ok = application:unload(lb),
    true = os:unsetenv("LB_ADMIN_TOKEN"),
    lb_test_backend:stop(?config(server, Config)).

health_answers_without_a_token(_Config) ->
    ?assertMatch({200, _, #{<<"status">> := <<"ok">>}}, get_json("/health", none)).

protected_routes_need_the_token(_Config) ->
    {Status, Headers, _Body} = request("GET", "/metrics", none),
    ?assertEqual(401, Status),
    ?assertEqual(<<"Bearer">>, header(<<"www-authenticate">>, Headers)),
    ?assertMatch({401, _, _}, request("GET", "/metrics", "not-the-token")),
    ?assertMatch({200, _, _}, request("GET", "/metrics", ?TOKEN)).

metrics_follow_proxied_traffic(Config) ->
    Socket = connect(front),
    ok = gen_tcp:send(Socket, <<"hello">>),
    ?assertEqual({ok, <<"hello">>}, gen_tcp:recv(Socket, 5, 2000)),
    ok = gen_tcp:close(Socket),
    ?assert(lb_pool_fixture:eventually(fun() -> lb_listener:connections(front) =:= 0 end)),
    {200, Headers, Body} = request("GET", "/metrics", ?TOKEN),
    ?assertEqual(
        <<"text/plain; version=0.0.4; charset=utf-8">>, header(<<"content-type">>, Headers)
    ),
    Lines = binary:split(Body, <<"\n">>, [global]),
    #{backend := Backend} = ?config(server, Config),
    Labels = <<"{backend=\"", (lb_backend:format(Backend))/binary, "\",pool=\"echo\"}">>,
    Expected = [
        <<"lb_listener_connections_accepted_total{listener=\"front\"} 1">>,
        <<"lb_listener_bytes_total{direction=\"upstream\",listener=\"front\"} 5">>,
        <<"lb_listener_bytes_total{direction=\"downstream\",listener=\"front\"} 5">>,
        <<"lb_backend_up", Labels/binary, " 1">>,
        <<"lb_backend_connections_total", Labels/binary, " 1">>
    ],
    ?assertEqual([], Expected -- Lines).

pools_and_listeners_are_reported_as_json(_Config) ->
    {200, _, #{<<"pools">> := [Pool]}} = get_json("/pools", ?TOKEN),
    ?assertMatch(
        #{<<"name">> := <<"echo">>, <<"backends">> := [#{<<"health">> := <<"up">>}]},
        Pool
    ),
    {200, _, #{<<"listeners">> := [Listener]}} = get_json("/listeners", ?TOKEN),
    ?assertMatch(#{<<"name">> := <<"front">>, <<"port">> := Port} when is_integer(Port), Listener).

unknown_routes_and_methods_are_rejected(_Config) ->
    ?assertMatch({404, _, _}, request("GET", "/nothing-here", ?TOKEN)),
    ?assertMatch({405, _, _}, request("POST", "/metrics", ?TOKEN)).

malformed_requests_get_bad_request(_Config) ->
    ?assertMatch({400, _, _}, exchange(<<"NONSENSE\r\n\r\n">>)),
    Flood = [[<<"x-header-">>, integer_to_binary(N), <<": v\r\n">>] || N <- lists:seq(1, 100)],
    ?assertMatch({400, _, _}, exchange([<<"GET /health HTTP/1.1\r\n">>, Flood, <<"\r\n">>])).

connect(Listener) ->
    Port = lb_listener:port(Listener),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    Socket.

get_json(Path, Token) ->
    {Status, Headers, Body} = request("GET", Path, Token),
    {Status, Headers, json:decode(Body)}.

request(Method, Path, Token) ->
    exchange([Method, " ", Path, " HTTP/1.1\r\nhost: lb\r\n", authorization(Token), "\r\n"]).

authorization(none) -> [];
authorization(Token) -> ["authorization: Bearer ", Token, "\r\n"].

%% one request per connection: the server answers and closes
exchange(Request) ->
    {ok, Socket} = gen_tcp:connect(
        {127, 0, 0, 1}, lb_admin:port(), [binary, {active, false}], 1000
    ),
    ok = gen_tcp:send(Socket, Request),
    parse(read_all(Socket, <<>>)).

read_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Data} -> read_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

parse(Response) ->
    [Head, Body] = binary:split(Response, <<"\r\n\r\n">>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, Code | _Reason] = binary:split(StatusLine, <<" ">>, [global]),
    Headers = [list_to_tuple(binary:split(Line, <<": ">>)) || Line <- HeaderLines],
    {binary_to_integer(Code), Headers, Body}.

header(Name, Headers) ->
    proplists:get_value(Name, Headers).
