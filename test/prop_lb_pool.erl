-module(prop_lb_pool).

-include_lib("proper/include/proper.hrl").

-export([initial_state/0, command/1, precondition/2, postcondition/3, next_state/3]).
-export([open/1, close/1, crash/1, restart_pool/0, set_health/2]).

-define(POOL, prop_pool).
-define(BACKENDS, [{{127, 0, 0, 1}, 9001}, {{127, 0, 0, 1}, 9002}, {{127, 0, 0, 1}, 9003}]).

%% random sequences of connections opening, closing and crashing, interleaved
%% with pool restarts and health changes: after every step the counters match
%% the live connections and picks respect health
prop_counters_follow_live_connections() ->
    ?FORALL(
        Commands,
        commands(?MODULE),
        begin
            Fixture = lb_pool_fixture:start(?POOL, round_robin, ?BACKENDS),
            {History, State, Result} = run_commands(?MODULE, Commands),
            lists:foreach(fun lb_pool_fixture:crash/1, conns(State)),
            ok = lb_pool_fixture:stop(Fixture),
            ?WHENFAIL(
                io:format("history: ~p~nstate: ~p~nresult: ~p~n", [History, State, Result]),
                Result =:= ok
            )
        end
    ).

initial_state() ->
    #{conns => [], health => all_up()}.

command(State) ->
    Conns = conns(State),
    frequency(
        [
            {4, {call, ?MODULE, open, [elements(?BACKENDS)]}},
            {1, {call, ?MODULE, restart_pool, []}},
            {2, {call, ?MODULE, set_health, [elements(?BACKENDS), elements([up, down])]}}
        ] ++
            [{3, {call, ?MODULE, close, [elements(Conns)]}} || Conns =/= []] ++
            [{2, {call, ?MODULE, crash, [elements(Conns)]}} || Conns =/= []]
    ).

precondition(State, {call, ?MODULE, Stop, [Conn]}) when Stop =:= close; Stop =:= crash ->
    lists:member(Conn, conns(State));
precondition(_State, _Call) ->
    true.

next_state(#{conns := Conns} = State, Conn, {call, ?MODULE, open, [Backend]}) ->
    State#{conns := [{Conn, Backend} | Conns]};
next_state(#{conns := Conns} = State, _Result, {call, ?MODULE, Stop, [Conn]}) when
    Stop =:= close; Stop =:= crash
->
    State#{conns := lists:keydelete(Conn, 1, Conns)};
next_state(State, _Result, {call, ?MODULE, restart_pool, []}) ->
    %% health is not persisted, a fresh pool starts with every backend up
    State#{health := all_up()};
next_state(#{health := Health} = State, _Result, {call, ?MODULE, set_health, [Backend, Value]}) ->
    State#{health := Health#{Backend := Value}}.

postcondition(State, Call, Result) ->
    #{conns := Conns, health := Health} = next_state(State, Result, Call),
    Expected = maps:from_list([
        {Backend, length([Conn || {Conn, B} <- Conns, B =:= Backend])}
     || Backend <- ?BACKENDS
    ]),
    lb_pool_fixture:eventually(fun() -> counters() =:= Expected end) andalso
        picks_respect(Health).

open(Backend) ->
    lb_pool_fixture:open(?POOL, Backend).

close(Conn) ->
    lb_pool_fixture:close(Conn).

crash(Conn) ->
    lb_pool_fixture:crash(Conn).

restart_pool() ->
    lb_pool_fixture:restart_pool(#{
        config => lb_pool_fixture:config(?POOL, round_robin, ?BACKENDS)
    }).

set_health(Backend, Health) ->
    lb_pool:set_health(?POOL, Backend, Health).

counters() ->
    {ok, Statuses} = lb_pool:backends(?POOL),
    maps:from_list([{Backend, Active} || #{backend := Backend, active := Active} <- Statuses]).

picks_respect(Health) ->
    Up = [Backend || Backend <- ?BACKENDS, map_get(Backend, Health) =:= up],
    Picks = [lb_pool:pick(?POOL, key, []) || _ <- ?BACKENDS],
    case Up of
        [] -> lists:all(fun(Pick) -> Pick =:= {error, no_backend} end, Picks);
        _ -> lists:all(fun(Pick) -> picked_one_of(Pick, Up) end, Picks)
    end.

picked_one_of({ok, Backend}, Up) -> lists:member(Backend, Up);
picked_one_of({error, no_backend}, _Up) -> false.

conns(#{conns := Conns}) ->
    [Conn || {Conn, _Backend} <- Conns].

all_up() ->
    maps:from_list([{Backend, up} || Backend <- ?BACKENDS]).
