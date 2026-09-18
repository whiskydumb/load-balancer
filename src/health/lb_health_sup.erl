-module(lb_health_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:pool()) -> supervisor:startlink_ret().
start_link(Pool) ->
    supervisor:start_link(?MODULE, Pool).

-spec init(lb_config:pool()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{name := Name, backends := Backends, health_check := HealthCheck}) ->
    %% probers keep no state, a crashed one simply starts probing again
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{id => Id, start => {lb_health_probe, start_link, [Name, Id, HealthCheck]}}
     || Id <- [lb_backend:id(Backend) || Backend <- Backends]
    ],
    {ok, {SupFlags, Children}}.
