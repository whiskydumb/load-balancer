-module(lb_admin_api).

-export([handle/2, bad_request/0, too_large/0, internal_error/0]).

-export_type([token/0]).

%% routes admin requests. /health answers anyone, because orchestrators probe it
%% without credentials; everything else needs the bearer token. runtime changes
%% last until the node restarts, the config file stays the source of truth

%% only the digest of the configured token is ever held in memory
-type token() :: <<_:256>> | undefined.

-spec handle(lb_http:request(), token()) -> lb_http:response().
handle(#{method := Method, path := Path} = Request, Token) ->
    case route(segments(Path)) of
        {public, Method, Handler} -> Handler(Request);
        {protected, Method, Handler} -> authorized(Request, Token, Handler);
        {_Access, _OtherMethod, _Handler} -> json(405, #{error => <<"method not allowed">>});
        not_found -> not_found()
    end.

-spec bad_request() -> lb_http:response().
bad_request() ->
    json(400, #{error => <<"bad request">>}).

-spec too_large() -> lb_http:response().
too_large() ->
    json(413, #{error => <<"request body too large">>}).

-spec internal_error() -> lb_http:response().
internal_error() ->
    json(500, #{error => <<"internal error">>}).

route([<<"health">>]) ->
    {public, 'GET', fun(_) -> json(200, #{status => ok}) end};
route([<<"metrics">>]) ->
    {protected, 'GET', fun(_) -> metrics() end};
route([<<"listeners">>]) ->
    {protected, 'GET', fun(_) -> listeners() end};
route([<<"pools">>]) ->
    {protected, 'GET', fun(_) -> pools() end};
route([<<"pools">>, Pool, <<"backends">>]) ->
    {protected, 'POST', fun(Request) -> add_backend(Pool, Request) end};
route([<<"pools">>, Pool, <<"backends">>, Backend]) ->
    {protected, 'DELETE', fun(_) -> remove_backend(Pool, Backend) end};
route([<<"pools">>, Pool, <<"backends">>, Backend, <<"drain">>]) ->
    {protected, 'POST', fun(_) -> set_admin(Pool, Backend, fun lb_pool:drain/2, draining) end};
route([<<"pools">>, Pool, <<"backends">>, Backend, <<"enable">>]) ->
    {protected, 'POST', fun(_) -> set_admin(Pool, Backend, fun lb_pool:enable/2, enabled) end};
route(_Segments) ->
    not_found.

segments(Path) ->
    [
        uri_string:percent_decode(Segment)
     || Segment <- binary:split(Path, <<"/">>, [global, trim_all])
    ].

authorized(_Request, undefined, _Handler) ->
    json(403, #{error => <<"admin token is not configured">>});
authorized(#{headers := Headers} = Request, Token, Handler) ->
    case bearer(Headers) of
        %% comparing digests keeps the check constant time and length blind
        {ok, Given} ->
            case crypto:hash_equals(crypto:hash(sha256, Given), Token) of
                true -> Handler(Request);
                false -> unauthorized()
            end;
        error ->
            unauthorized()
    end.

%% the scheme is case insensitive, the token is not
bearer(#{<<"authorization">> := Value}) ->
    case binary:split(Value, <<" ">>) of
        [Scheme, Given] ->
            case string:lowercase(Scheme) of
                <<"bearer">> -> {ok, string:trim(Given)};
                _Other -> error
            end;
        _NoScheme ->
            error
    end;
bearer(#{}) ->
    error.

metrics() ->
    respond(200, <<"text/plain; version=0.0.4; charset=utf-8">>, lb_metrics:render()).

listeners() ->
    Listeners = [
        Stats#{name => Name}
     || Name <- lb_listener:names(), {ok, Stats} <- [lb_listener:stats(Name)]
    ],
    json(200, #{listeners => Listeners}).

pools() ->
    json(200, #{pools => [pool_view(Name) || Name <- lb_pool:names()]}).

pool_view(Name) ->
    case lb_pool:backends(Name) of
        {ok, Statuses} ->
            #{
                name => Name,
                backends => [
                    Status#{backend := lb_backend:format(Id)}
                 || #{backend := Id} = Status <- Statuses
                ]
            };
        {error, Reason} ->
            #{name => Name, error => Reason}
    end.

add_backend(PoolName, #{body := Body}) ->
    maybe
        {ok, Pool} ?= pool(PoolName),
        {ok, Input} ?= json_object(Body),
        {ok, Backend} ?= lb_config:validate_backend(Input),
        ok ?= lb_pool:add_backend(Pool, Backend),
        json(201, #{added => lb_backend:format(lb_backend:id(Backend))})
    else
        {error, unknown_pool} ->
            not_found();
        {error, not_json} ->
            json(400, #{error => <<"body must be a json object">>});
        {error, already_exists} ->
            json(409, #{error => <<"backend is already in the pool">>});
        {error, Problems} when is_list(Problems) ->
            json(400, #{
                error => <<"invalid backend">>,
                problems => [lb_config:format_error(Problem) || Problem <- Problems]
            })
    end.

remove_backend(PoolName, BackendName) ->
    maybe
        {ok, Pool} ?= pool(PoolName),
        {ok, Backend} ?= lb_backend:parse(BackendName),
        ok ?= lb_pool:remove_backend(Pool, Backend),
        json(200, #{removed => lb_backend:format(Backend)})
    else
        {error, _Unknown} -> not_found()
    end.

set_admin(PoolName, BackendName, Change, Mode) ->
    maybe
        {ok, Pool} ?= pool(PoolName),
        {ok, Backend} ?= lb_backend:parse(BackendName),
        ok ?= Change(Pool, Backend),
        json(200, #{backend => lb_backend:format(Backend), admin => Mode})
    else
        {error, _Unknown} -> not_found()
    end.

%% only names of running pools resolve, so a request can never create atoms
pool(Name) ->
    try binary_to_existing_atom(Name) of
        Pool ->
            case lb_pool:pid(Pool) of
                undefined -> {error, unknown_pool};
                _Running -> {ok, Pool}
            end
    catch
        error:badarg -> {error, unknown_pool}
    end.

%% keys become atoms only where such atoms already exist; the rest stay binaries
%% and the schema reports them as unknown options
json_object(Body) ->
    try json:decode(Body) of
        Object when is_map(Object) ->
            {ok, maps:fold(fun(Key, Value, Acc) -> Acc#{key(Key) => Value} end, #{}, Object)};
        _NotAnObject ->
            {error, not_json}
    catch
        error:_Malformed -> {error, not_json}
    end.

key(Key) ->
    try
        binary_to_existing_atom(Key)
    catch
        error:badarg -> Key
    end.

not_found() ->
    json(404, #{error => <<"not found">>}).

unauthorized() ->
    #{headers := Headers} = Response = json(401, #{error => <<"missing or invalid bearer token">>}),
    Response#{headers := [{<<"www-authenticate">>, <<"Bearer">>} | Headers]}.

json(Status, Body) ->
    respond(Status, <<"application/json">>, json:encode(Body)).

respond(Status, ContentType, Body) ->
    #{
        status => Status,
        headers => [
            {<<"content-type">>, ContentType},
            %% admin data is never meant to be cached or sniffed
            {<<"cache-control">>, <<"no-store">>},
            {<<"x-content-type-options">>, <<"nosniff">>}
        ],
        body => Body
    }.
