-module(lb_table_owner).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-export_type([table/0]).

-include_lib("kernel/include/logger.hrl").

%% owns named ets tables on behalf of processes that restart, so the data
%% outlives them. the tables die with this process, which is why it sits in
%% front of their users under a rest_for_one supervisor

-type table() :: {Name :: atom(), Options :: [term()]}.

-spec start_link([table()]) -> gen_server:start_ret().
start_link(Tables) ->
    gen_server:start_link(?MODULE, Tables, []).

-spec init([table()]) -> {ok, [atom()]}.
init(Tables) ->
    {ok, [ets:new(Name, [named_table | Options]) || {Name, Options} <- Tables]}.

-spec handle_call(term(), gen_server:from(), [atom()]) ->
    {reply, {error, unexpected_call}, [atom()]}.
handle_call(Request, From, Names) ->
    ?LOG_WARNING(#{event => unexpected_call, request => Request, from => From}),
    {reply, {error, unexpected_call}, Names}.

-spec handle_cast(term(), [atom()]) -> {noreply, [atom()]}.
handle_cast(Message, Names) ->
    ?LOG_WARNING(#{event => unexpected_cast, message => Message}),
    {noreply, Names}.
