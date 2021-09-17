%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Gateway Interface Module for HTTP-APIs
-module(emqx_gateway_http).

-include("include/emqx_gateway.hrl").
-include_lib("emqx/include/logger.hrl").

%% Mgmt APIs - gateway
-export([ gateways/1
        ]).

%% Mgmt APIs - listeners
-export([ listeners/1
        , listener/1
        , remove_listener/1
        , update_listener/2
        , mapping_listener_m2l/2
        ]).

-export([ authn/1
        , update_authn/2
        , remove_authn/1
        ]).

%% Mgmt APIs - clients
-export([ lookup_client/3
        , lookup_client/4
        , kickout_client/2
        , kickout_client/3
        , list_client_subscriptions/2
        , client_subscribe/4
        , client_unsubscribe/3
        ]).

%% Utils for http, swagger, etc.
-export([ return_http_error/2
        , with_gateway/2
        , checks/2
        , schema_bad_request/0
        , schema_not_found/0
        , schema_internal_error/0
        , schema_no_content/0
        ]).

-type gateway_summary() ::
        #{ name := binary()
         , status := running | stopped | unloaded
         , started_at => binary()
         , max_connections => integer()
         , current_connections => integer()
         , listeners => []
         }.

-define(DEFAULT_CALL_TIMEOUT, 15000).

%%--------------------------------------------------------------------
%% Mgmt APIs - gateway
%%--------------------------------------------------------------------

-spec gateways(Status :: all | running | stopped | unloaded)
    -> [gateway_summary()].
gateways(Status) ->
    Gateways = lists:map(fun({GwName, _}) ->
        case emqx_gateway:lookup(GwName) of
            undefined -> #{name => GwName, status => unloaded};
            GwInfo = #{config := Config} ->
                GwInfo0 = emqx_gateway_utils:unix_ts_to_rfc3339(
                            [created_at, started_at, stopped_at],
                            GwInfo),
                GwInfo1 = maps:with([name,
                                     status,
                                     created_at,
                                     started_at,
                                     stopped_at], GwInfo0),
                GwInfo1#{
                  max_connections => max_connections_count(Config),
                  current_connections => current_connections_count(GwName),
                  listeners => get_listeners_status(GwName, Config)}
        end
    end, emqx_gateway_registry:list()),
    case Status of
        all -> Gateways;
        _ ->
            [Gw || Gw = #{status := S} <- Gateways, S == Status]
    end.

%% @private
max_connections_count(Config) ->
    Listeners = emqx_gateway_utils:normalize_config(Config),
    lists:foldl(fun({_, _, _, SocketOpts, _}, Acc) ->
        Acc + proplists:get_value(max_connections, SocketOpts, 0)
    end, 0, Listeners).

%% @private
current_connections_count(GwName) ->
    try
        InfoTab = emqx_gateway_cm:tabname(info, GwName),
        ets:info(InfoTab, size)
    catch _ : _ ->
        0
    end.

%% @private
get_listeners_status(GwName, Config) ->
    Listeners = emqx_gateway_utils:normalize_config(Config),
    lists:map(fun({Type, LisName, ListenOn, _, _}) ->
        Name0 = emqx_gateway_utils:listener_id(GwName, Type, LisName),
        Name = {Name0, ListenOn},
        LisO = #{id => Name0, type => Type, name => LisName},
        case catch esockd:listener(Name) of
            _Pid when is_pid(_Pid) ->
                LisO#{running => true};
            _ ->
                LisO#{running => false}
        end
    end, Listeners).

%%--------------------------------------------------------------------
%% Mgmt APIs - listeners
%%--------------------------------------------------------------------

-spec listeners(atom() | binary()) -> list().
listeners(GwName) when is_atom(GwName) ->
    listeners(atom_to_binary(GwName));
listeners(GwName) ->
    RawConf = emqx_config:fill_defaults(
                emqx_config:get_root_raw([<<"gateway">>])),
    Listeners = emqx_map_lib:jsonable_map(
                  emqx_map_lib:deep_get(
                    [<<"gateway">>, GwName, <<"listeners">>], RawConf)),
    mapping_listener_m2l(GwName, Listeners).

-spec listener(binary()) -> {ok, map()} | {error, not_found} | {error, any()}.
listener(ListenerId) ->
    {GwName, Type, LName} = emqx_gateway_utils:parse_listener_id(ListenerId),
    RootConf = emqx_config:fill_defaults(
                 emqx_config:get_root_raw([<<"gateway">>])),
    try
        Path = [<<"gateway">>, GwName, <<"listeners">>, Type, LName],
        LConf = emqx_map_lib:deep_get(Path, RootConf),
        Running = is_running(binary_to_existing_atom(ListenerId), LConf),
        {ok, emqx_map_lib:jsonable_map(
               LConf#{
                 id => ListenerId,
                 type => Type,
                 name => LName,
                 running => Running})}
    catch
        error : {config_not_found, _} ->
            {error, not_found};
        _Class : Reason ->
            {error, Reason}
    end.

