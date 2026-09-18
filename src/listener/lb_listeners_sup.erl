-module(lb_listeners_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

-spec start_link([lb_config:listener()], [lb_config:pool()]) -> supervisor:startlink_ret().
start_link(Listeners, Pools) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Listeners, Pools}).

-spec init({[lb_config:listener()], [lb_config:pool()]}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Listeners, Pools}) ->
    %% the config guarantees every listener points at an existing pool
    ByName = maps:from_list([{Name, Pool} || #{name := Name} = Pool <- Pools]),
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{
            id => {lb_listener_sup, Name},
            start => {lb_listener_sup, start_link, [Listener, map_get(Pool, ByName)]},
            type => supervisor
        }
     || #{name := Name, pool := Pool} = Listener <- Listeners
    ],
    {ok, {SupFlags, Children}}.
