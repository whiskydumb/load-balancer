-module(lb_acceptor_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(lb_config:listener()) -> supervisor:startlink_ret().
start_link(Listener) ->
    supervisor:start_link(?MODULE, Listener).

-spec init(lb_config:listener()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(#{name := Name, acceptors := Count}) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    %% an acceptor returns once the listen socket closes and stays down then;
    %% it sits in accept and cannot handle a shutdown request, hence the kill
    Children = [
        #{
            id => Id,
            start => {lb_acceptor, start_link, [Name]},
            restart => transient,
            shutdown => brutal_kill
        }
     || Id <- lists:seq(1, Count)
    ],
    {ok, {SupFlags, Children}}.
