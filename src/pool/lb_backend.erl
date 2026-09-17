-module(lb_backend).

-export([id/1, format/1]).

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
