-module(lb_config_schema).

-export([validate/2, validate/3, format_error/1, format_path/1]).

-export_type([schema/0, field/0, type/0, path/0, reason/0, error/0]).

%% declarative validation for nested config maps: values are checked and
%% normalized, defaults are filled in, and every problem is reported in one pass
%% instead of failing on the first one

-type schema() :: #{atom() => field()}.
%% a field without a default is required
-type field() :: #{type := type(), default => term()}.
-type type() ::
    atom
    | boolean
    | {integer, integer(), integer() | infinity}
    | {enum, [atom()]}
    | ip_address
    | host
    | {list, type()}
    | {map, schema()}.

%% keys and list indexes leading from the root of the config to the bad value
-type path() :: [term()].
-type reason() :: missing_option | unknown_option | {invalid, binary(), term()}.
-type error() :: {path(), reason()}.

-spec validate(schema(), term()) -> {ok, map()} | {error, [error()]}.
validate(Schema, Value) ->
    validate(Schema, Value, []).

-spec validate(schema(), term(), path()) -> {ok, map()} | {error, [error()]}.
validate(Schema, Value, Path) when is_map(Value) ->
    Unknown = [
        {Path ++ [Key], unknown_option}
     || Key <- maps:keys(Value), not is_map_key(Key, Schema)
    ],
    {Fields, Errors} = maps:fold(
        fun(Key, Field, Acc) -> field(Key, Field, Value, Path, Acc) end,
        {#{}, Unknown},
        Schema
    ),
    case Errors of
        [] -> {ok, Fields};
        _ -> {error, lists:sort(Errors)}
    end;
validate(_Schema, Value, Path) ->
    {error, [{Path, {invalid, <<"a map">>, Value}}]}.

-spec format_error(error()) -> binary().
format_error({Path, missing_option}) ->
    text("~ts: required option is missing", [format_path(Path)]);
format_error({Path, unknown_option}) ->
    text("~ts: unknown option", [format_path(Path)]);
format_error({Path, {invalid, Expected, Value}}) ->
    text("~ts: expected ~ts, got ~0p", [format_path(Path), Expected, Value]).

-spec format_path(path()) -> binary().
format_path([]) ->
    <<"config">>;
format_path([Head | Tail]) ->
    unicode:characters_to_binary([head_segment(Head) | [tail_segment(S) || S <- Tail]]).

field(Key, Field, Value, Path, {Fields, Errors}) ->
    case maps:find(Key, Value) of
        {ok, Given} ->
            checked(Key, Field, Given, Path, Fields, Errors);
        error ->
            case Field of
                %% defaults go through the same checks, so a nested map default
                %% of #{} expands into the defaults of its own schema
                #{default := Default} -> checked(Key, Field, Default, Path, Fields, Errors);
                #{} -> {Fields, [{Path ++ [Key], missing_option} | Errors]}
            end
    end.

checked(Key, #{type := Type}, Value, Path, Fields, Errors) ->
    case check(Type, Value, Path ++ [Key]) of
        {ok, Checked} -> {Fields#{Key => Checked}, Errors};
        {error, Found} -> {Fields, Found ++ Errors}
    end.

check(atom, Value, _Path) when is_atom(Value) ->
    {ok, Value};
check(boolean, Value, _Path) when is_boolean(Value) ->
    {ok, Value};
check({integer, Min, Max}, Value, _Path) when
    is_integer(Value), Value >= Min, (Max =:= infinity orelse Value =< Max)
->
    {ok, Value};
check({enum, Allowed} = Type, Value, Path) when is_atom(Value) ->
    case lists:member(Value, Allowed) of
        true -> {ok, Value};
        false -> invalid(Type, Value, Path)
    end;
check(ip_address, Value, Path) ->
    case to_address(Value) of
        {ok, Address} -> {ok, Address};
        error -> invalid(ip_address, Value, Path)
    end;
check(host, Value, Path) ->
    case to_host(Value) of
        {ok, Host} -> {ok, Host};
        error -> invalid(host, Value, Path)
    end;
%% length/1 in the guard also rejects improper lists
check({list, Type}, Values, Path) when is_list(Values), length(Values) >= 0 ->
    entries(Type, Values, Path);
check({map, Schema}, Value, Path) when is_map(Value) ->
    validate(Schema, Value, Path);
check(Type, Value, Path) ->
    invalid(Type, Value, Path).

entries(Type, Values, Path) ->
    {Checked, Errors} = lists:foldl(
        fun({Index, Value}, {Acc, Found}) ->
            case check(Type, Value, Path ++ [Index]) of
                {ok, Ok} -> {[Ok | Acc], Found};
                {error, New} -> {Acc, New ++ Found}
            end
        end,
        {[], []},
        lists:enumerate(Values)
    ),
    case Errors of
        [] -> {ok, lists:reverse(Checked)};
        _ -> {error, Errors}
    end.

invalid(Type, Value, Path) ->
    {error, [{Path, {invalid, describe(Type), Value}}]}.

describe(atom) ->
    <<"an atom">>;
describe(boolean) ->
    <<"true or false">>;
describe({integer, Min, infinity}) ->
    text("an integer >= ~p", [Min]);
describe({integer, Min, Max}) ->
    text("an integer in ~p..~p", [Min, Max]);
describe({enum, Allowed}) ->
    text("one of ~ts", [lists:join(", ", [atom_to_list(A) || A <- Allowed])]);
describe(ip_address) ->
    <<"an ip address">>;
describe(host) ->
    <<"a host name or ip address">>;
describe({list, _Type}) ->
    <<"a list">>;
describe({map, _Schema}) ->
    <<"a map">>.

to_address(Value) when is_tuple(Value) ->
    case inet:is_ip_address(Value) of
        true -> {ok, Value};
        false -> error
    end;
to_address(Value) ->
    case to_text(Value) of
        {ok, Text} -> parse_address(Text);
        error -> error
    end.

%% host names stay lowercase strings, the form gen_tcp:connect takes
to_host(Value) when is_tuple(Value) ->
    to_address(Value);
to_host(Value) ->
    case to_text(Value) of
        {ok, Text} ->
            case parse_address(Text) of
                {ok, Address} -> {ok, Address};
                error -> host_name(string:lowercase(Text))
            end;
        error ->
            error
    end.

parse_address(Text) ->
    case inet:parse_strict_address(Text) of
        {ok, Address} -> {ok, Address};
        {error, einval} -> error
    end.

host_name(Text) ->
    Length = length(Text),
    case Length > 0 andalso Length =< 253 andalso lists:all(fun is_host_char/1, Text) of
        true -> {ok, Text};
        false -> error
    end.

is_host_char(Char) when Char >= $a, Char =< $z -> true;
is_host_char(Char) when Char >= $0, Char =< $9 -> true;
is_host_char(Char) -> Char =:= $- orelse Char =:= $. orelse Char =:= $_.

to_text(Value) when is_atom(Value) ->
    {ok, atom_to_list(Value)};
to_text(Value) when is_list(Value); is_binary(Value) ->
    try unicode:characters_to_list(Value) of
        Text when is_list(Text) -> {ok, Text};
        _Incomplete -> error
    catch
        error:badarg -> error
    end;
to_text(_Value) ->
    error.

head_segment(Segment) when is_atom(Segment) -> atom_to_list(Segment);
head_segment(Segment) -> io_lib:format("~0p", [Segment]).

tail_segment(Index) when is_integer(Index) -> io_lib:format("[~p]", [Index]);
tail_segment(Key) when is_atom(Key) -> [$. | atom_to_list(Key)];
tail_segment(Other) -> io_lib:format(".~0p", [Other]).

text(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
