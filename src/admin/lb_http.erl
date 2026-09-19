-module(lb_http).

-export([read_request/2, send_response/2]).

-export_type([request/0, response/0]).

%% just enough http/1.1 for the admin api: one request per connection, bounded
%% line length and header count, one deadline for reading the whole request

-define(MAX_LINE, 8192).
-define(MAX_HEADERS, 64).

-type request() :: #{
    method := atom() | binary(),
    path := binary(),
    headers := #{binary() => binary()}
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
    case recv(Socket, Deadline) of
        {ok, {http_request, Method, {abs_path, Target}, _Version}} ->
            [Path | _Query] = binary:split(Target, <<"?">>),
            headers(Socket, Deadline, #{method => Method, path => Path, headers => #{}}, 0);
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
    case recv(Socket, Deadline) of
        {ok, {http_header, _, Name, _, Value}} ->
            Next = Request#{headers := Headers#{header_name(Name) => Value}},
            headers(Socket, Deadline, Next, Count + 1);
        {ok, http_eoh} ->
            {ok, Request};
        {ok, _Unexpected} ->
            {error, bad_request};
        {error, Reason} ->
            {error, Reason}
    end.

recv(Socket, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> gen_tcp:recv(Socket, 0, Left);
        _Expired -> {error, timeout}
    end.

%% the decoder returns well known header names as atoms, the rest as binaries
header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) -> string:lowercase(Name).

reason(200) -> <<"OK">>;
reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(500) -> <<"Internal Server Error">>;
reason(_Status) -> <<"Unknown">>.
