%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(index_settings_manager).

-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(INDEX_CONFIG_KEY, {metakv, <<"/indexing/settings/config">>}).

-export([start_link/0,
         get/1, get/2,
         get_from_config/3,
         update/1, update/2,
         update_txn/1,
         config_upgrade/0,
         config_upgrade_to_watson/1]).

start_link() ->
    work_queue:start_link(?MODULE, fun init/0).

get(Key) ->
    index_settings_manager:get(Key, undefined).

get(Key, Default) when is_atom(Key) ->
    case ets:lookup(?MODULE, Key) of
        [{Key, Value}] ->
            Value;
        [] ->
            Default
    end.

get_from_config(Config, Key, Default) ->
    case Config =:= ns_config:latest() of
        true ->
            index_settings_manager:get(Key, Default);
        false ->
            case ns_config:search(Config, ?INDEX_CONFIG_KEY) of
                {value, JSON} ->
                    do_get_from_json(Key, JSON);
                false ->
                    Default
            end
    end.

do_get_from_json(Key, JSON) ->
    {_, Lens} = lists:keyfind(Key, 1, known_settings()),
    Settings = decode_settings_json(JSON),
    lens_get(Lens, Settings).

update(Props) ->
    work_queue:submit_sync_work(
      ?MODULE,
      fun () ->
              do_update(Props)
      end).

update(Key, Value) ->
    update([{Key, Value}]).

update_txn(Props) ->
    fun (Config, SetFn) ->
            JSON = fetch_settings_json(Config),
            Current = decode_settings_json(JSON),

            New = build_settings_json(Props, Current),
            {commit, SetFn(?INDEX_CONFIG_KEY, New, Config), New}
    end.

config_upgrade() ->
    [{set, ?INDEX_CONFIG_KEY, build_settings_json(default_settings())}].

config_upgrade_to_watson(Config) ->
    JSON = fetch_settings_json(Config),
    Current = decode_settings_json(JSON),
    Nodes = ns_node_disco:nodes_wanted(),
    %% If there are no index nodes in the cluster then set the default
    %% to empty.
    Default = case ns_cluster_membership:service_nodes(Config, Nodes, index) of
                  [] ->
                      [{storageMode, <<"">>}];
                  _ ->
                      [{storageMode, <<"forestdb">>}]
              end,
    New = build_settings_json(Default, Current, extra_known_settings()),
    [{set, ?INDEX_CONFIG_KEY, New}].

%% internal
init() ->
    ets:new(?MODULE, [named_table, set, protected]),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun ({?INDEX_CONFIG_KEY, JSON}, Pid) ->
                                     submit_config_update(Pid, JSON),
                                     Pid;
                                 ({cluster_compat_version, _}, Pid) ->
                                     submit_full_refresh(Pid),
                                     Pid;
                                 (_, Pid) ->
                                     Pid
                             end, self()),
    populate_ets_table().

submit_full_refresh(Pid) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              populate_ets_table()
      end).

submit_config_update(Pid, JSON) ->
    work_queue:submit_work(
      Pid,
      fun () ->
              populate_ets_table(JSON)
      end).

do_update(Props) ->
    RV = ns_config:run_txn(update_txn(Props)),
    case RV of
        {commit, _, NewJSON} ->
            populate_ets_table(NewJSON),
            {ok, ets:tab2list(?MODULE)};
        _ ->
            RV
    end.

fetch_settings_json() ->
    fetch_settings_json(ns_config:latest()).

fetch_settings_json(Config) ->
    ns_config:search(Config, ?INDEX_CONFIG_KEY, <<"{}">>).

build_settings_json(Props) ->
    build_settings_json(Props, dict:new()).

build_settings_json(Props, Dict) ->
    build_settings_json(Props, Dict, known_settings()).

build_settings_json(Props, Dict, KnownSettings) ->
    NewDict = lens_set_many(KnownSettings, Props, Dict),
    ejson:encode({dict:to_list(NewDict)}).

decode_settings_json(JSON) ->
    {Props} = ejson:decode(JSON),
    dict:from_list(Props).

populate_ets_table() ->
    JSON = fetch_settings_json(),
    populate_ets_table(JSON).

populate_ets_table(JSON) ->
    case not cluster_compat_mode:is_cluster_40()
        orelse erlang:get(prev_json) =:= JSON of
        true ->
            ok;
        false ->
            do_populate_ets_table(JSON)
    end.

do_populate_ets_table(JSON) ->
    Dict = decode_settings_json(JSON),
    NotFound = make_ref(),

    lists:foreach(
      fun ({Key, NewValue}) ->
              OldValue = index_settings_manager:get(Key, NotFound),
              case OldValue =:= NewValue of
                  true ->
                      ok;
                  false ->
                      ets:insert(?MODULE, {Key, NewValue}),
                      gen_event:notify(index_events,
                                       {index_settings_change, Key, NewValue})
              end
      end, lens_get_many(known_settings(), Dict)),

    erlang:put(prev_json, JSON).

known_settings() ->
    RV = [{memoryQuota, memory_quota_lens()},
          {generalSettings, general_settings_lens()},
          {compaction, compaction_lens()}],
    case cluster_compat_mode:is_cluster_watson() of
        true ->
            extra_known_settings() ++ RV;
        false ->
            RV
    end.

