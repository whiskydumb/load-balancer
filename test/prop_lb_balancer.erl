-module(prop_lb_balancer).

-include_lib("proper/include/proper.hrl").

%% prop_* functions are exported by the proper parse transform

prop_picks_a_member() ->
    ?FORALL(
        {Strategy, Backends, Key, Start},
        {strategy(), backends(), address(), cursor_start()},
        begin
            Context = lb_balancer_ctx:new(#{key => Key, start => Start}),
            {ok, Id} = lb_balancer:pick(lb_balancer:new(Strategy, Backends), Context),
            lists:keymember(Id, 1, Backends)
        end
    ).

prop_excluded_backends_are_never_picked() ->
    ?FORALL(
        {Strategy, {Backends, Exclude}, Key, Start},
        {strategy(), backends_with_exclusions(), address(), cursor_start()},
        begin
            Context = lb_balancer_ctx:new(#{key => Key, start => Start, exclude => Exclude}),
            case lb_balancer:pick(lb_balancer:new(Strategy, Backends), Context) of
                {ok, Id} -> not lists:member(Id, Exclude);
                {error, no_backend} -> length(Exclude) =:= length(Backends)
            end
        end
    ).

%% one pick per unit of total weight covers whole cycles, so counts are exact
prop_round_robin_cycle_follows_weights() ->
    ?FORALL(
        Backends,
        backends(),
        begin
            Picks = lb_balancer_ctx:picks(lb_balancer:new(round_robin, Backends), total(Backends)),
            lists:all(fun({Id, Weight}) -> count(Id, Picks) =:= Weight end, Backends)
        end
    ).

%% no prefix of the cycle gives a backend a whole pick more than its exact share,
%% so a heavy backend cannot grab a run of picks. the opposite bound does not
%% hold: a light backend may lag behind by more than one pick
prop_round_robin_never_runs_ahead_of_weight() ->
    ?FORALL(
        Backends,
        backends(),
        begin
            Total = total(Backends),
            Picks = lb_balancer_ctx:picks(lb_balancer:new(round_robin, Backends), Total),
            Steps = lists:zip(lists:seq(1, Total), prefix_counts(Picks)),
            lists:all(
                fun({Step, Taken}) ->
                    lists:all(
                        fun({Id, Weight}) ->
                            Total * maps:get(Id, Taken, 0) - Step * Weight < Total
                        end,
                        Backends
                    )
                end,
                Steps
            )
        end
    ).

%% the random pair varies, but a strictly most expensive backend loses every
%% comparison, so it can only be returned when it is the sole candidate
prop_least_conn_never_picks_the_most_loaded() ->
    ?FORALL(
        {Backends, Loads},
        ?LET(Bs, backends(), {Bs, loads(Bs)}),
        begin
            Context = lb_balancer_ctx:new(#{loads => Loads}),
            {ok, Id} = lb_balancer:pick(lb_balancer:new(least_conn, Backends), Context),
            {Id, Weight} = lists:keyfind(Id, 1, Backends),
            Cost = maps:get(Id, Loads) + 1,
            length(Backends) =:= 1 orelse
                lists:any(
                    fun({Other, OtherWeight}) ->
                        Other =/= Id andalso
                            Cost * OtherWeight =< (maps:get(Other, Loads) + 1) * Weight
                    end,
                    Backends
                )
        end
    ).

prop_source_hash_moves_only_orphaned_keys() ->
    ?FORALL(
        {{Backends, Removed}, Keys},
        {backends_with_removal(), list(address())},
        begin
            Before = lb_balancer:new(source_hash, Backends),
            After = lb_balancer:new(source_hash, lists:keydelete(Removed, 1, Backends)),
            lists:all(
                fun(Key) ->
                    {ok, Owner} = lb_balancer_ctx:pick_by_key(Before, Key),
                    Owner =:= Removed orelse
                        lb_balancer_ctx:pick_by_key(After, Key) =:= {ok, Owner}
                end,
                Keys
            )
        end
    ).

strategy() ->
    elements(lb_balancer:strategies()).

%% unique ids with weights inside the range the config allows
backends() ->
    ?LET(Pairs, non_empty(list({range(1, 32), weight()})), lists:ukeysort(1, Pairs)).

weight() ->
    range(1, 100).

backends_with_exclusions() ->
    ?LET(Backends, backends(), {Backends, lb_gen:subset(ids(Backends))}).

%% id 0 is outside the generated range, so the pool always keeps a survivor
backends_with_removal() ->
    ?LET(
        Backends,
        ?LET({Weight, Rest}, {weight(), backends()}, [{0, Weight} | Rest]),
        {Backends, elements(ids(Backends))}
    ).

loads(Backends) ->
    ?LET(
        Values,
        vector(length(Backends), range(0, 1000)),
        maps:from_list(lists:zip(ids(Backends), Values))
    ).

address() ->
    {range(0, 255), range(0, 255), range(0, 255), range(0, 255)}.

cursor_start() ->
    range(0, 1 bsl 32).

ids(Backends) ->
    [Id || {Id, _} <- Backends].

total(Backends) ->
    lists:sum([Weight || {_, Weight} <- Backends]).

count(Id, Ids) ->
    length([I || I <- Ids, I =:= Id]).

prefix_counts(Picks) ->
    {Counts, _} = lists:mapfoldl(
        fun(Id, Taken) ->
            Next = maps:update_with(Id, fun(N) -> N + 1 end, 1, Taken),
            {Next, Next}
        end,
        #{},
        Picks
    ),
    Counts.
