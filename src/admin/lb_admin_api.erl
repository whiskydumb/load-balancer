-module(lb_admin_api).

-export([handle/2, bad_request/0, internal_error/0]).

-export_type([token/0]).

%% routes admin requests. /health answers anyone, because orchestrators probe it
%% without credentials; everything else needs the bearer token

%% only the digest of the configured token is ever held in memory
-type token() :: <<_:256>> | undefined.

-spec handle(lb_http:request(), token()) -> lb_http:response().
handle(#{method := Method, path := Path} = Request, Token) ->
    case route(Path) of
        {public, Method, Handler} -> Handler();
        {protected, Method, Handler} -> authorized(Request, Token, Handler);
        {_Access, _Other, _Handler} -> json(405, #{error => <<"method not allowed">>});
        not_found -> json(404, #{error => <<"not found">>})
    end.

-spec bad_request() -> lb_http:response().
bad_request() ->
    json(400, #{error => <<"bad request">>}).

-spec internal_error() -> lb_http:response().
internal_error() ->
    json(500, #{error => <<"internal error">>}).

route(<<"/health">>) -> {public, 'GET', fun health/0};
route(<<"/metrics">>) -> {protected, 'GET', fun metrics/0};
route(<<"/pools">>) -> {protected, 'GET', fun pools/0};
route(<<"/listeners">>) -> {protected, 'GET', fun listeners/0};
route(_Path) -> not_found.

authorized(_Request, undefined, _Handler) ->
    json(403, #{error => <<"admin token is not configured">>});
authorized(#{headers := Headers}, Token, Handler) ->
    case bearer(Headers) of
        %% comparing digests keeps the check constant time and length blind
        {ok, Given} ->
            case crypto:hash_equals(crypto:hash(sha256, Given), Token) of
                true -> Handler();
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

health() ->
    json(200, #{status => ok}).

metrics() ->
    respond(200, <<"text/plain; version=0.0.4; charset=utf-8">>, lb_metrics:render()).

pools() ->
    json(200, #{pools => [pool(Name) || Name <- lb_pool:names()]}).

listeners() ->
    Listeners = [
        Stats#{name => Name}
     || Name <- lb_listener:names(), {ok, Stats} <- [lb_listener:stats(Name)]
    ],
    json(200, #{listeners => Listeners}).

pool(Name) ->
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
