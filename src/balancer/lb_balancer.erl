-module(lb_balancer).

-export([strategies/0, new/2, pick/2]).

-export_type([
    strategy/0,
    backend_id/0,
    weight/0,
    backend/0,
    context/0,
    selector/0
]).

-type strategy() :: round_robin | least_conn | source_hash.
-type backend_id() :: term().
-type weight() :: pos_integer().
-type backend() :: {backend_id(), weight()}.

%% strategies stay pure: shared state is reachable only through these funs,
%% which the pool binds to ets counters and tests bind to local closures
-type context() :: #{
    key := term(),
    exclude := [backend_id()],
    cursor := fun(() -> non_neg_integer()),
    load := fun((backend_id()) -> non_neg_integer())
}.

-opaque selector() :: {module(), term()}.

-callback init([backend()]) -> term().
-callback pick(term(), context()) -> {ok, backend_id()} | {error, no_backend}.

-define(MODULES, #{
    round_robin => lb_balancer_round_robin,
    least_conn => lb_balancer_least_conn,
    source_hash => lb_balancer_source_hash
}).

%% sorted, so error messages and docs list strategies in a stable order
-spec strategies() -> [strategy()].
strategies() ->
    lists:sort(maps:keys(?MODULES)).

%% a selector is an immutable snapshot of pool membership, rebuilt on every change
-spec new(strategy(), [backend()]) -> selector().
new(Strategy, Backends) ->
    Module = maps:get(Strategy, ?MODULES),
    {Module, Module:init(Backends)}.

-spec pick(selector(), context()) -> {ok, backend_id()} | {error, no_backend}.
pick({Module, State}, Context) ->
    Module:pick(State, Context).
