-module(lb_admin).
-behaviour(gen_server).

-export([start_link/1, port/0]).
-export([init/1, handle_call/3, handle_cast/2]).
-export([accept/2]).

-include_lib("kernel/include/logger.hrl").

%% serves the admin api on its own port. a linked acceptor takes connections
%% and every request runs in a short-lived process of its own, so one slow
%% client cannot hold the api up

-define(REQUEST_TIMEOUT, 5000).
-define(LINGER, 1000).
-define(BACKOFF, 100).

-record(state, {socket :: gen_tcp:socket(), port :: inet:port_number()}).

-spec start_link(lb_config:admin()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-spec port() -> inet:port_number().
port() ->
    gen_server:call(?MODULE, port).

-spec init(lb_config:admin()) -> {ok, #state{}} | {stop, {listen_failed, term()}}.
init(#{ip := Ip, port := Port}) ->
    Options = [binary, {ip, Ip}, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} ->
            {ok, Bound} = inet:port(Socket),
            Token = token(),
            _ = proc_lib:spawn_link(?MODULE, accept, [Socket, Token]),
            ?LOG_INFO(#{
                event => admin_started,
                address => list_to_binary(inet:ntoa(Ip)),
                port => Bound,
                token_configured => Token =/= undefined
            }),
            {ok, #state{socket = Socket, port = Bound}};
        {error, Reason} ->
            ?LOG_ERROR(#{event => listen_failed, listener => admin, port => Port, reason => Reason}),
            {stop, {listen_failed, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(Request, From, State) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Message, State) ->
    ?LOG_WARNING(#{event => unexpected_cast, message => Message}),
    {noreply, State}.

%% linked to the server: if either dies the other follows and both restart
-spec accept(gen_tcp:socket(), lb_admin_api:token()) -> no_return().
accept(Listen, Token) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            ok = hand_over(Socket, proc_lib:spawn(fun() -> serve(Token) end)),
            accept(Listen, Token);
        {error, closed} ->
            exit(listen_socket_closed);
        {error, Reason} ->
            ?LOG_WARNING(#{event => accept_failed, listener => admin, reason => Reason}),
            timer:sleep(?BACKOFF),
            accept(Listen, Token)
    end.

hand_over(Socket, Handler) ->
    case gen_tcp:controlling_process(Socket, Handler) of
        ok ->
            Handler ! {socket, Socket},
            ok;
        {error, _HandlerGone} ->
            gen_tcp:close(Socket)
    end.

serve(Token) ->
    receive
        {socket, Socket} ->
            case lb_http:read_request(Socket, ?REQUEST_TIMEOUT) of
                {ok, Request} ->
                    Response = handle(Request, Token),
                    _ = lb_http:send_response(Socket, Response),
                    log_access(Request, Response);
                {error, closed} ->
                    ok;
                {error, _Malformed} ->
                    _ = lb_http:send_response(Socket, lb_admin_api:bad_request())
            end,
            linger_close(Socket)
    after ?REQUEST_TIMEOUT -> ok
    end.

%% closing with unread input makes the tcp stack send a reset, which can wipe out
%% the response before the client reads it; draining the input first avoids that
linger_close(Socket) ->
    _ = gen_tcp:shutdown(Socket, write),
    drain(Socket, erlang:monotonic_time(millisecond) + ?LINGER),
    gen_tcp:close(Socket).

drain(Socket, Deadline) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left > 0 andalso gen_tcp:recv(Socket, 0, Left) of
        {ok, _Discarded} -> drain(Socket, Deadline);
        _Done -> ok
    end.

%% a crashing handler still answers, so a client never waits for a timeout
handle(Request, Token) ->
    try
        lb_admin_api:handle(Request, Token)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{
                event => admin_request_failed,
                path => maps:get(path, Request),
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),
            lb_admin_api:internal_error()
    end.

%% failed authentication is worth an operator's attention, routine scrapes are not
log_access(#{method := Method, path := Path}, #{status := Status}) when
    Status =:= 401; Status =:= 403
->
    ?LOG_WARNING(#{event => admin_access_denied, method => Method, path => Path, status => Status});
log_access(#{method := Method, path := Path}, #{status := Status}) ->
    ?LOG_DEBUG(#{event => admin_request, method => Method, path => Path, status => Status}).

%% only a digest is kept, so a crash report can never print the token itself
token() ->
    case os:getenv("LB_ADMIN_TOKEN", "") of
        "" -> undefined;
        Token -> crypto:hash(sha256, unicode:characters_to_binary(Token))
    end.
