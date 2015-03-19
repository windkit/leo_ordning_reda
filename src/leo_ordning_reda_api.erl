%%======================================================================
%%
%% Leo Ordning & Reda
%%
%% Copyright (c) 2012-2015 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% @doc The ordning-reda's API
%% @reference https://github.com/leo-project/leo_ordning_reda/blob/master/src/leo_ordning_reda_api.erl
%% @end
%%======================================================================
-module(leo_ordning_reda_api).
-author('Yosuke Hara').

-include("leo_ordning_reda.hrl").
-include_lib("eunit/include/eunit.hrl").


%% Application callbacks
-export([start/0, stop/0,
         add_container/2, remove_container/1, has_container/1,
         stack/3, pack/1, unpack/2, force_sending_obj/1]).

%% -define(PREFIX, "leo_ord_reda_").

-ifdef(TEST).
-define(out_put_info_log(_Fun, _Unit),
        error_logger:info_msg("~p,~p,~p,~p~n",
                              [{module, ?MODULE_STRING},
                               {function, _Fun},
                               {line, ?LINE}, {body, _Unit}])).
-else.
-define(out_put_info_log(_Fun,_Unit), ok).
-endif.


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Launch the application
%%
-spec(start() ->
             ok | {error, any()}).
start() ->
    start_app().


%% @doc Stop the application
%%
-spec(stop() ->
             ok | {error, any()}).
stop() ->
    leo_ordning_reda_sup:stop().


%% @doc Add the container into the App
%%
-spec(add_container(Unit, Options) ->
             ok | {error, any()} when Unit::atom(),
                                      Options::[any()]).
add_container(Unit, Options) ->
    ChildId = {leo_ord_reda, Unit},
    Module  = leo_misc:get_value(?PROP_ORDRED_MOD,      Options),
    BufSize = leo_misc:get_value(?PROP_ORDRED_BUF_SIZE, Options, ?DEF_BUF_SIZE),
    Timeout = leo_misc:get_value(?PROP_ORDRED_TIMEOUT,  Options, ?REQ_TIMEOUT),
    IsComp  = leo_misc:get_value(?PROP_ORDRED_IS_COMP,  Options, true),
    TmpStackedDir = ?env_temp_stacked_dir(),

    Args = [#stack_info{unit     = Unit,
                        module   = Module,
                        buf_size = BufSize,
                        timeout  = Timeout,
                        is_compression_obj = IsComp,
                        tmp_stacked_dir = TmpStackedDir
                       }],
    ChildSpec = {ChildId,
                 {leo_ordning_reda_server, start_link, Args},
                 temporary, 2000, worker, [leo_ordning_reda_server]},

    case supervisor:start_child(leo_ordning_reda_sup, ChildSpec) of
        {ok, PId} ->
            %% Remove the unnecessary record,
            %% then insert the record
            case catch ets:lookup(?ETS_TAB_STACK_PID, Unit) of
                [Rec|_] ->
                    catch ets:delete_object(?ETS_TAB_STACK_PID, Rec),
                    ok;
                _ ->
                    ok
            end,
            case catch ets:insert(?ETS_TAB_STACK_PID, {Unit, PId}) of
                {'EXIT', Cause} ->
                    {error, Cause};
                true ->
                    ok
            end;
        {error, Cause} ->
            {error, Cause}
    end.


%% @doc Remove the container from the App
%%
-spec(remove_container(Unit) ->
             ok | {error, any()} when Unit::atom()).
remove_container(Unit) ->
    case get_pid_by_unit(Unit) of
        {ok, PId} ->
            case is_process_alive(PId) of
                true ->
                    case supervisor:which_children('leo_ordning_reda_sup') of
                        [] ->
                            ok;
                        Children ->
                            %% Remove the process from sup
                            ok = remove_container_1(Children, PId),
                            ?out_put_info_log("remove_container/1", Unit),

                            %% Remove the unnecessary record
                            case catch ets:lookup(?ETS_TAB_STACK_PID, Unit) of
                                [Rec|_] ->
                                    catch ets:delete_object(?ETS_TAB_STACK_PID, Rec),
                                    ok;
                                _ ->
                                    ok
                            end
                    end;
                false ->
                    ok
            end;
        _ ->
            ok
    end.


