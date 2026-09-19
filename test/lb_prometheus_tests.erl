-module(lb_prometheus_tests).

-include_lib("eunit/include/eunit.hrl").

renders_help_type_and_sorted_labels_test() ->
    Family = family(counter, [{#{route => <<"/a">>, code => 200}, 3}, {#{}, 1}]),
    ?assertEqual(
        <<
            "# HELP lb_requests_total Requests served.\n"
            "# TYPE lb_requests_total counter\n"
            "lb_requests_total{code=\"200\",route=\"/a\"} 3\n"
            "lb_requests_total 1\n"
        >>,
        render([Family])
    ).

escapes_label_values_test() ->
    Text = render([family(gauge, [{#{value => <<"a\"b\\c\nd">>}, 1}])]),
    ?assertNotEqual(nomatch, binary:match(Text, <<"{value=\"a\\\"b\\\\c\\nd\"} 1">>)).

escapes_help_text_test() ->
    Text = render([(family(gauge, []))#{help := <<"back\\slash\nnewline">>}]),
    ?assertNotEqual(
        nomatch, binary:match(Text, <<"# HELP lb_requests_total back\\\\slash\\nnewline\n">>)
    ).

keeps_the_header_of_an_empty_family_test() ->
    ?assertEqual(
        <<"# HELP lb_requests_total Requests served.\n# TYPE lb_requests_total gauge\n">>,
        render([family(gauge, [])])
    ).

formats_floats_and_atom_labels_test() ->
    ?assertEqual(
        <<"lb_requests_total{pool=\"web\"} 0.5\n">>,
        lists:last(lines(render([family(gauge, [{#{pool => web}, 0.5}])])))
    ).

family(Type, Samples) ->
    #{name => lb_requests_total, type => Type, help => <<"Requests served.">>, samples => Samples}.

render(Families) ->
    iolist_to_binary(lb_prometheus:format(Families)).

lines(Text) ->
    [<<Line/binary, "\n">> || Line <- binary:split(Text, <<"\n">>, [global, trim])].