mapping_listener_m2l(GwName, Listeners0) ->
    Listeners = maps:to_list(Listeners0),
    lists:append([listener(GwName, Type, maps:to_list(Conf))
                  || {Type, Conf} <- Listeners]).

listener(GwName, Type, Conf) ->
    [begin
         ListenerId = emqx_gateway_utils:listener_id(GwName, Type, LName),
         Running = is_running(ListenerId, LConf),
         bind2str(
           LConf#{
             id => ListenerId,
             type => Type,
             name => LName,
             running => Running
            })
     end || {LName, LConf} <- Conf, is_map(LConf)].

is_running(ListenerId, #{<<"bind">> := ListenOn0}) ->
    ListenOn = emqx_gateway_utils:parse_listenon(ListenOn0),
    try esockd:listener({ListenerId, ListenOn}) of
        Pid when is_pid(Pid)->
            true
    catch _:_ ->
        false
    end.

bind2str(LConf = #{bind := Bind}) when is_integer(Bind) ->
    maps:put(bind, integer_to_binary(Bind), LConf);
bind2str(LConf = #{<<"bind">> := Bind}) when is_integer(Bind) ->
    maps:put(<<"bind">>, integer_to_binary(Bind), LConf);
bind2str(LConf = #{bind := Bind}) when is_binary(Bind) ->
    LConf;
bind2str(LConf = #{<<"bind">> := Bind}) when is_binary(Bind) ->
    LConf.

-spec remove_listener(binary()) -> ok | {error, not_found} | {error, any()}.
remove_listener(ListenerId) ->
    {GwName, Type, Name} = emqx_gateway_utils:parse_listener_id(ListenerId),
    LConf = emqx:get_raw_config(
              [<<"gateway">>, GwName, <<"listeners">>, Type]
             ),
    NLConf = maps:remove(Name, LConf),
    emqx_gateway:update_rawconf(
      GwName,
      #{<<"listeners">> => #{Type => NLConf}}
     ).

-spec update_listener(atom() | binary(), map()) -> ok | {error, any()}.
update_listener(ListenerId, NewConf0) ->
    {GwName, Type, Name} = emqx_gateway_utils:parse_listener_id(ListenerId),
    NewConf = maps:without([<<"id">>, <<"name">>,
                            <<"type">>, <<"running">>], NewConf0),
    emqx_gateway:update_rawconf(
      GwName,
      #{<<"listeners">> => #{Type => #{Name => NewConf}}
       }).

-spec authn(gateway_name()) -> map() | undefined.
authn(GwName) ->
    case emqx_map_lib:deep_get(
           authentication,
           emqx:get_config([gateway, GwName]),
           undefined)  of
        undefined -> undefined;
        AuthConf -> emqx_map_lib:jsonable_map(AuthConf)
    end.

-spec update_authn(gateway_name(), map()) -> ok | {error, any()}.
update_authn(GwName, AuthConf) ->
    emqx_gateway:update_rawconf(
      atom_to_binary(GwName),
      #{authentication => AuthConf}).

-spec remove_authn(gateway_name()) -> ok | {error, any()}.
remove_authn(_GwName) ->
    {error, not_supported_now}.

%%--------------------------------------------------------------------
%% Mgmt APIs - clients
%%--------------------------------------------------------------------

-spec lookup_client(gateway_name(),
                    emqx_type:clientid(), {atom(), atom()}) -> list().
lookup_client(GwName, ClientId, FormatFun) ->
    lists:append([lookup_client(Node, GwName, {clientid, ClientId}, FormatFun)
                  || Node <- ekka_mnesia:running_nodes()]).

lookup_client(Node, GwName, {clientid, ClientId}, {M,F}) when Node =:= node() ->
    ChanTab = emqx_gateway_cm:tabname(chan, GwName),
    InfoTab = emqx_gateway_cm:tabname(info, GwName),

    lists:append(lists:map(
      fun(Key) ->
        lists:map(fun M:F/1, ets:lookup(InfoTab, Key))
      end, ets:lookup(ChanTab, ClientId)));

lookup_client(Node, GwName, {clientid, ClientId}, FormatFun) ->
    rpc_call(Node, lookup_client,
             [Node, GwName, {clientid, ClientId}, FormatFun]).

-spec kickout_client(gateway_name(), emqx_type:clientid())
    -> {error, any()}
     | ok.
kickout_client(GwName, ClientId) ->
    Results = [kickout_client(Node, GwName, ClientId)
               || Node <- ekka_mnesia:running_nodes()],
    case lists:any(fun(Item) -> Item =:= ok end, Results) of
        true  -> ok;
        false -> lists:last(Results)
    end.

kickout_client(Node, GwName, ClientId) when Node =:= node() ->
    emqx_gateway_cm:kick_session(GwName, ClientId);

kickout_client(Node, GwName, ClientId) ->
    rpc_call(Node, kickout_client, [Node, GwName, ClientId]).

-spec list_client_subscriptions(gateway_name(), emqx_type:clientid())
    -> {error, any()}
     | {ok, list()}.
list_client_subscriptions(GwName, ClientId) ->
    %% Get the subscriptions from session-info
    with_channel(GwName, ClientId,
        fun(Pid) ->
            Subs = emqx_gateway_conn:call(
                     Pid,
                     subscriptions, ?DEFAULT_CALL_TIMEOUT),
            {ok, lists:map(fun({Topic, SubOpts}) ->
                     SubOpts#{topic => Topic}
                 end, Subs)}
        end).

-spec client_subscribe(gateway_name(), emqx_type:clientid(),
                       emqx_type:topic(), emqx_type:subopts())
    -> {error, any()}
     | ok.
client_subscribe(GwName, ClientId, Topic, SubOpts) ->
    with_channel(GwName, ClientId,
        fun(Pid) ->
            emqx_gateway_conn:call(
              Pid, {subscribe, Topic, SubOpts},
              ?DEFAULT_CALL_TIMEOUT
             )
        end).

-spec client_unsubscribe(gateway_name(),
                         emqx_type:clientid(), emqx_type:topic())
    -> {error, any()}
     | ok.
client_unsubscribe(GwName, ClientId, Topic) ->
    with_channel(GwName, ClientId,
        fun(Pid) ->
            emqx_gateway_conn:call(
              Pid, {unsubscribe, Topic}, ?DEFAULT_CALL_TIMEOUT)
        end).

with_channel(GwName, ClientId, Fun) ->
    case emqx_gateway_cm:with_channel(GwName, ClientId, Fun) of
        undefined -> {error, not_found};
        Res -> Res
    end.

%%--------------------------------------------------------------------
%% Utils
%%--------------------------------------------------------------------

-spec return_http_error(integer(), any()) -> {integer(), binary()}.
return_http_error(Code, Msg) ->
    {Code, emqx_json:encode(
             #{code => codestr(Code),
               reason => emqx_gateway_utils:stringfy(Msg)
              })
    }.

codestr(400) -> 'BAD_REQUEST';
codestr(401) -> 'NOT_SUPPORTED_NOW';
codestr(404) -> 'RESOURCE_NOT_FOUND';
codestr(500) -> 'UNKNOW_ERROR'.

-spec with_gateway(binary(), function()) -> any().
with_gateway(GwName0, Fun) ->
    try
        GwName = try
                     binary_to_existing_atom(GwName0)
                 catch _ : _ -> error(badname)
                 end,
        case emqx_gateway:lookup(GwName) of
            undefined ->
                return_http_error(404, "Gateway not load");
            Gateway ->
                Fun(GwName, Gateway)
        end
    catch
        error : badname ->
            return_http_error(404, "Bad gateway name");
        error : {miss_param, K} ->
            return_http_error(400, [K, " is required"]);
        error : {invalid_listener_id, Id} ->
            return_http_error(400, ["invalid listener id: ", Id]);
        Class : Reason : Stk ->
            ?LOG(error, "Uncatched error: {~p, ~p}, stacktrace: ~0p",
                        [Class, Reason, Stk]),
            return_http_error(500, {Class, Reason, Stk})
    end.

-spec checks(list(), map()) -> ok.
checks([], _) ->
    ok;
checks([K|Ks], Map) ->
    case maps:is_key(K, Map) of
        true -> checks(Ks, Map);
        false ->
            error({miss_param, K})
    end.

%%--------------------------------------------------------------------
%% common schemas

schema_bad_request() ->
    emqx_mgmt_util:error_schema(
      <<"Some Params missed">>, ['PARAMETER_MISSED']).
schema_internal_error() ->
    emqx_mgmt_util:error_schema(
      <<"Ineternal Server Error">>, ['INTERNAL_SERVER_ERROR']).
schema_not_found() ->
    emqx_mgmt_util:error_schema(<<"Resource Not Found">>).
schema_no_content() ->
    #{description => <<"No Content">>}.

%%--------------------------------------------------------------------
%% Internal funcs

rpc_call(Node, Fun, Args) ->
    case rpc:call(Node, ?MODULE, Fun, Args) of
        {badrpc, Reason} -> {error, Reason};
        Res -> Res
    end.
