-module(lb_log_formatter).

-export([format/2, check_config/1]).

%% logger formatter that writes one json object per line for log shippers.
%% report fields become top level keys; terms json has no notation for, such as
%% tuples, pids or invalid utf-8, are written the way erlang prints them, so a
%% log call can never crash the formatter

%% keeps a huge or deeply nested term from flooding the log
-define(PRINT_DEPTH, 20).

-spec check_config(logger:formatter_config()) -> ok | {error, term()}.
check_config(Config) when is_map(Config) ->
    ok;
check_config(Config) ->
    {error, {invalid_formatter_config, Config}}.

-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(#{level := Level, msg := Message, meta := Meta}, _Config) ->
    Standard = maps:merge(location(Meta), #{time => timestamp(Meta), level => Level}),
    %% standard fields win over report fields with the same name
    Object = maps:merge(message(Message, Meta), Standard),
    [json:encode(Object, fun encode/2), $\n].

message({report, Report}, Meta) ->
    case report_callback(Meta) of
        generic when is_map(Report) -> Report;
        generic -> #{msg => printed(Report)};
        Callback -> #{msg => render(Callback, Report)}
    end;
message({string, String}, _Meta) ->
    #{msg => unicode:characters_to_binary(String)};
message({Format, Args}, _Meta) ->
    #{msg => text(Format, Args)}.

%% logger attaches its generic callback to every plain map report, which keeps
%% the report fields; only a callback of the reporting module, like those on
%% otp supervisor and crash reports, turns the report into prose
report_callback(#{report_cb := Callback}) ->
    case lists:member(Callback, [fun logger:format_otp_report/1, fun logger:format_report/1]) of
        true -> generic;
        false -> Callback
    end;
report_callback(#{}) ->
    generic.

render(Callback, Report) when is_function(Callback, 1) ->
    {Format, Args} = Callback(Report),
    text(Format, Args);
render(Callback, Report) when is_function(Callback, 2) ->
    Options = #{single_line => true, depth => unlimited, chars_limit => unlimited},
    unicode:characters_to_binary(Callback(Report, Options)).

timestamp(#{time := Time}) ->
    Options = [{unit, microsecond}, {offset, "Z"}],
    list_to_binary(calendar:system_time_to_rfc3339(Time, Options)).

location(Meta) ->
    maps:from_list(
        [{mfa, text("~ts:~ts/~b", [M, F, A])} || #{mfa := {M, F, A}} <- [Meta]] ++
            [{pid, text("~p", [Pid])} || #{pid := Pid} <- [Meta]]
    ).

%% json:encode/2 hands every value to this function
encode(Value, Encode) when is_map(Value) ->
    Keyed = maps:fold(fun(Key, Item, Acc) -> Acc#{key(Key) => Item} end, #{}, Value),
    json:encode_map(Keyed, Encode);
%% the length guard fails for improper lists, which fall through to printing
encode(Value, Encode) when is_list(Value), length(Value) >= 0 ->
    case io_lib:printable_unicode_list(Value) of
        true -> json:encode_binary(unicode:characters_to_binary(Value));
        false -> json:encode_list(Value, Encode)
    end;
encode(Value, _Encode) when is_binary(Value) ->
    json:encode_binary(utf8(Value));
encode(Value, Encode) when is_atom(Value); is_number(Value) ->
    json:encode_value(Value, Encode);
encode(Value, _Encode) ->
    json:encode_binary(printed(Value)).

key(Key) when is_atom(Key); is_integer(Key) -> Key;
key(Key) when is_binary(Key) -> utf8(Key);
key(Key) -> printed(Key).

utf8(Binary) ->
    case unicode:characters_to_binary(Binary) of
        Binary -> Binary;
        _Invalid -> printed(Binary)
    end.

printed(Term) ->
    text("~0P", [Term, ?PRINT_DEPTH]).

text(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
