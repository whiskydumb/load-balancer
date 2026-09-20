-module(lb_pool_fixture).

-export([
    config/3,
    config/4,
    start/1,
    start/3,
    start_supervised/1,
    stop/1,
    stop_pool/1,
    start_pool/1,
    restart_pool/1,
    open/2,
    close/1,
    crash/1,
    observe/3,
    active/2,
    health/2,
    admin/2,
    eventually/1,
    eventually/2
]).

%% a pool and its table owner started outside the application, so tests can
%% kill and restart the pool at will

config(Name, Strategy, Backends) ->
    config(Name, Strategy, Backends, #{}).

%% goes through the real validation, so tests see the same shape as production;
%% single observations flip health unless a test asks for longer streaks
config(Name, Strategy, Backends, HealthCheck) ->
    {ok, #{pools := [Config]}} = lb_config:validate(#{
        pools => [
            #{
                name => Name,
                strategy => Strategy,
                backends => [#{host => Host, port => Port} || {Host, Port} <- Backends],
                health_check => maps:merge(#{rise => 1, fall => 1}, HealthCheck)
            }
        ]
    }),
    Config.

start(Name, Strategy, Backends) ->
    start(config(Name, Strategy, Backends)).

start(Config) ->
    Fixture = start_tables(Config),
    ok = start_pool(Fixture),
    Fixture.

%% the pool together with its probers, the way the application runs it
start_supervised(Config) ->
    Fixture = start_tables(Config),
    {ok, Sup} = lb_pool_sup:start_link(Config),
    unlink(Sup),
    Fixture#{sup => Sup}.

stop(#{owner := Owner} = Fixture) ->
    %% a supervisor is stopped the orderly way: killed, it would take its child
    %% supervisors down with a crash report
    case Fixture of
        #{sup := Sup} -> ok = gen_server:stop(Sup);
        #{} -> ok
    end,
    ok = stop_pool(Fixture),
    ok = crash(Owner),
    %% named tables must be gone before the next fixture creates them again
    true = eventually(fun() ->
        lists:all(fun({Table, _}) -> ets:whereis(Table) =:= undefined end, lb_pool:tables())
    end),
    ok.

start_pool(#{config := Config}) ->
    {ok, Pool} = lb_pool:start_link(Config),
    unlink(Pool),
    ok.

stop_pool(#{config := #{name := Name}}) ->
    case lb_pool:pid(Name) of
        undefined -> ok;
        Pid -> crash(Pid)
    end.

restart_pool(Fixture) ->
    ok = stop_pool(Fixture),
    start_pool(Fixture).

%% stands in for a proxied connection: registers with the pool, then lives
%% until it is closed or killed
open(Pool, Backend) ->
    Parent = self(),
    Conn = spawn(fun() ->
        ok = lb_pool:track(Pool, Backend),
        Parent ! {tracked, self()},
        receive
            close -> ok
        end
    end),
    receive
        {tracked, Conn} -> Conn
    after 1000 -> error(track_timeout)
    end.

close(Conn) ->
    await_exit(Conn, fun() -> Conn ! close end).

crash(Pid) ->
    await_exit(Pid, fun() -> exit(Pid, kill) end).

%% casts from one process are handled in order, so the call that follows the
%% cast returns only after the observation took effect
observe(Pool, Backend, Observation) ->
    ok = lb_pool:observe(Pool, Backend, Observation),
    {ok, _} = lb_pool:backends(Pool),
    ok.

active(Pool, Backend) ->
    status_field(Pool, Backend, active).

health(Pool, Backend) ->
    status_field(Pool, Backend, health).

admin(Pool, Backend) ->
    status_field(Pool, Backend, admin).

%% monitors, casts and probes are asynchronous, so tests poll for the state
%% they expect
eventually(Check) ->
    eventually(Check, 200).

eventually(Check, Attempts) ->
    case Check() of
        true ->
            true;
        false when Attempts > 1 ->
            timer:sleep(5),
            eventually(Check, Attempts - 1);
        false ->
            false
    end.

start_tables(Config) ->
    {ok, Owner} = lb_table_owner:start_link(lb_pool:tables()),
    unlink(Owner),
    #{owner => Owner, config => Config}.

status_field(Pool, Backend, Field) ->
    {ok, Statuses} = lb_pool:backends(Pool),
    [Value] = [maps:get(Field, Status) || #{backend := Id} = Status <- Statuses, Id =:= Backend],
    Value.

await_exit(Pid, Stop) ->
    Ref = monitor(process, Pid),
    Stop(),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    end.
