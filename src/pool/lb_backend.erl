-module(lb_backend).

-export([id/1, format/1, parse/1]).

-export_type([id/0]).

%% a backend is identified by its address, which the config has normalized
-type id() :: {lb_config:host(), inet:port_number()}.

-spec id(lb_config:backend()) -> id().
id(#{host := Host, port := Port}) ->
    {Host, Port}.

%% "10.0.0.1:80", "[::1]:80" or "db.internal:80", for logs and metric labels
-spec format(id()) -> binary().
format({Host, Port}) when tuple_size(Host) =:= 8 ->
    iolist_to_binary([$[, inet:ntoa(Host), "]:", integer_to_list(Port)]);
format({Host, Port}) when is_tuple(Host) ->
    iolist_to_binary([inet:ntoa(Host), $:, integer_to_list(Port)]);
format({Host, Port}) ->
    iolist_to_binary([Host, $:, integer_to_list(Port)]).

%% reads what format/1 writes, normalized the way the config file is
-spec parse(binary()) -> {ok, id()} | {error, invalid_backend}.
parse(Text) ->
    case string:split(Text, ":", trailing) of
        [Host, Port] ->
            case lb_config:validate_backend(#{host => unbracket(Host), port => integer(Port)}) of
                {ok, Backend} -> {ok, id(Backend)};
                {error, _Problems} -> {error, invalid_backend}
            end;
        _NoPort ->
            {error, invalid_backend}
    end.

%% ipv6 addresses are bracketed so their colons stay apart from the port
unbracket(<<$[, _/binary>> = Host) when byte_size(Host) > 2 ->
    case binary:last(Host) of
        $] -> binary:part(Host, 1, byte_size(Host) - 2);
        _Unclosed -> Host
    end;
unbracket(Host) ->
    Host.

%% anything that is not a number is left for the validation to reject
integer(Text) ->
    try
        binary_to_integer(Text)
    catch
        error:badarg -> Text
    end.
