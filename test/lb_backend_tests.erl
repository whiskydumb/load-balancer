-module(lb_backend_tests).

-include_lib("eunit/include/eunit.hrl").

format_test_() ->
    [
        ?_assertEqual(<<"10.0.0.1:9000">>, lb_backend:format({{10, 0, 0, 1}, 9000})),
        ?_assertEqual(<<"[::1]:9000">>, lb_backend:format({{0, 0, 0, 0, 0, 0, 0, 1}, 9000})),
        ?_assertEqual(<<"db.internal:5432">>, lb_backend:format({"db.internal", 5432}))
    ].

parse_test_() ->
    [
        ?_assertEqual({ok, {{10, 0, 0, 1}, 9000}}, lb_backend:parse(<<"10.0.0.1:9000">>)),
        ?_assertEqual({ok, {{0, 0, 0, 0, 0, 0, 0, 1}, 9000}}, lb_backend:parse(<<"[::1]:9000">>)),
        ?_assertEqual({ok, {"db.internal", 5432}}, lb_backend:parse(<<"DB.Internal:5432">>)),
        ?_assertEqual({error, invalid_backend}, lb_backend:parse(<<"10.0.0.1">>)),
        ?_assertEqual({error, invalid_backend}, lb_backend:parse(<<"10.0.0.1:http">>)),
        ?_assertEqual({error, invalid_backend}, lb_backend:parse(<<"10.0.0.1:70000">>))
    ].

parse_reads_what_format_writes_test_() ->
    Ids = [{{10, 0, 0, 1}, 80}, {{0, 0, 0, 0, 0, 0, 0, 1}, 443}, {"db.internal", 5432}],
    [?_assertEqual({ok, Id}, lb_backend:parse(lb_backend:format(Id))) || Id <- Ids].