%% @private
remove_container_1([],_) ->
    ok;
remove_container_1([{_Id, PId, worker, ['leo_ordning_reda_server'|_]}|_], PId) ->
    _ = supervisor:terminate_child(leo_ordning_reda_sup, _Id),
    _ = supervisor:delete_child(leo_ordning_reda_sup, _Id),
    ok;
remove_container_1([_|T],PId) ->
    remove_container_1(T, PId).


%% @doc Check whether the container exists
%%
-spec(has_container(Unit) ->
             true | false when Unit::atom()).
has_container(Unit) ->
    case get_pid_by_unit(Unit) of
        {ok, PId} ->
            is_process_alive(PId);
        {error, not_alive} ->
            false
    end.


%% @doc Stack the object into the container
%%
-spec(stack(Unit, StrawId, Object) ->
             ok | {error, any()} when Unit::atom(),
                                      StrawId::any(),
                                      Object::binary()).
stack(Unit, StrawId, Object) ->
    case get_pid_by_unit(Unit) of
        {ok, PId} ->
            leo_ordning_reda_server:stack(PId, StrawId, Object);
        _ ->
            {error, undefined}
    end.


%% @doc Pack the object
%%
-spec(pack(Object) ->
             {ok, Bin} | {error, _} when Object::any(),
                                         Bin::binary()).
pack(Object) ->
    ObjBin = term_to_binary(Object),
    SizeBin = binary:encode_unsigned(byte_size(ObjBin)),
    case byte_size(SizeBin) of
        1 ->
            {ok, <<0/integer, SizeBin/binary, ObjBin/binary>>};
        2 ->
            {ok, <<SizeBin/binary, ObjBin/binary>>};
        _ ->
            {error, "too big object!"}
    end.

%% @doc Unpack the object
%%
-spec(unpack(CompressedBin, Fun) ->
             ok when CompressedBin::binary(),
                     Fun::function()).
unpack(CompressedBin, Fun) ->
    {ok, Bin} = lz4:unpack(CompressedBin),
    unpack_1(Bin, Fun).

-spec(unpack_1(Bin, Fun) ->
             ok when Bin :: binary(),
                     Fun :: function()).
unpack_1(<<>>,_Fun) ->
    ok;
unpack_1(Bin, Fun) ->
    %% Retrieve an object
    H    = binary:part(Bin, {0, 2}),
    Size = binary:decode_unsigned(H),
    Obj  = binary_to_term(binary:part(Bin, {2, Size})),
    %% Execute fun
    Fun(Obj),

    %% Retrieve rest objects
    Rest = binary:part(Bin, {2 + Size, byte_size(Bin) - 2 - Size}),
    unpack_1(Rest, Fun).


%% @doc Force executing object transfer
%%
-spec(force_sending_obj(Unit) ->
             ok | {error, undefined} when Unit::atom()).
force_sending_obj(Unit) ->
    case get_pid_by_unit(Unit) of
        {ok, PId} ->
            leo_ordning_reda_server:exec(PId);
        _ ->
            {error, undefined}
    end.


%%--------------------------------------------------------------------
%% INNTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Launch the ordning-reda application
%% @private
-spec(start_app() ->
             ok | {error, any()}).
start_app() ->
    Module = leo_ordning_reda,
    case application:start(Module) of
        ok ->
            case ets:info(?ETS_TAB_STACK_PID) of
                undefined ->
                    ?ETS_TAB_STACK_PID =
                        ets:new(?ETS_TAB_STACK_PID,
                                [named_table, set, public, {read_concurrency, true}]),
                    ok;
                _ ->
                    ok
            end;
        {error, {already_started, Module}} ->
            ok;
        {error, Cause} ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING},
                                    {function, "start_app/0"},
                                    {line, ?LINE}, {body, Cause}]),
            {exit, Cause}
    end.


%% @doc Retrieve pid by the unit
%% @private
-spec(get_pid_by_unit(Unit) ->
             {ok, pid()} |
             {error, not_alive} when Unit::atom()).
get_pid_by_unit(Unit) ->
    case catch ets:lookup(?ETS_TAB_STACK_PID, Unit) of
        {'EXIT',Cause} ->
            {error, Cause};
        [] ->
            {error, not_found};
        [{_,PId}|_] ->
            {ok, PId}
    end.
