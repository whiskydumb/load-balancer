-module(lb_metrics).

-export([render/0]).

%% a prometheus snapshot of the running listeners and pools. counters live next
%% to the code that bumps them; this module only reads and labels them

-spec render() -> iolist().
render() ->
    lb_prometheus:format(listener_families() ++ backend_families() ++ vm_families()).

listener_families() ->
    Listeners = [
        {#{listener => Name}, Stats}
     || Name <- lb_listener:names(),
        {ok, Stats} <- [available(fun() -> lb_listener:stats(Name) end)]
    ],
    Pick = fun(Key) -> [{Labels, maps:get(Key, Stats)} || {Labels, Stats} <- Listeners] end,
    [
        counter(
            lb_listener_connections_accepted_total,
            <<"Client connections handed to a proxy.">>,
            Pick(accepted)
        ),
        gauge(
            lb_listener_connections_active,
            <<"Client connections being proxied.">>,
            Pick(active)
        ),
        counter(
            lb_listener_bytes_total,
            <<"Bytes relayed; upstream flows from client to backend.">>,
            [
                {Labels#{direction => Direction}, maps:get(Direction, Stats)}
             || {Labels, Stats} <- Listeners, Direction <- [upstream, downstream]
            ]
        ),
        counter(
            lb_listener_no_backend_total,
            <<"Clients closed because no backend could take them.">>,
            Pick(no_backend)
        )
    ].

backend_families() ->
    Backends = [
        {#{pool => Pool, backend => lb_backend:format(Backend)}, Status}
     || Pool <- lb_pool:names(),
        {ok, Statuses} <- [available(fun() -> lb_pool:backends(Pool) end)],
        #{backend := Backend} = Status <- Statuses
    ],
    Pick = fun(Key) -> [{Labels, maps:get(Key, Status)} || {Labels, Status} <- Backends] end,
    [
        gauge(
            lb_backend_up,
            <<"1 while the backend passes its health checks.">>,
            [{Labels, up(Status)} || {Labels, Status} <- Backends]
        ),
        gauge(
            lb_backend_draining,
            <<"1 while an operator keeps new connections away from the backend.">>,
            [{Labels, draining(Status)} || {Labels, Status} <- Backends]
        ),
        gauge(
            lb_backend_connections_active,
            <<"Connections currently open to the backend.">>,
            Pick(active)
        ),
        counter(
            lb_backend_connections_total,
            <<"Connections established to the backend.">>,
            Pick(connections_total)
        ),
        counter(
            lb_backend_connect_failures_total,
            <<"Connection attempts the backend refused or let time out.">>,
            Pick(connect_failures_total)
        )
    ].

vm_families() ->
    [
        gauge(lb_vm_processes, <<"Erlang processes alive.">>, [
            {#{}, erlang:system_info(process_count)}
        ]),
        gauge(lb_vm_memory_bytes, <<"Memory allocated by the runtime.">>, [
            {#{}, erlang:memory(total)}
        ])
    ].

%% a listener or pool in the middle of a restart is left out of this scrape
%% instead of failing all of it
available(Fetch) ->
    try
        Fetch()
    catch
        exit:_ -> {error, unavailable}
    end.

up(#{health := up}) -> 1;
up(#{health := down}) -> 0.

draining(#{admin := draining}) -> 1;
draining(#{admin := enabled}) -> 0.

counter(Name, Help, Samples) ->
    #{name => Name, type => counter, help => Help, samples => Samples}.

gauge(Name, Help, Samples) ->
    #{name => Name, type => gauge, help => Help, samples => Samples}.
