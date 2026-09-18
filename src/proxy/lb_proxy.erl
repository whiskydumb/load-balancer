-module(lb_proxy).
-behaviour(gen_statem).

-export([start_link/1, handoff/2, socket_options/0]).
-export([callback_mode/0, init/1, waiting/3, connecting/3, relaying/3]).

-export_type([options/0]).

-include_lib("kernel/include/logger.hrl").

%% one process per client connection. it owns both sockets and two linked pumps
%% move the bytes, one per direction. a single relay loop blocked on sending to
%% a peer that writes before it reads stops reading that peer and deadlocks with
%% it; with a pump per direction a blocked send stalls only its own direction

-define(HANDOFF_TIMEOUT, 5000).
%% a peer that takes no data for this long is treated as gone
-define(SEND_TIMEOUT, 30000).

-type options() :: #{
    listener := atom(),
    pool := lb_pool:name(),
    connect_timeout := pos_integer(),
    connect_attempts := pos_integer(),
    idle_timeout := pos_integer()
}.
-type direction() :: upstream | downstream.

-record(data, {
    options :: options(),
    started :: integer(),
    client :: gen_tcp:socket() | undefined,
    peer :: inet:ip_address() | undefined,
    backend :: gen_tcp:socket() | undefined,
    backend_id :: lb_backend:id() | undefined,
    tried = [] :: [lb_backend:id()],
    running = 0 :: 0..2,
    bytes = #{} :: #{direction() => non_neg_integer()}
}).

-record(pump, {
    direction :: direction(),
    from :: gen_tcp:socket(),
    to :: gen_tcp:socket(),
    proxy :: pid(),
    activity :: atomics:atomics_ref(),
    idle_timeout :: pos_integer()
}).

-spec start_link(options()) -> gen_statem:start_ret().
start_link(Options) ->
    gen_statem:start_link(?MODULE, Options, []).

%% called by the acceptor once this process owns the socket
-spec handoff(pid(), gen_tcp:socket()) -> ok.
handoff(Proxy, Socket) ->
    gen_statem:cast(Proxy, {handoff, Socket}).

%% shared by accepted client sockets and backend connections
-spec socket_options() -> [gen_tcp:option()].
socket_options() ->
    [
        binary,
        {active, false},
        {nodelay, true},
        {keepalive, true},
        %% a peer that sent its fin may still read the rest, so the socket stays
        %% open for sending until the other direction is done too
        {exit_on_close, false},
        {send_timeout, ?SEND_TIMEOUT},
        {send_timeout_close, true}
    ].

-spec callback_mode() -> state_functions.
callback_mode() ->
    state_functions.

-spec init(options()) -> gen_statem:init_result(waiting).
init(Options) ->
    Data = #data{options = Options, started = erlang:monotonic_time(millisecond)},
    {ok, waiting, Data, [{state_timeout, ?HANDOFF_TIMEOUT, handoff}]}.

