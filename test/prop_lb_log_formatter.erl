-module(prop_lb_log_formatter).

-include_lib("proper/include/proper.hrl").

%% whatever a report carries, keys included, the formatter writes exactly one
%% line of valid json, so no log call can break a log shipper downstream
prop_any_report_is_one_line_of_json() ->
    ?FORALL(
        {Key, Value},
        {any(), any()},
        begin
            Event = #{
                level => info,
                msg => {report, #{Key => Value, event => property}},
                meta => #{time => erlang:system_time(microsecond)}
            },
            Line = iolist_to_binary(lb_log_formatter:format(Event, #{})),
            case binary:split(Line, <<"\n">>) of
                [Json, <<>>] -> is_map(json:decode(Json));
                _MoreLines -> false
            end
        end
    ).
