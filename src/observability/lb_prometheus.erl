-module(lb_prometheus).

-export([format/1]).

-export_type([family/0, labels/0]).

%% renders metric families in the prometheus text exposition format, version
%% 0.0.4: a HELP and a TYPE line per family, then one line per sample

-type labels() :: #{atom() => atom() | binary() | integer()}.
-type family() :: #{
    name := atom(),
    type := counter | gauge,
    help := binary(),
    samples := [{labels(), number()}]
}.

-spec format([family()]) -> iolist().
format(Families) ->
    [family(Family) || Family <- Families].

family(#{name := Name, type := Type, help := Help, samples := Samples}) ->
    Metric = atom_to_binary(Name),
    [
        [<<"# HELP ">>, Metric, $\s, escape_help(Help), $\n],
        [<<"# TYPE ">>, Metric, $\s, atom_to_binary(Type), $\n],
        [[Metric, labels(Labels), $\s, number(Value), $\n] || {Labels, Value} <- Samples]
    ].

%% sorted by name, so the output is stable between scrapes
labels(Labels) when map_size(Labels) =:= 0 ->
    [];
labels(Labels) ->
    Pairs = [
        [atom_to_binary(Key), <<"=\"">>, escape_label(text(Value)), $"]
     || {Key, Value} <- lists:sort(maps:to_list(Labels))
    ],
    [${, lists:join($,, Pairs), $}].

number(Value) when is_integer(Value) -> integer_to_binary(Value);
number(Value) when is_float(Value) -> float_to_binary(Value, [short]).

text(Value) when is_atom(Value) -> atom_to_binary(Value);
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) when is_binary(Value) -> Value.

escape_help(Help) ->
    escape(Help, [{<<"\\">>, <<"\\\\">>}, {<<"\n">>, <<"\\n">>}]).

escape_label(Value) ->
    escape(Value, [{<<"\\">>, <<"\\\\">>}, {<<"\"">>, <<"\\\"">>}, {<<"\n">>, <<"\\n">>}]).

%% the backslash goes first, so later replacements are not escaped twice
escape(Text, Replacements) ->
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Text,
        Replacements
    ).
