-module(lb_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:config()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-spec init(lb_config:config()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{pools := Pools, listeners := Listeners, admin := Admin}) ->
    %% children are ordered by dependency: a crash restarts only what was started
    %% after it, and listeners route into pools, so they come last
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Tables = lb_pool:tables() ++ lb_listener:tables(),
    Children =
        [
            #{id => lb_tables, start => {lb_table_owner, start_link, [Tables]}},
            #{id => lb_pools_sup, start => {lb_pools_sup, start_link, [Pools]}, type => supervisor},
            #{
                id => lb_listeners_sup,
                start => {lb_listeners_sup, start_link, [Listeners, Pools]},
                type => supervisor
            }
        ] ++
            [
                #{id => lb_admin, start => {lb_admin, start_link, [Admin]}}
             || map_get(enabled, Admin)
            ],
    {ok, {SupFlags, Children}}.
