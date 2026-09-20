-module(lb_pool_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:pool()) -> supervisor:startlink_ret().
start_link(Pool) ->
    supervisor:start_link(?MODULE, Pool).

-spec init(lb_config:pool()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{health_check := #{enabled := Enabled}} = Pool) ->
    %% probers report into the pool, so they start after it and restart with it
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children =
        %% the pool gets this supervisor's pid to add and remove probers later
        [#{id => lb_pool, start => {lb_pool, start_link, [Pool, self()]}}] ++
            [
                #{
                    id => lb_health_sup,
                    start => {lb_health_sup, start_link, [Pool]},
                    type => supervisor
                }
             || Enabled
            ],
    {ok, {SupFlags, Children}}.
