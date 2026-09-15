-module(lb_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% children are ordered by dependency: a crash restarts only what was started after it
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    {ok, {SupFlags, []}}.
