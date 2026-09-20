-module(lb_listener).
-behaviour(gen_server).

-export([start_link/2, tables/0]).
-export([port/1, lookup/1, start_proxy/1, connections/1, names/0, stats/1, record/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([counters/0, metric/0]).

-include_lib("kernel/include/logger.hrl").

%% owns a listen socket and every connection accepted on it. acceptors block in
%% accept on the published socket and ask this process for a proxy; at
%% max_connections the request waits, so further clients queue in the kernel
%% backlog instead of being accepted and starved

-define(TABLE, lb_listeners).
-define(METRICS, [accepted, upstream, downstream, no_backend]).

%% proxies bump these without talking to the listener
-opaque counters() :: counters:counters_ref().
-type metric() :: accepted | upstream | downstream | no_backend.

-record(state, {
    name :: atom(),
    socket :: gen_tcp:socket(),
    max :: pos_integer(),
    drain_timeout :: non_neg_integer(),
    counters :: counters(),
    proxy :: lb_proxy:options(),
    proxies = #{} :: #{pid() => []},
    waiting = queue:new() :: queue:queue(gen_server:from())
}).

-spec start_link(lb_config:listener(), lb_config:pool()) -> gen_server:start_ret().
start_link(Listener, Pool) ->
    gen_server:start_link(?MODULE, {Listener, Pool}, []).

%% one row per listener: {Name, Pid, Socket, Port, Counters}
-spec tables() -> [lb_table_owner:table()].
tables() ->
    [{?TABLE, [set, public, {read_concurrency, true}]}].

%% the bound port, which differs from the configured one when that was 0
-spec port(atom()) -> inet:port_number() | undefined.
port(Name) ->
    ets:lookup_element(?TABLE, Name, 4, undefined).

-spec lookup(atom()) -> {pid(), gen_tcp:socket()}.
lookup(Name) ->
    [{Name, Listener, Socket, _Port, _Counters}] = ets:lookup(?TABLE, Name),
    {Listener, Socket}.

%% blocks while the listener is at max_connections
-spec start_proxy(pid()) -> {ok, pid()}.
start_proxy(Listener) ->
    gen_server:call(Listener, start_proxy, infinity).

-spec connections(atom()) -> non_neg_integer().
connections(Name) ->
    {Listener, _Socket} = lookup(Name),
    gen_server:call(Listener, connections).

-spec names() -> [atom()].
names() ->
    ets:select(?TABLE, [{{'$1', '_', '_', '_', '_'}, [], ['$1']}]).

-spec stats(atom()) -> {ok, #{atom() => non_neg_integer()}} | {error, unknown_listener}.
stats(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, Listener, _Socket, Port, Counters}] ->
            Totals = maps:from_list([
                {Metric, counters:get(Counters, index(Metric))}
             || Metric <- ?METRICS
            ]),
            {ok, Totals#{port => Port, active => gen_server:call(Listener, connections)}};
        [] ->
            {error, unknown_listener}
    end.

-spec record(counters(), metric(), pos_integer()) -> ok.
record(Counters, Metric, Amount) ->
    counters:add(Counters, index(Metric), Amount).

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
        connect_attempts := Attempts,
        drain_timeout := DrainTimeout
    } = Listener,
    %% proxies are linked to this process and their exits free the slots
    process_flag(trap_exit, true),
    Options = [{ip, Ip}, {reuseaddr, true}, {backlog, Backlog} | lb_proxy:socket_options()],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} ->
            {ok, Bound} = inet:port(Socket),
            Counters = counters(Name),
            true = ets:insert(?TABLE, {Name, self(), Socket, Bound, Counters}),
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
                drain_timeout = DrainTimeout,
                counters = Counters,
                proxy = #{
                    listener => Name,
                    pool => Pool,
                    counters => Counters,
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

%% an orderly stop drains: the closed socket lets no new client in, and open
%% connections get drain_timeout to finish before they die with this process,
%% to which they are linked. a crash skips the wait, so a replacement listener
%% can take over quickly
-spec terminate(term(), #state{}) -> ok.
terminate(Reason, #state{socket = Socket} = State) ->
    ok = gen_tcp:close(Socket),
    case orderly(Reason) of
        true -> drain(State);
        false -> ok
    end.

orderly(normal) -> true;
orderly(shutdown) -> true;
orderly({shutdown, _Reason}) -> true;
orderly(_Crash) -> false.

drain(#state{proxies = Proxies}) when map_size(Proxies) =:= 0 ->
    ok;
drain(#state{name = Name, proxies = Proxies, drain_timeout = Timeout}) ->
    ?LOG_NOTICE(#{
        event => listener_draining,
        listener => Name,
        connections => map_size(Proxies),
        timeout_ms => Timeout
    }),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case map_size(await_proxies(Proxies, Deadline)) of
        0 -> ok;
        Left -> ?LOG_WARNING(#{event => connections_cut, listener => Name, connections => Left})
    end.

await_proxies(Proxies, _Deadline) when map_size(Proxies) =:= 0 ->
    Proxies;
await_proxies(Proxies, Deadline) ->
    receive
        {'EXIT', Proxy, _Reason} when is_map_key(Proxy, Proxies) ->
            await_proxies(maps:remove(Proxy, Proxies), Deadline)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        Proxies
    end.

%% a restarted listener keeps counting where its predecessor stopped, so the
%% totals only reset with the node
counters(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{Name, _Pid, _Socket, _Port, Counters}] -> Counters;
        [] -> counters:new(length(?METRICS), [write_concurrency])
    end.

index(accepted) -> 1;
index(upstream) -> 2;
index(downstream) -> 3;
index(no_backend) -> 4.

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

spawn_proxy(#state{proxy = Options, proxies = Proxies, counters = Counters} = State) ->
    {ok, Proxy} = lb_proxy:start_link(Options),
    ok = record(Counters, accepted, 1),
    {Proxy, State#state{proxies = Proxies#{Proxy => []}}}.
