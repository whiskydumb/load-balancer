-module(lb_log_formatter_tests).

-include_lib("eunit/include/eunit.hrl").

report_fields_become_top_level_keys_test() ->
    Object = format(warning, {report, #{event => backend_down, backend => <<"10.0.0.1:80">>}}, #{
        mfa => {lb_pool, observed, 4}
    }),
    ?assertMatch(
        #{
            <<"event">> := <<"backend_down">>,
            <<"backend">> := <<"10.0.0.1:80">>,
            <<"level">> := <<"warning">>,
            <<"mfa">> := <<"lb_pool:observed/4">>
        },
        Object
    ).

time_is_rfc3339_in_utc_test() ->
    ?assertMatch(
        #{<<"time">> := <<"1970-01-01T00:00:00.000000Z">>},
        format(info, {report, #{event => tick}}, #{})
    ).

standard_fields_win_over_report_fields_test() ->
    ?assertMatch(#{<<"level">> := <<"error">>}, format(error, {report, #{level => fake}}, #{})).

string_and_format_messages_become_msg_test_() ->
    [
        ?_assertMatch(#{<<"msg">> := <<"plain">>}, format(notice, {string, "plain"}, #{})),
        ?_assertMatch(#{<<"msg">> := <<"pool web">>}, format(notice, {"pool ~p", [web]}, #{}))
    ].

terms_without_json_notation_are_printed_test() ->
    Report = #{
        address => {{127, 0, 0, 1}, 80},
        owner => list_to_pid("<0.42.0>"),
        improper => [a | b],
        bytes => <<255, 0>>,
        {tuple, key} => ok
    },
    ?assertMatch(
        #{
            <<"address">> := <<"{{127,0,0,1},80}">>,
            <<"owner">> := <<"<0.42.0>">>,
            <<"improper">> := <<"[a|b]">>,
            <<"bytes">> := <<"<<255,0>>">>,
            <<"{tuple,key}">> := <<"ok">>
        },
        format(info, {report, Report}, #{})
    ).

charlists_become_strings_test() ->
    ?assertMatch(
        #{<<"tried">> := [<<"a">>, <<"b">>]},
        format(info, {report, #{tried => ["a", <<"b">>]}}, #{})
    ).

generic_report_callback_keeps_the_fields_test() ->
    Meta = #{report_cb => fun logger:format_otp_report/1},
    ?assertMatch(#{<<"event">> := <<"x">>}, format(info, {report, #{event => x}}, Meta)).

own_report_callback_turns_the_report_into_prose_test() ->
    Meta = #{report_cb => fun(#{child := Child}) -> {"child ~p died", [Child]} end},
    ?assertMatch(
        #{<<"msg">> := <<"child worker died">>}, format(error, {report, #{child => worker}}, Meta)
    ).

%% the newline inside the message is escaped, the only raw one ends the line
every_event_is_one_line_test() ->
    Line = iolist_to_binary(lb_log_formatter:format(event(info, {string, "two\nlines"}, #{}), #{})),
    ?assertMatch([_Json, <<>>], binary:split(Line, <<"\n">>)).

properties_test_() ->
    Options = [{numtests, 500}, {to_file, user}],
    {timeout, 120, ?_assertEqual([], proper:module(prop_lb_log_formatter, Options))}.

format(Level, Message, Meta) ->
    Line = iolist_to_binary(lb_log_formatter:format(event(Level, Message, Meta), #{})),
    json:decode(string:trim(Line, trailing, "\n")).

event(Level, Message, Meta) ->
    #{level => Level, msg => Message, meta => maps:merge(#{time => 0}, Meta)}.
