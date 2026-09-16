-module(lb_gen).

-include_lib("proper/include/proper.hrl").

-export([subset/1]).

%% proper ships no sublist generator, and both the balancer and the config
%% properties need one to drop a random part of a list
subset(Items) ->
    ?LET(
        Mask,
        vector(length(Items), boolean()),
        [Item || {Item, true} <- lists:zip(Items, Mask)]
    ).
