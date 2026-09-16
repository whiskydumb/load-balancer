-module(lb_balancer_source_hash).
-behaviour(lb_balancer).

-export([init/1, pick/2]).

%% weighted rendezvous hashing: every backend scores the key independently and
%% the top score wins. removing a backend remaps only the keys it owned, and an
%% excluded winner falls back to the same runner-up every time

-define(HASH_RANGE, 1 bsl 32).
-define(MASK64, 16#FFFFFFFFFFFFFFFF).

-type entry() :: {lb_balancer:backend_id(), lb_balancer:weight(), IdHash :: 0..16#FFFFFFFF}.

-spec init([lb_balancer:backend()]) -> [entry()].
init(Backends) ->
    [{Id, Weight, erlang:phash2(Id, ?HASH_RANGE)} || {Id, Weight} <- Backends].

-spec pick([entry()], lb_balancer:context()) ->
    {ok, lb_balancer:backend_id()} | {error, no_backend}.
pick(Backends, #{key := Key, exclude := Exclude}) ->
    KeyHash = erlang:phash2(Key, ?HASH_RANGE),
    Scores = [
        {score(KeyHash, IdHash, Weight), Id}
     || {Id, Weight, IdHash} <- Backends, not lists:member(Id, Exclude)
    ],
    case Scores of
        [] ->
            {error, no_backend};
        _ ->
            {_, Winner} = lists:max(Scores),
            {ok, Winner}
    end.

%% phash2 is stable across nodes and otp releases, so separate balancer
%% instances agree on key owners. on its own it leaves scores of one key
%% correlated across backends (even phash2({Key, Id}) does), which skews the
%% weighted race towards heavy backends; the murmur3 finalizer decorrelates them
score(KeyHash, IdHash, Weight) ->
    Hash = fmix64((KeyHash bsl 32) bor IdHash),
    %% top 52 bits centered in their bucket give u strictly inside (0, 1)
    Uniform = ((Hash bsr 12) + 0.5) / (1 bsl 52),
    %% -weight / ln(u) makes the chance to win proportional to the weight
    -Weight / math:log(Uniform).

fmix64(K0) ->
    K1 = ((K0 bxor (K0 bsr 33)) * 16#FF51AFD7ED558CCD) band ?MASK64,
    K2 = ((K1 bxor (K1 bsr 33)) * 16#C4CEB9FE1A85EC53) band ?MASK64,
    K2 bxor (K2 bsr 33).
