-module(lb_balancer_ctx).

-export([new/0, new/1, picks/2, pick_by_key/2]).

%% pick context backed by a private cursor and a static load table, standing in
%% for the shared counters the pool provides at runtime

new() ->
    new(#{}).

new(Options) ->
    Cursor = counters:new(1, []),
    ok = counters:add(Cursor, 1, maps:get(start, Options, 0)),
    Loads = maps:get(loads, Options, #{}),
    #{
        key => maps:get(key, Options, undefined),
        exclude => maps:get(exclude, Options, []),
        cursor => fun() ->
            Position = counters:get(Cursor, 1),
            ok = counters:add(Cursor, 1, 1),
            Position
        end,
        load => fun(Id) -> maps:get(Id, Loads, 0) end
    }.

%% consecutive picks through one context, as consecutive connections would do
picks(Selector, Count) ->
    Context = new(),
    [
        begin
            {ok, Id} = lb_balancer:pick(Selector, Context),
            Id
        end
     || _ <- lists:seq(1, Count)
    ].

pick_by_key(Selector, Key) ->
    lb_balancer:pick(Selector, new(#{key => Key})).
