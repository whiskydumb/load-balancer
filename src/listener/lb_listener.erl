-module(lb_listener).
-behaviour(gen_server).

-export([start_link/2, tables/0, port/1, lookup/1, start_proxy/1, connections/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%% owns a listen socket and every connection accepted on it. acceptors block in
%% accept on the published socket and ask this process for a proxy; at
%% max_connections the request waits, so further clients queue in the kernel
%% backlog instead of being accepted and starved

-define(TABLE, lb_listeners).

-record(state, {
    name :: atom(),
    socket :: gen_tcp:socket(),
    max :: pos_integer(),
    proxy :: lb_proxy:options(),
    proxies = #{} :: #{pid() => []},
    waiting = queue:new() :: queue:queue(gen_server:from())
}).

-spec start_link(lb_config:listener(), lb_config:pool()) -> gen_server:start_ret().
start_link(Listener, Pool) ->
    gen_server:start_link(?MODULE, {Listener, Pool}, []).

-spec tables() -> [lb_table_owner:table()].
tables() ->
    [{?TABLE, [set, public, {read_concurrency, true}]}].

%% the bound port, which differs from the configured one when that was 0
-spec port(atom()) -> inet:port_number() | undefined.
port(Name) ->
    ets:lookup_element(?TABLE, Name, 4, undefined).

-spec lookup(atom()) -> {pid(), gen_tcp:socket()}.
lookup(Name) ->
    [{Name, Listener, Socket, _Port}] = ets:lookup(?TABLE, Name),
    {Listener, Socket}.

%% blocks while the listener is at max_connections
-spec start_proxy(pid()) -> {ok, pid()}.
start_proxy(Listener) ->
    gen_server:call(Listener, start_proxy, infinity).

-spec connections(atom()) -> non_neg_integer().
connections(Name) ->
    {Listener, _Socket} = lookup(Name),
    gen_server:call(Listener, connections).

-spec init({lb_config:listener(), lb_config:pool()}) ->
    {ok, #state{}} | {stop, {listen_failed, term()}}.
init({Listener, #{connect_timeout := ConnectTimeout}}) ->
    #{
        name := Name,
        ip := Ip,
        port := Port,
        backlog := Backlog,
        pool := Pool,
        max_connections := Max,
        idle_timeout := IdleTimeout,
        connect_attempts := Attempts
    } = Listener,
    %% proxies are linked to this process and their exits free the slots
    process_flag(trap_exit, true),
    Options = [{ip, Ip}, {reuseaddr, true}, {backlog, Backlog} | lb_proxy:socket_options()],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} ->
            {ok, Bound} = inet:port(Socket),
            true = ets:insert(?TABLE, {Name, self(), Socket, Bound}),
            ?LOG_INFO(#{
                event => listener_started,
                listener => Name,
                address => list_to_binary(inet:ntoa(Ip)),
                port => Bound,
                pool => Pool
            }),
            {ok, #state{
                name = Name,
                socket = Socket,
                max = Max,
                proxy = #{
                    listener => Name,
                    pool => Pool,
                    connect_timeout => ConnectTimeout,
                    connect_attempts => Attempts,
                    idle_timeout => IdleTimeout
                }
            }};
        {error, Reason} ->
            ?LOG_ERROR(#{event => listen_failed, listener => Name, port => Port, reason => Reason}),
            {stop, {listen_failed, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.
handle_call(start_proxy, From, #state{proxies = Proxies, max = Max, waiting = Waiting} = State) ->
    case map_size(Proxies) < Max of
        true ->
            {Proxy, Next} = spawn_proxy(State),
            {reply, {ok, Proxy}, Next};
        false ->
            {noreply, State#state{waiting = queue:in(From, Waiting)}}
    end;
handle_call(connections, _From, #state{proxies = Proxies} = State) ->
    {reply, map_size(Proxies), State};
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_cast, message => Message}),
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
handle_info({'EXIT', Pid, _Reason}, #state{proxies = Proxies} = State) when
    is_map_key(Pid, Proxies)
->
    {noreply, admit(State#state{proxies = maps:remove(Pid, Proxies)})};
handle_info({'EXIT', Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {listen_socket_closed, Reason}, State};
handle_info(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_message, message => Message}),
    {noreply, State}.

%% a freed slot goes to the acceptor that has waited longest; one whose client
%% vanished meanwhile leaves a proxy that times out waiting for the socket
admit(#state{waiting = Waiting} = State) ->
    case queue:out(Waiting) of
        {{value, From}, Rest} ->
            {Proxy, Next} = spawn_proxy(State#state{waiting = Rest}),
            gen_server:reply(From, {ok, Proxy}),
            Next;
        {empty, _} ->
            State
    end.

spawn_proxy(#state{proxy = Options, proxies = Proxies} = State) ->
    {ok, Proxy} = lb_proxy:start_link(Options),
    {Proxy, State#state{proxies = Proxies#{Proxy => []}}}.
