-module(lb_http).

-export([read_request/2, send_response/2]).

-export_type([request/0, response/0]).

%% just enough http/1.1 for the admin api: one request per connection, bounded
%% line length, header count and body size, one deadline for the whole request

-define(MAX_LINE, 8192).
-define(MAX_HEADERS, 64).
-define(MAX_BODY, 16384).

-type request() :: #{
    method := atom() | binary(),
    path := binary(),
    headers := #{binary() => binary()},
    body := binary()
}.
-type response() :: #{
    status := 100..599,
    headers := [{binary(), iodata()}],
    body := iodata()
}.

-spec read_request(gen_tcp:socket(), pos_integer()) -> {ok, request()} | {error, term()}.
read_request(Socket, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    ok = inet:setopts(Socket, [{packet, http_bin}, {packet_size, ?MAX_LINE}]),
    case recv(Socket, 0, Deadline) of
        {ok, {http_request, Method, {abs_path, Target}, _Version}} ->
            [Path | _Query] = binary:split(Target, <<"?">>),
            Request = #{method => Method, path => Path, headers => #{}, body => <<>>},
            headers(Socket, Deadline, Request, 0);
        {ok, _Unexpected} ->
            {error, bad_request};
        {error, Reason} ->
            {error, Reason}
    end.

-spec send_response(gen_tcp:socket(), response()) -> ok | {error, term()}.
send_response(Socket, #{status := Status, headers := Headers, body := Body}) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    Head = [
        [<<"HTTP/1.1 ">>, integer_to_binary(Status), $\s, reason(Status), <<"\r\n">>],
        [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
        [<<"content-length: ">>, integer_to_binary(iolist_size(Body)), <<"\r\n">>],
        <<"connection: close\r\n\r\n">>
    ],
    gen_tcp:send(Socket, [Head, Body]).

headers(_Socket, _Deadline, _Request, Count) when Count > ?MAX_HEADERS ->
    {error, too_many_headers};
headers(Socket, Deadline, #{headers := Headers} = Request, Count) ->
    case recv(Socket, 0, Deadline) of
        {ok, {http_header, _, Name, _, Value}} ->
            Next = Request#{headers := Headers#{header_name(Name) => Value}},
            headers(Socket, Deadline, Next, Count + 1);
        {ok, http_eoh} ->
            body(Socket, Deadline, Request);
        {ok, _Unexpected} ->
            {error, bad_request};
        {error, Reason} ->
            {error, Reason}
    end.

%% only bodies with a declared length are read; chunked uploads are refused
body(_Socket, _Deadline, #{headers := #{<<"transfer-encoding">> := _}}) ->
    {error, unsupported_transfer_encoding};
body(Socket, Deadline, #{headers := #{<<"content-length">> := Value}} = Request) ->
    case content_length(Value) of
        {ok, 0} ->
            {ok, Request};
        {ok, Length} when Length =< ?MAX_BODY ->
            %% the rest of the input stays buffered across the switch to raw
            ok = inet:setopts(Socket, [{packet, raw}]),
            case recv(Socket, Length, Deadline) of
                {ok, Body} -> {ok, Request#{body := Body}};
                {error, Reason} -> {error, Reason}
            end;
        {ok, _Length} ->
            {error, body_too_large};
        error ->
            {error, bad_request}
    end;
body(_Socket, _Deadline, Request) ->
    {ok, Request}.

content_length(Value) ->
    try binary_to_integer(string:trim(Value)) of
        Length when Length >= 0 -> {ok, Length};
        _Negative -> error
    catch
        error:badarg -> error
    end.

recv(Socket, Length, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> gen_tcp:recv(Socket, Length, Left);
        _Expired -> {error, timeout}
    end.

%% the decoder returns well known header names as atoms, the rest as binaries
header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) -> string:lowercase(Name).

reason(200) -> <<"OK">>;
reason(201) -> <<"Created">>;
reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(409) -> <<"Conflict">>;
reason(413) -> <<"Content Too Large">>;
reason(500) -> <<"Internal Server Error">>;
reason(_Status) -> <<"Unknown">>.
