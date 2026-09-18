-module(lb_health).

-export([new/1, observe/2, status/1]).

-export_type([status/0, outcome/0, tracker/0]).

%% hysteresis over consecutive results: a backend flips only after `fall`
%% failures in a row while up, or `rise` successes in a row while down, so one
%% lost probe or one refused connection does not bounce it out of rotation

-type status() :: up | down.
-type outcome() :: success | failure.

-record(tracker, {
    status = up :: status(),
    %% consecutive outcomes that disagree with the current status
    streak = 0 :: non_neg_integer(),
    rise :: pos_integer(),
    fall :: pos_integer()
}).

-opaque tracker() :: #tracker{}.

%% backends start up, so traffic flows at boot and the first failures take
%% them out
-spec new(lb_config:health_check()) -> tracker().
new(#{rise := Rise, fall := Fall}) ->
    #tracker{rise = Rise, fall = Fall}.

-spec observe(outcome(), tracker()) -> tracker().
observe(success, #tracker{status = up} = Tracker) ->
    Tracker#tracker{streak = 0};
observe(failure, #tracker{status = down} = Tracker) ->
    Tracker#tracker{streak = 0};
observe(failure, #tracker{status = up, streak = Streak, fall = Fall} = Tracker) when
    Streak + 1 >= Fall
->
    Tracker#tracker{status = down, streak = 0};
observe(success, #tracker{status = down, streak = Streak, rise = Rise} = Tracker) when
    Streak + 1 >= Rise
->
    Tracker#tracker{status = up, streak = 0};
observe(_Disagreeing, #tracker{streak = Streak} = Tracker) ->
    Tracker#tracker{streak = Streak + 1}.

-spec status(tracker()) -> status().
status(#tracker{status = Status}) ->
    Status.
