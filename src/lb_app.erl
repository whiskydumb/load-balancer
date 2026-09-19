-module(lb_app).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("kernel/include/logger.hrl").

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    ok = configure_log_format(os:getenv("LB_LOG_FORMAT", "text")),
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

%% readable text by default; LB_LOG_FORMAT=json writes one object per line
configure_log_format("json") ->
    case logger:update_handler_config(default, formatter, {lb_log_formatter, #{}}) of
        ok -> ok;
        {error, Reason} -> ?LOG_WARNING(#{event => log_format_not_applied, reason => Reason})
    end;
configure_log_format(_Text) ->
    ok.
