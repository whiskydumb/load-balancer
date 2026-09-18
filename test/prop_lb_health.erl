-module(prop_lb_health).

-include_lib("proper/include/proper.hrl").

%% the tracker flips exactly when the run of outcomes disagreeing with its
%% status, counted since the last flip, reaches the threshold for that status:
%% never earlier, which would bounce backends, and never later, which would
%% keep a dead one in rotation
prop_flips_exactly_when_the_streak_completes() ->
    ?FORALL(
        {Rise, Fall, Outcomes},
        {range(1, 5), range(1, 5), list(elements([success, failure]))},
        begin
            Threshold = fun
                (up) -> Fall;
                (down) -> Rise
            end,
            {_, _, Holds} = lists:foldl(
                fun(Outcome, {Tracker, Run, Holds}) ->
                    Status = lb_health:status(Tracker),
                    Next = lb_health:observe(Outcome, Tracker),
                    Streak =
                        case disagrees(Outcome, Status) of
                            true -> Run + 1;
                            false -> 0
                        end,
                    Flipped = lb_health:status(Next) =/= Status,
                    Completed = Streak >= Threshold(Status),
                    NextRun =
                        case Flipped of
                            true -> 0;
                            false -> Streak
                        end,
                    {Next, NextRun, Holds andalso Flipped =:= Completed}
                end,
                {lb_health:new(#{rise => Rise, fall => Fall}), 0, true},
                Outcomes
            ),
            Holds
        end
    ).

disagrees(failure, up) -> true;
disagrees(success, down) -> true;
disagrees(_Outcome, _Status) -> false.