-spec waiting(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(connecting).
waiting(cast, {handoff, Socket}, Data) ->
    case inet:peername(Socket) of
        {ok, {Peer, _Port}} ->
            Next = Data#data{client = Socket, peer = Peer},
            {next_state, connecting, Next, [{next_event, internal, connect}]};
        {error, _Gone} ->
            {stop, normal}
    end;
%% the acceptor died before handing the socket over
waiting(state_timeout, handoff, _Data) ->
    {stop, normal};
waiting(EventType, Event, _Data) ->
    unexpected(waiting, EventType, Event).

-spec connecting(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(relaying).
connecting(internal, connect, #data{options = Options, peer = Peer, tried = Tried} = Data) ->
    #{pool := Pool, connect_timeout := Timeout} = Options,
    case lb_pool:pick(Pool, Peer, Tried) of
        {error, no_backend} ->
            give_up(no_backend, Data);
        {ok, {Host, Port} = Backend} ->
            case gen_tcp:connect(Host, Port, socket_options(), Timeout) of
                {ok, Socket} ->
                    ok = lb_pool:track(Pool, Backend),
                    Next = Data#data{backend = Socket, backend_id = Backend},
                    {next_state, relaying, start_pumps(Next)};
                {error, Reason} ->
                    %% a refused connection is evidence against the backend
                    ok = lb_pool:observe(Pool, Backend, {failure, Reason}),
                    retry(Reason, Data#data{tried = [Backend | Tried]})
            end
    end;
connecting(EventType, Event, _Data) ->
    unexpected(connecting, EventType, Event).

-spec relaying(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(relaying).
relaying(info, {pump, Direction, closed, Sent}, #data{running = Running, bytes = Bytes} = Data) ->
    Next = Data#data{running = Running - 1, bytes = Bytes#{Direction => Sent}},
    case Next#data.running of
        0 -> finish(closed, Next);
        _ -> {keep_state, Next}
    end;
%% idle or failed: closing both sockets on exit also stops the other pump
relaying(info, {pump, Direction, Reason, Sent}, #data{bytes = Bytes} = Data) ->
    finish(Reason, Data#data{bytes = Bytes#{Direction => Sent}});
relaying(EventType, Event, _Data) ->
    unexpected(relaying, EventType, Event).

retry(Reason, #data{options = #{connect_attempts := Attempts}, tried = Tried} = Data) ->
    case length(Tried) < Attempts of
        true -> {keep_state, Data, [{next_event, internal, connect}]};
        false -> give_up({connect_failed, Reason}, Data)
    end.

%% the client socket closes when this process exits
give_up(Reason, #data{options = #{listener := Listener, pool := Pool}, tried = Tried}) ->
    ?LOG_WARNING(#{
        event => no_backend,
        listener => Listener,
        pool => Pool,
        reason => Reason,
        tried => [lb_backend:format(Backend) || Backend <- lists:reverse(Tried)]
    }),
    {stop, normal}.

finish(Reason, #data{options = #{listener := Listener}} = Data) ->
    #data{backend_id = Backend, bytes = Bytes, started = Started} = Data,
    ?LOG_DEBUG(#{
        event => connection_closed,
        listener => Listener,
        backend => lb_backend:format(Backend),
        reason => Reason,
        upstream_bytes => maps:get(upstream, Bytes, unknown),
        downstream_bytes => maps:get(downstream, Bytes, unknown),
        duration_ms => erlang:monotonic_time(millisecond) - Started
    }),
    {stop, normal, Data}.

start_pumps(#data{client = Client, backend = Backend, options = Options} = Data) ->
    #{idle_timeout := Idle} = Options,
    %% both pumps stamp the last transfer here, so neither calls the connection
    %% idle while the other direction is busy
    Activity = atomics:new(1, []),
    ok = atomics:put(Activity, 1, now_ms()),
    Proxy = self(),
    Pump = fun(Direction, From, To) ->
        #pump{
            direction = Direction,
            from = From,
            to = To,
            proxy = Proxy,
            activity = Activity,
            idle_timeout = Idle
        }
    end,
    ok = spawn_pump(Pump(upstream, Client, Backend)),
    ok = spawn_pump(Pump(downstream, Backend, Client)),
    Data#data{running = 2}.

spawn_pump(#pump{idle_timeout = Idle} = Pump) ->
    _ = proc_lib:spawn_link(fun() -> pump(Pump, Idle, 0) end),
    ok.

%% moves bytes one way until the source closes or fails, or until the whole
%% connection has been quiet for idle_timeout
pump(#pump{from = From, to = To, activity = Activity} = Pump, Wait, Sent) ->
    case gen_tcp:recv(From, 0, Wait) of
        {ok, Chunk} ->
            ok = atomics:put(Activity, 1, now_ms()),
            case gen_tcp:send(To, Chunk) of
                ok -> pump(Pump, Pump#pump.idle_timeout, Sent + byte_size(Chunk));
                {error, Reason} -> report(Pump, {error, Reason}, Sent)
            end;
        {error, timeout} ->
            %% this direction was quiet, but the other one may have been busy
            Quiet = now_ms() - atomics:get(Activity, 1),
            case Quiet >= Pump#pump.idle_timeout of
                true -> report(Pump, idle, Sent);
                false -> pump(Pump, Pump#pump.idle_timeout - Quiet, Sent)
            end;
        {error, closed} ->
            %% pass the fin on and let the opposite direction finish
            _ = gen_tcp:shutdown(To, write),
            report(Pump, closed, Sent);
        {error, Reason} ->
            report(Pump, {error, Reason}, Sent)
    end.

report(#pump{proxy = Proxy, direction = Direction}, Outcome, Sent) ->
    Proxy ! {pump, Direction, Outcome, Sent},
    ok.

now_ms() ->
    erlang:monotonic_time(millisecond).

unexpected(State, EventType, Event) ->
    ?LOG_WARNING(#{event => unexpected_event, state => State, type => EventType, content => Event}),
    keep_state_and_data.
