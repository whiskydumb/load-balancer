-module(lb_health_probe).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%% connects to one backend every interval and reports the outcome to the pool,
%% which owns the health state. a probe blocks this process for at most
%% `timeout`, which the config keeps within `interval`, and every backend has
%% its own prober, so a slow backend delays nobody else

-record(state, {
    pool :: lb_pool:name(),
    backend :: lb_backend:id(),
    interval :: pos_integer(),
    timeout :: pos_integer()
}).

-spec start_link(lb_pool:name(), lb_backend:id(), lb_config:health_check()) ->
    gen_server:start_ret().
start_link(Pool, Backend, #{interval := Interval, timeout := Timeout}) ->
    State = #state{pool = Pool, backend = Backend, interval = Interval, timeout = Timeout},
    gen_server:start_link(?MODULE, State, []).

-spec init(#state{}) -> {ok, #state{}}.
init(#state{interval = Interval} = State) ->
    %% a random first delay keeps probers started together out of lockstep
    schedule(rand:uniform(Interval)),
    {ok, State}.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, {error, unexpected_call}, #state{}}.
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_cast, message => Message}),
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(probe, #state{pool = Pool, backend = Backend, timeout = Timeout} = State) ->
    ok = lb_pool:observe(Pool, Backend, probe(Backend, Timeout)),
    schedule(jitter(State#state.interval)),
    {noreply, State};
handle_info(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_message, message => Message}),
    {noreply, State}.

probe({Host, Port}, Timeout) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], Timeout) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            success;
        {error, Reason} ->
            {failure, Reason}
    end.

schedule(Delay) ->
    _ = erlang:send_after(Delay, self(), probe),
    ok.

%% +-10% keeps probes of different backends from settling into the same beat
jitter(Interval) ->
    Spread = Interval div 10,
    Interval - Spread + rand:uniform(2 * Spread + 1) - 1.
