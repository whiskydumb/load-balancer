-module(lb_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:config()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-spec init(lb_config:config()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{pools := Pools}) ->
    %% children are ordered by dependency: a crash restarts only what was started after it
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [
        #{id => lb_pool_tables, start => {lb_table_owner, start_link, [lb_pool:tables()]}},
        #{id => lb_pools_sup, start => {lb_pools_sup, start_link, [Pools]}, type => supervisor}
    ],
    {ok, {SupFlags, Children}}.
