-module(lb_pool_fixture).

-export([
    config/3,
    start/3,
    stop/1,
    stop_pool/1,
    start_pool/1,
    restart_pool/1,
    open/2,
    close/1,
    crash/1,
    active/2,
    eventually/1
]).

%% a pool and its table owner started outside the application, so tests can
%% kill and restart the pool at will

%% goes through the real validation, so tests see the same shape as production
config(Name, Strategy, Backends) ->
    {ok, #{pools := [Config]}} = lb_config:validate(#{
        pools => [
            #{
                name => Name,
                strategy => Strategy,
                backends => [#{host => Host, port => Port} || {Host, Port} <- Backends]
            }
        ]
    }),
    Config.

start(Name, Strategy, Backends) ->
    {ok, Owner} = lb_table_owner:start_link(lb_pool:tables()),
    unlink(Owner),
    Fixture = #{owner => Owner, config => config(Name, Strategy, Backends)},
    ok = start_pool(Fixture),
    Fixture.

stop(#{owner := Owner} = Fixture) ->
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

active(Pool, Backend) ->
    {ok, Statuses} = lb_pool:backends(Pool),
    [Active] = [Active || #{backend := Id, active := Active} <- Statuses, Id =:= Backend],
    Active.

%% monitors and casts are asynchronous, so tests poll for the state they expect
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

await_exit(Pid, Stop) ->
    Ref = monitor(process, Pid),
    Stop(),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    end.
