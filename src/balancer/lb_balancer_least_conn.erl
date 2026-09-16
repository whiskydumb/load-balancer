-module(lb_balancer_least_conn).
-behaviour(lb_balancer).

-export([init/1, pick/2]).

%% power of two choices: compare two random backends instead of scanning all.
%% loads are read without coordination, so a burst of concurrent picks sees one
%% snapshot; a full scan would herd the whole burst onto the same backend

-spec init([lb_balancer:backend()]) -> tuple().
init(Backends) ->
    list_to_tuple(Backends).

-spec pick(tuple(), lb_balancer:context()) ->
    {ok, lb_balancer:backend_id()} | {error, no_backend}.
pick(Backends, #{exclude := [], load := Load}) ->
    choose(Backends, Load);
pick(Backends, #{exclude := Exclude, load := Load}) ->
    Allowed = [B || {Id, _} = B <- tuple_to_list(Backends), not lists:member(Id, Exclude)],
    choose(list_to_tuple(Allowed), Load).

choose({}, _Load) ->
    {error, no_backend};
choose({{Id, _Weight}}, _Load) ->
    {ok, Id};
choose(Backends, Load) ->
    Size = tuple_size(Backends),
    First = rand:uniform(Size),
    Second = (First + rand:uniform(Size - 1) - 1) rem Size + 1,
    {IdA, WeightA} = element(First, Backends),
    {IdB, WeightB} = element(Second, Backends),
    %% compares (load + 1) / weight without floats; the +1 lets weight decide
    %% between idle backends
    case (Load(IdA) + 1) * WeightB =< (Load(IdB) + 1) * WeightA of
        true -> {ok, IdA};
        false -> {ok, IdB}
    end.
