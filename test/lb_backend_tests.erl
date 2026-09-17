-module(lb_backend_tests).

-include_lib("eunit/include/eunit.hrl").

format_test_() ->
    [
        ?_assertEqual(<<"10.0.0.1:9000">>, lb_backend:format({{10, 0, 0, 1}, 9000})),
        ?_assertEqual(<<"[::1]:9000">>, lb_backend:format({{0, 0, 0, 0, 0, 0, 0, 1}, 9000})),
        ?_assertEqual(<<"db.internal:5432">>, lb_backend:format({"db.internal", 5432}))
    ].
