-module(lb_test_backend).

-export([start/0, start/1, start/2, stop/1, reserve_port/0]).

%% a tcp echo server on 127.0.0.1 standing in for a real backend

start() ->
    start(0).

start(Port) ->
    start(Port, <<>>).

%% sends Preamble to every client before reading anything from it, like a
%% server that answers before it has consumed the request, then echoes
start(Port, Preamble) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(Port, [
            binary, {ip, {127, 0, 0, 1}}, {reuseaddr, true}, {active, false}, {backlog, 128}
        ]),
        {ok, Bound} = inet:port(Listen),
        Parent ! {listening, self(), Bound},
        accept_loop(Listen, Preamble)
    end),
    receive
        {listening, Pid, Bound} -> #{pid => Pid, backend => {{127, 0, 0, 1}, Bound}}
    after 1000 -> error(listen_timeout)
    end.

%% goes away like a crashed server: the listener and every open connection
%% close at once, because connection handlers are linked to the acceptor
stop(#{pid := Pid}) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    end.

%% a port nothing listens on, for backends that must refuse connections
reserve_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

accept_loop(Listen, Preamble) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Handler = spawn_link(fun() ->
        receive
            {socket, Owned} -> serve(Owned, Preamble)
        end
    end),
    ok = gen_tcp:controlling_process(Socket, Handler),
    Handler ! {socket, Socket},
    accept_loop(Listen, Preamble).

serve(Socket, Preamble) ->
    case gen_tcp:send(Socket, Preamble) of
        ok -> echo(Socket);
        {error, _Closed} -> ok
    end.

echo(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            case gen_tcp:send(Socket, Data) of
                ok -> echo(Socket);
                {error, _Closed} -> ok
            end;
        {error, _Closed} ->
            ok
    end.
