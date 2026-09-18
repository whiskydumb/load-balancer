-module(lb_pools_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link([lb_config:pool()]) -> supervisor:startlink_ret().
start_link(Pools) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Pools).

-spec init([lb_config:pool()]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Pools) ->
    %% pools are independent: a crashing pool restarts alone
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{id => {lb_pool_sup, Name}, start => {lb_pool_sup, start_link, [Pool]}, type => supervisor}
     || #{name := Name} = Pool <- Pools
    ],
    {ok, {SupFlags, Children}}.
