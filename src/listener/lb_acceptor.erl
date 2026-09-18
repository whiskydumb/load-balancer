-module(lb_acceptor).

-export([start_link/1, accept/2]).

-include_lib("kernel/include/logger.hrl").

%% blocks in accept and hands every client to a fresh proxy. like ranch's
%% acceptors these are plain processes: they spend their life inside accept,
%% where a system message could not be answered anyway

%% pause after accept errors such as emfile, instead of spinning on them
-define(BACKOFF, 100).

-spec start_link(atom()) -> {ok, pid()}.
start_link(Name) ->
    {Listener, Socket} = lb_listener:lookup(Name),
    {ok, proc_lib:spawn_link(?MODULE, accept, [Listener, Socket])}.

%% returns when the listen socket is closed, which ends a transient acceptor
-spec accept(pid(), gen_tcp:socket()) -> ok.
accept(Listener, Listen) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            ok = handoff(Listener, Socket),
            accept(Listener, Listen);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{event => accept_failed, reason => Reason}),
            timer:sleep(?BACKOFF),
            accept(Listener, Listen)
    end.

handoff(Listener, Socket) ->
    {ok, Proxy} = lb_listener:start_proxy(Listener),
    case gen_tcp:controlling_process(Socket, Proxy) of
        ok -> lb_proxy:handoff(Proxy, Socket);
        {error, _ProxyGone} -> gen_tcp:close(Socket)
    end.
