-module(lb_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:config()) -> supervisor:startlink_ret().
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

-spec init(lb_config:config()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(_Config) ->
    %% children are ordered by dependency: a crash restarts only what was started after it
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    {ok, {SupFlags, []}}.
