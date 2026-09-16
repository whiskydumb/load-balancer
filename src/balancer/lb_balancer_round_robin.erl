-module(lb_balancer_round_robin).
-behaviour(lb_balancer).

-export([init/1, pick/2]).

%% smooth weighted round robin, as in nginx: weights a=5 b=1 c=1 produce
%% "a a b a c a a" instead of "a a a a a b c". the cycle is precomputed when
%% membership changes, so a pick is one cursor increment and a tuple lookup

-spec init([lb_balancer:backend()]) -> tuple().
init([]) ->
    {};
init(Backends) ->
    Divisor = lists:foldl(fun({_, Weight}, Acc) -> gcd(Weight, Acc) end, 0, Backends),
    Weights = [{Id, Weight div Divisor, 0} || {Id, Weight} <- Backends],
    Total = lists:sum([Weight || {_, Weight, _} <- Weights]),
    list_to_tuple(cycle(Total, Total, Weights, [])).

-spec pick(tuple(), lb_balancer:context()) ->
    {ok, lb_balancer:backend_id()} | {error, no_backend}.
pick({}, _Context) ->
    {error, no_backend};
pick(Cycle, #{cursor := Cursor, exclude := Exclude}) ->
    Size = tuple_size(Cycle),
    scan(Cycle, Cursor() rem Size, Size, Exclude).

%% every step raises each backend by its weight, then the leader pays back the
%% total, so heavy backends win often but never many times in a row
cycle(0, _Total, _Weights, Acc) ->
    lists:reverse(Acc);
cycle(Steps, Total, Weights, Acc) ->
    Raised = [{Id, Weight, Current + Weight} || {Id, Weight, Current} <- Weights],
    {Leader, LeaderWeight, LeaderCurrent} = lists:foldl(fun highest/2, hd(Raised), tl(Raised)),
    Paid = lists:keyreplace(Leader, 1, Raised, {Leader, LeaderWeight, LeaderCurrent - Total}),
    cycle(Steps - 1, Total, Paid, [Leader | Acc]).

%% ties go to the earlier backend, which keeps the cycle deterministic
highest({_, _, Current} = Candidate, {_, _, Best}) when Current > Best ->
    Candidate;
highest(_Candidate, Best) ->
    Best.

%% a retry reuses the position instead of advancing the shared cursor again;
%% walking forward keeps the weighted order and reaches every backend
scan(_Cycle, _Index, 0, _Exclude) ->
    {error, no_backend};
scan(Cycle, Index, Left, Exclude) ->
    Id = element(Index + 1, Cycle),
    case lists:member(Id, Exclude) of
        false -> {ok, Id};
        true -> scan(Cycle, (Index + 1) rem tuple_size(Cycle), Left - 1, Exclude)
    end.

gcd(A, 0) -> A;
gcd(A, B) -> gcd(B, A rem B).