extra_known_settings() ->
    [{storageMode, id_lens(<<"indexer.settings.storage_mode">>)}].

default_settings() ->
    RV = [{memoryQuota, 256},
          {generalSettings, general_settings_defaults()},
          {compaction, compaction_defaults()}],
    case cluster_compat_mode:is_cluster_watson() of
        true ->
            extra_default_settings() ++ RV;
        false ->
            RV
    end.

extra_default_settings() ->
    [{storageMode, <<"">>}].

id_lens(Key) ->
    Get = fun (Dict) ->
                  dict:fetch(Key, Dict)
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value, Dict)
          end,
    {Get, Set}.

memory_quota_lens() ->
    Key = <<"indexer.settings.memory_quota">>,

    Get = fun (Dict) ->
                  dict:fetch(Key, Dict) div ?MIB
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value * ?MIB, Dict)
          end,
    {Get, Set}.

indexer_threads_lens() ->
    Key = <<"indexer.settings.max_cpu_percent">>,
    Get = fun (Dict) ->
                  dict:fetch(Key, Dict) div 100
          end,
    Set = fun (Value, Dict) ->
                  dict:store(Key, Value * 100, Dict)
          end,
    {Get, Set}.

general_settings_lens_props() ->
    [{indexerThreads, indexer_threads_lens()},
     {memorySnapshotInterval, id_lens(<<"indexer.settings.inmemory_snapshot.interval">>)},
     {stableSnapshotInterval, id_lens(<<"indexer.settings.persisted_snapshot.interval">>)},
     {maxRollbackPoints, id_lens(<<"indexer.settings.recovery.max_rollbacks">>)},
     {logLevel, id_lens(<<"indexer.settings.log_level">>)}].

general_settings_defaults() ->
    [{indexerThreads, 0},
     {memorySnapshotInterval, 200},
     {stableSnapshotInterval, 5000},
     {maxRollbackPoints, 5},
     {logLevel, <<"info">>}].

general_settings_lens_get(Dict) ->
    lens_get_many(general_settings_lens_props(), Dict).

general_settings_lens_set(Values, Dict) ->
    lens_set_many(general_settings_lens_props(), Values, Dict).

general_settings_lens() ->
    {fun general_settings_lens_get/1, fun general_settings_lens_set/2}.

compaction_interval_default() ->
    [{from_hour, 0},
     {to_hour, 0},
     {from_minute, 0},
     {to_minute, 0}].

compaction_interval_lens() ->
    Get = fun (_Dict) ->
                  unused
          end,
    Set = fun (Values0, Dict) ->
                  Values =
                      case Values0 of
                          [] ->
                              compaction_interval_default();
                          _ ->
                              Values0
                      end,

                  {_, FromHour} = lists:keyfind(from_hour, 1, Values),
                  {_, ToHour} = lists:keyfind(to_hour, 1, Values),
                  {_, FromMinute} = lists:keyfind(from_minute, 1, Values),
                  {_, ToMinute} = lists:keyfind(to_minute, 1, Values),

                  Key = <<"indexer.settings.compaction.interval">>,
                  Value = iolist_to_binary(
                            io_lib:format("~2.10.0b:~2.10.0b,~2.10.0b:~2.10.0b",
                                          [FromHour, FromMinute, ToHour, ToMinute])),

                  dict:store(Key, Value, Dict)
          end,
    {Get, Set}.

compaction_lens_props() ->
    [{fragmentation, id_lens(<<"indexer.settings.compaction.min_frag">>)},
     {interval, compaction_interval_lens()}].

compaction_defaults() ->
    [{fragmentation, 30},
     {interval, compaction_interval_default()}].

compaction_lens_get(Dict) ->
    lens_get_many(compaction_lens_props(), Dict).

compaction_lens_set(Values, Dict) ->
    lens_set_many(compaction_lens_props(), Values, Dict).

compaction_lens() ->
    {fun compaction_lens_get/1, fun compaction_lens_set/2}.

lens_get({Get, _}, Dict) ->
    Get(Dict).

lens_get_many(Lenses, Dict) ->
    [{Key, lens_get(L, Dict)} || {Key, L} <- Lenses].

lens_set(Value, {_, Set}, Dict) ->
    Set(Value, Dict).

lens_set_many(Lenses, Values, Dict) ->
    lists:foldl(
      fun ({Key, Value}, Acc) ->
              {Key, L} = lists:keyfind(Key, 1, Lenses),
              lens_set(Value, L, Acc)
      end, Dict, Values).

-ifdef(EUNIT).
defaults_test() ->
    Keys = fun (L) -> lists:sort([K || {K, _} <- L]) end,

    %% TODO: Need to mock cluster_compat_mode:is_cluster_***
    %% ?assertEqual(Keys(known_settings()), Keys(default_settings())),
    ?assertEqual(Keys(compaction_lens_props()), Keys(compaction_defaults())),
    ?assertEqual(Keys(general_settings_lens_props()),
                 Keys(general_settings_defaults())).
-endif.