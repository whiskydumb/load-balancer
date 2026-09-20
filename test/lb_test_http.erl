-module(lb_test_http).

-export([request/4, exchange/1, header/2]).

%% a bare http/1.1 client for the admin api: one request per connection, read
%% until the server closes it

request(Method, Path, Token, Body) ->
    exchange([
        [Method, " ", Path, " HTTP/1.1\r\nhost: lb\r\n"],
        authorization(Token),
        content(Body),
        "\r\n",
        Body
    ]).

exchange(Request) ->
    {ok, Socket} = gen_tcp:connect(
        {127, 0, 0, 1}, lb_admin:port(), [binary, {active, false}], 1000
    ),
    ok = gen_tcp:send(Socket, Request),
    parse(read_all(Socket, <<>>)).

header(Name, Headers) ->
    proplists:get_value(Name, Headers).

authorization(none) -> [];
authorization(Token) -> ["authorization: Bearer ", Token, "\r\n"].

content(<<>>) ->
    [];
content(Body) ->
    Length = integer_to_list(iolist_size(Body)),
    ["content-type: application/json\r\ncontent-length: ", Length, "\r\n"].

read_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 2000) of
        {ok, Data} -> read_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

parse(Response) ->
    [Head, Body] = binary:split(Response, <<"\r\n\r\n">>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, Code | _Reason] = binary:split(StatusLine, <<" ">>, [global]),
    Headers = [list_to_tuple(binary:split(Line, <<": ">>)) || Line <- HeaderLines],
    {binary_to_integer(Code), Headers, Body}.
