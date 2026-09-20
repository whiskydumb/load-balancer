-module(lb_listener_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

-spec start_link(lb_config:listener(), lb_config:pool()) -> supervisor:startlink_ret().
start_link(Listener, Pool) ->
    supervisor:start_link(?MODULE, {Listener, Pool}).

-spec init({lb_config:listener(), lb_config:pool()}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({#{drain_timeout := DrainTimeout} = Listener, Pool}) ->
    %% acceptors use the socket the listener publishes, and a new listener means
    %% a new socket, so they start after it and restart with it
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => lb_listener,
            start => {lb_listener, start_link, [Listener, Pool]},
            %% the supervisor has to sit out the drain before it may kill
            shutdown => DrainTimeout + 1000
        },
        #{
            id => lb_acceptor_sup,
            start => {lb_acceptor_sup, start_link, [Listener]},
            type => supervisor
        }
    ],
    {ok, {SupFlags, Children}}.
