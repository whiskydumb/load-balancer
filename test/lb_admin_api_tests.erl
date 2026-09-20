-module(lb_admin_api_tests).

-include_lib("eunit/include/eunit.hrl").

%% routing and authorization; the handlers behind a valid token read live
%% state and are covered by lb_admin_SUITE

-define(TOKEN, <<"s3cret">>).

health_needs_no_token_test() ->
    ?assertMatch(#{status := 200}, handle('GET', <<"/health">>, #{}, undefined)).

protected_route_is_closed_without_a_configured_token_test() ->
    ?assertMatch(#{status := 403}, handle('GET', <<"/metrics">>, bearer(?TOKEN), undefined)).

missing_token_is_challenged_test() ->
    #{status := Status, headers := Headers} = handle('GET', <<"/metrics">>, #{}, digest(?TOKEN)),
    ?assertEqual(401, Status),
    ?assertEqual(<<"Bearer">>, proplists:get_value(<<"www-authenticate">>, Headers)).

wrong_token_is_rejected_test() ->
    ?assertMatch(
        #{status := 401}, handle('GET', <<"/pools">>, bearer(<<"guess">>), digest(?TOKEN))
    ).

other_schemes_are_rejected_test() ->
    Basic = #{<<"authorization">> => <<"Basic czNjcmV0">>},
    ?assertMatch(#{status := 401}, handle('GET', <<"/pools">>, Basic, digest(?TOKEN))).

unknown_path_is_not_found_test() ->
    ?assertMatch(#{status := 404}, handle('GET', <<"/secrets">>, bearer(?TOKEN), digest(?TOKEN))).

wrong_method_is_not_allowed_test() ->
    ?assertMatch(#{status := 405}, handle('DELETE', <<"/health">>, #{}, undefined)).

backend_routes_check_the_method_test_() ->
    [
        ?_assertMatch(#{status := 405}, handle('GET', <<"/pools/web/backends">>, #{}, undefined)),
        ?_assertMatch(
            #{status := 405}, handle('GET', <<"/pools/web/backends/10.0.0.1:80">>, #{}, undefined)
        ),
        ?_assertMatch(
            #{status := 405},
            handle('DELETE', <<"/pools/web/backends/10.0.0.1:80/drain">>, #{}, undefined)
        )
    ].

responses_are_never_cached_test() ->
    #{headers := Headers} = handle('GET', <<"/health">>, #{}, undefined),
    ?assertEqual(<<"no-store">>, proplists:get_value(<<"cache-control">>, Headers)).

handle(Method, Path, Headers, Token) ->
    Request = #{method => Method, path => Path, headers => Headers, body => <<>>},
    lb_admin_api:handle(Request, Token).

bearer(Token) ->
    #{<<"authorization">> => <<"Bearer ", Token/binary>>}.

digest(Token) ->
    crypto:hash(sha256, Token).
