-module(lb_health_sup).
-behaviour(supervisor).

-export([start_link/1, child_spec/3]).
-export([init/1]).

-spec start_link(lb_config:pool()) -> supervisor:startlink_ret().
start_link(Pool) ->
    supervisor:start_link(?MODULE, Pool).

-spec child_spec(lb_pool:name(), lb_backend:id(), lb_config:health_check()) ->
    supervisor:child_spec().
child_spec(Pool, Backend, HealthCheck) ->
    #{id => Backend, start => {lb_health_probe, start_link, [Pool, Backend, HealthCheck]}}.

-spec init(lb_config:pool()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{name := Name, health_check := HealthCheck}) ->
    %% probers keep no state, a crashed one simply starts probing again
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    %% the pool started first and restored any backends added at runtime
    Children = [child_spec(Name, Backend, HealthCheck) || Backend <- lb_pool:members(Name)],
    {ok, {SupFlags, Children}}.
