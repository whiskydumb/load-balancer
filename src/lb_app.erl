-module(lb_app).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("kernel/include/logger.hrl").

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case lb_config:load() of
        {ok, Config} ->
            lb_sup:start_link(Config);
        {error, Errors} ->
            ?LOG_ERROR(#{
                event => invalid_config,
                problems => [lb_config:format_error(Error) || Error <- Errors]
            }),
            {error, invalid_config}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
