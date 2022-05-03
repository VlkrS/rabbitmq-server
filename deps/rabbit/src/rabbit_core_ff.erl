%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2018-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_core_ff).

-export([direct_exchange_routing_v2_enable/1,
         listener_records_in_ets_enable/1,
         listener_records_in_ets_post_enable/1,
         tracking_records_in_ets_enable/1,
         tracking_records_in_ets_post_enable/1,
         mds_phase1_migration_enable/1,
         mds_phase1_migration_post_enable/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-include("vhost.hrl").
-include("internal_user.hrl").

-rabbit_feature_flag(
   {classic_mirrored_queue_version,
    #{desc          => "Support setting version for classic mirrored queues",
      stability     => stable
     }}).

-rabbit_feature_flag(
   {quorum_queue,
    #{desc          => "Support queues of type `quorum`",
      doc_url       => "https://www.rabbitmq.com/quorum-queues.html",
      stability     => required
     }}).

-rabbit_feature_flag(
   {stream_queue,
    #{desc          => "Support queues of type `stream`",
      doc_url       => "https://www.rabbitmq.com/stream.html",
      stability     => stable,
      depends_on    => [quorum_queue]
     }}).

-rabbit_feature_flag(
   {implicit_default_bindings,
    #{desc          => "Default bindings are now implicit, instead of "
                       "being stored in the database",
      stability     => required
     }}).

-rabbit_feature_flag(
   {virtual_host_metadata,
    #{desc          => "Virtual host metadata (description, tags, etc)",
      stability     => required
     }}).

-rabbit_feature_flag(
   {maintenance_mode_status,
    #{desc          => "Maintenance mode status",
      stability     => required
     }}).

-rabbit_feature_flag(
    {user_limits,
     #{desc          => "Configure connection and channel limits for a user",
       stability     => required
     }}).

-rabbit_feature_flag(
   {stream_single_active_consumer,
    #{desc          => "Single active consumer for streams",
      doc_url       => "https://www.rabbitmq.com/stream.html",
      stability     => stable,
      depends_on    => [stream_queue]
     }}).

-rabbit_feature_flag(
    {feature_flags_v2,
     #{desc          => "Feature flags subsystem V2",
       stability     => stable
     }}).

-rabbit_feature_flag(
   {direct_exchange_routing_v2,
    #{desc       => "v2 direct exchange routing implementation",
      stability  => stable,
      depends_on => [feature_flags_v2, implicit_default_bindings],
      callbacks  => #{enable => {?MODULE, direct_exchange_routing_v2_enable}}
     }}).

-rabbit_feature_flag(
   {listener_records_in_ets,
    #{desc       => "Store listener records in ETS instead of Mnesia",
      stability  => stable,
      depends_on => [feature_flags_v2],
      callbacks  => #{enable =>
                      {?MODULE, listener_records_in_ets_enable},
                      post_enable =>
                      {?MODULE, listener_records_in_ets_post_enable}}
     }}).

-rabbit_feature_flag(
   {tracking_records_in_ets,
    #{desc          => "Store tracking records in ETS instead of Mnesia",
      stability     => stable,
      depends_on    => [feature_flags_v2],
      callbacks     => #{enable =>
                             {?MODULE, tracking_records_in_ets_enable},
                         post_enable =>
                             {?MODULE, tracking_records_in_ets_post_enable}}
     }}).

-rabbit_feature_flag(
   {raft_based_metadata_store_phase1,
    #{desc          => "Use the new Raft-based metadata store [phase 1]",
      doc_url       => "", %% TODO
      stability     => experimental,
      depends_on    => [feature_flags_v2,
                        maintenance_mode_status,
                        user_limits,
                        virtual_host_metadata],
      migration_fun => {?MODULE, mds_phase1_migration}
     }}).

%% -------------------------------------------------------------------
%% Direct exchange routing v2.
%% -------------------------------------------------------------------

-spec direct_exchange_routing_v2_enable(Args) -> Ret when
      Args :: rabbit_feature_flags:enable_callback_args(),
      Ret :: rabbit_feature_flags:enable_callback_ret().
direct_exchange_routing_v2_enable(#{feature_name := FeatureName}) ->
    TableName = rabbit_index_route,
    ok = rabbit_table:wait([rabbit_route], _Retry = true),
    try
        ok = rabbit_table:create(
               TableName, rabbit_table:rabbit_index_route_definition()),
        case rabbit_table:ensure_table_copy(TableName, node(), ram_copies) of
            ok ->
                ok = rabbit_binding:populate_index_route_table();
            {error, Err} = Error ->
                rabbit_log_feature_flags:error(
                  "Feature flags: `~s`: failed to add copy of table ~s to "
                  "node ~p: ~p",
                  [FeatureName, TableName, node(), Err]),
                Error
        end
    catch throw:{error, Reason} ->
              rabbit_log_feature_flags:error(
                "Feature flags: `~s`: enable callback failure: ~p",
                [FeatureName, Reason]),
              {error, Reason}
    end.

%% -------------------------------------------------------------------
%% Listener records moved from Mnesia to ETS.
%% -------------------------------------------------------------------

listener_records_in_ets_enable(#{feature_name := FeatureName}) ->
    try
        rabbit_misc:execute_mnesia_transaction(
          fun () ->
                  mnesia:lock({table, rabbit_listener}, read),
                  Listeners = mnesia:select(
                                rabbit_listener, [{'$1',[],['$1']}]),
                  lists:foreach(
                    fun(Listener) ->
                            ets:insert(rabbit_listener_ets, Listener)
                    end, Listeners)
          end)
    catch
        throw:{error, {no_exists, rabbit_listener}} ->
            ok;
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error(
              "Feature flags: `~s`: failed to migrate Mnesia table: ~p",
              [FeatureName, Reason]),
            {error, Reason}
    end.

listener_records_in_ets_post_enable(#{feature_name := FeatureName}) ->
    try
        case mnesia:delete_table(rabbit_listener) of
            {atomic, ok} ->
                ok;
            {aborted, {no_exists, _}} ->
                ok;
            {aborted, Err} ->
                rabbit_log_feature_flags:error(
                  "Feature flags: `~s`: failed to delete Mnesia table: ~p",
                  [FeatureName, Err]),
                ok
        end
    catch
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error(
              "Feature flags: `~s`: failed to delete Mnesia table: ~p",
              [FeatureName, Reason]),
            ok
    end.

tracking_records_in_ets_enable(#{feature_name := FeatureName}) ->
    try
        rabbit_connection_tracking:migrate_tracking_records(),
        rabbit_channel_tracking:migrate_tracking_records()
    catch
        throw:{error, {no_exists, _}} ->
            ok;
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed: ~p",
                                           [FeatureName, Reason]),
            {error, Reason}
    end.

tracking_records_in_ets_post_enable(#{feature_name := FeatureName}) ->
    try
        [delete_table(FeatureName, Tab) ||
            Tab <- rabbit_connection_tracking:get_all_tracked_connection_table_names_for_node(node())],
        [delete_table(FeatureName, Tab) ||
            Tab <- rabbit_channel_tracking:get_all_tracked_channel_table_names_for_node(node())]
    catch
        throw:{error, Reason} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed: ~p",
                                           [FeatureName, Reason]),
            %% adheres to the callback interface
            ok
    end.

delete_table(FeatureName, Tab) ->
    case mnesia:delete_table(Tab) of
        {atomic, ok} ->
            ok;
        {aborted, {no_exists, _}} ->
            ok;
        {aborted, Err} ->
            rabbit_log_feature_flags:error("Enabling feature flag ~s failed to delete mnesia table ~p: ~p",
                                           [FeatureName, Tab, Err]),
            %% adheres to the callback interface
            ok
    end.

%% -------------------------------------------------------------------
%% Raft-based metadata store (phase 1).
%% -------------------------------------------------------------------

%% Phase 1 covers the migration of the following data:
%%     * virtual hosts
%%     * users and their permissions
%%     * runtime parameters
%% They all depend on each others in Mnesia transactions. That's why they must
%% be migrated atomically.

%% This table order is important. For instance, user permissions depend on
%% both vhosts and users to exist in the metadata store.

%% TODO should they be integrated on phase1?
-define(MDS_PHASE2_TABLES, [rabbit_durable_route,
                            rabbit_semi_durable_route,
                            rabbit_route,
                            rabbit_reverse_route,
                            rabbit_topic_trie_node,
                            rabbit_topic_trie_edge,
                            rabbit_topic_trie_binding]).

-define(MDS_PHASE1_TABLES, [rabbit_vhost,
                            rabbit_user,
                            rabbit_user_permission,
                            rabbit_topic_permission,
                            rabbit_runtime_parameters,
                            rabbit_queue,
                            rabbit_durable_queue,
                            rabbit_exchange,
                            rabbit_durable_exchange,
                            rabbit_exchange_serial] ++ ?MDS_PHASE2_TABLES).

mds_phase1_migration_enable(#{feature_name := FeatureName}) ->
    case ensure_khepri_cluster_matches_mnesia(FeatureName) of
        ok ->
            Tables = ?MDS_PHASE1_TABLES,
            case is_mds_migration_done(FeatureName) of
                false -> migrate_tables_to_khepri(FeatureName, Tables);
                true  -> ok
            end;
        Error ->
            Error
    end.

mds_phase1_migration_post_enable(#{feature_name := FeatureName}) ->
    ?assert(rabbit_khepri:is_enabled(non_blocking)),
    Tables = ?MDS_PHASE1_TABLES,
    empty_unused_mnesia_tables(FeatureName, Tables).

ensure_khepri_cluster_matches_mnesia(FeatureName) ->
    %% Initialize Khepri cluster based on Mnesia running nodes. Verify that
    %% all Mnesia nodes are running (all == running). It would be more
    %% difficult to add them later to the node when they start.
    ?LOG_DEBUG(
       "Feature flag `~s`:   ensure Khepri Ra system is running",
       [FeatureName]),
    ok = rabbit_khepri:setup(),
    ?LOG_DEBUG(
       "Feature flag `~s`:   making sure all Mnesia nodes are running",
       [FeatureName]),
    AllMnesiaNodes = lists:sort(rabbit_mnesia:cluster_nodes(all)),
    RunningMnesiaNodes = lists:sort(rabbit_mnesia:cluster_nodes(running)),
    MissingMnesiaNodes = AllMnesiaNodes -- RunningMnesiaNodes,
    case MissingMnesiaNodes of
        [] ->
            %% This is the first time Khepri will be used for real. Therefore
            %% we need to make sure the Khepri cluster matches the Mnesia
            %% cluster.
            ?LOG_DEBUG(
               "Feature flag `~s`:   updating the Khepri cluster to match "
               "the Mnesia cluster",
               [FeatureName]),
            case expand_khepri_cluster(FeatureName, AllMnesiaNodes) of
                ok ->
                    ok;
                Error ->
                    ?LOG_ERROR(
                       "Feature flag `~s`:   failed to migrate from Mnesia "
                       "to Khepri: failed to create Khepri cluster: ~p",
                       [FeatureName, Error]),
                    Error
            end;
        _ ->
            ?LOG_ERROR(
               "Feature flag `~s`:   failed to migrate from Mnesia to Khepri: "
               "all Mnesia nodes must run; the following nodes are missing: "
               "~p",
               [FeatureName, MissingMnesiaNodes]),
            {error, all_mnesia_nodes_must_run}
    end.

expand_khepri_cluster(FeatureName, AllMnesiaNodes) ->
    %% All Mnesia nodes are running (this is a requirement to enable this
    %% feature flag). We use this unique list of nodes to find the largest
    %% Khepri clusters among all of them.
    %%
    %% The idea is that at the beginning, each Mnesia node will also be an
    %% unclustered Khepri node. Therefore, the first node in the sorted list
    %% of Mnesia nodes will be picked (a "cluster" with 1 member, but the
    %% "largest" at the beginning).
    %%
    %% After the first nodes join that single node, its cluster will grow and
    %% will continue to be the largest.
    %%
    %% This function is executed on the node enabling the feature flag. It will
    %% take care of adding all nodes in the Mnesia cluster to a Khepri cluster
    %% (except those which are already part of it).
    %%
    %% This should avoid the situation where a large established cluster is
    %% reset and joins a single new/empty node.
    %%
    %% Also, we only consider Khepri clusters which are in use (i.e. the
    %% feature flag is enabled). Here is an example:
    %%     - Node2 is the only node in the Mnesia cluster at the time the
    %%       feature flag is enabled. It joins no other node and runs its own
    %%       one-node Khepri cluster.
    %%     - Node1 joins the Mnesia cluster which is now Node1 + Node2. Given
    %%       the sorting, Khepri clusters will be [[Node1], [Node2]] when
    %%       sorted by name and size. With this order, Node1 should "join"
    %%       itself. But the feature is not enabled yet on this node,
    %%       therefore, we skip this cluster to consider the following one,
    %%       [Node2].
    KhepriCluster = find_largest_khepri_cluster(FeatureName),
    NodesToAdd = AllMnesiaNodes -- KhepriCluster,
    ?LOG_DEBUG(
       "Feature flags `~s`:   selected Khepri cluster: ~p",
       [FeatureName, KhepriCluster]),
    ?LOG_DEBUG(
       "Feature flags `~s`:   Mnesia nodes to add to the Khepri cluster "
       "above: ~p",
       [FeatureName, NodesToAdd]),
    add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, NodesToAdd).

add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, [Node | Rest]) ->
    add_node_to_khepri_cluster(FeatureName, KhepriCluster, Node),
    add_nodes_to_khepri_cluster(FeatureName, KhepriCluster, Rest);
add_nodes_to_khepri_cluster(_FeatureName, _KhepriCluster, []) ->
    ok.

add_node_to_khepri_cluster(FeatureName, KhepriCluster, Node) ->
    ?assertNotEqual([], KhepriCluster),
    case lists:member(Node, KhepriCluster) of
        true ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   node ~p is already a member of "
               "the largest cluster: ~p",
               [FeatureName, Node, KhepriCluster]),
            ok;
        false ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   adding node ~p to the largest "
               "Khepri cluster found among Mnesia nodes: ~p",
               [FeatureName, Node, KhepriCluster]),
            case rabbit_khepri:add_member(Node, KhepriCluster) of
                ok                   -> ok;
                {ok, already_member} -> ok
            end
    end.

find_largest_khepri_cluster(FeatureName) ->
    case list_all_khepri_clusters(FeatureName) of
        [] ->
            [node()];
        KhepriClusters ->
            KhepriClustersBySize = sort_khepri_clusters_by_size(
                                     KhepriClusters),
            ?LOG_DEBUG(
               "Feature flag `~s`:   existing Khepri clusters (sorted by "
               "size): ~p",
               [FeatureName, KhepriClustersBySize]),
            LargestKhepriCluster = hd(KhepriClustersBySize),
            LargestKhepriCluster
    end.

list_all_khepri_clusters(FeatureName) ->
    MnesiaNodes = lists:sort(rabbit_mnesia:cluster_nodes(all)),
    ?LOG_DEBUG(
       "Feature flag `~s`:   querying the following Mnesia nodes to learn "
       "their Khepri cluster membership: ~p",
       [FeatureName, MnesiaNodes]),
    KhepriClusters = lists:foldl(
                       fun(MnesiaNode, Acc) ->
                               case khepri_cluster_on_node(MnesiaNode) of
                                   []        -> Acc;
                                   Cluster   -> Acc#{Cluster => true}
                               end
                       end, #{}, MnesiaNodes),
    lists:sort(maps:keys(KhepriClusters)).

sort_khepri_clusters_by_size(KhepriCluster) ->
    lists:sort(
      fun(A, B) -> length(A) >= length(B) end,
      KhepriCluster).

khepri_cluster_on_node(Node) ->
    lists:sort(
      rabbit_misc:rpc_call(Node, rabbit_khepri, nodes_if_khepri_enabled, [])).

migrate_tables_to_khepri(FeatureName, Tables) ->
    rabbit_table:wait(Tables, _Retry = true),
    ?LOG_NOTICE(
       "Feature flag `~s`:   starting migration from Mnesia "
       "to Khepri; expect decrease in performance and "
       "increase in memory footprint",
       [FeatureName]),
    Pid = spawn(
            fun() ->
                    migrate_tables_to_khepri_run(FeatureName, Tables)
            end),
    MonitorRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MonitorRef, process, Pid, normal} ->
            ?LOG_NOTICE(
               "Feature flag `~s`:   migration from Mnesia to Khepri "
               "finished",
               [FeatureName]),
            ok;
        {'DOWN', MonitorRef, process, Pid, Info} ->
            ?LOG_ERROR(
               "Feature flag `~s`:   "
               "failed to migrate Mnesia tables to Khepri:~n  ~p",
               [FeatureName, Info]),
            {error, {migration_failure, Info}}
    end.

migrate_tables_to_khepri_run(FeatureName, Tables) ->
    %% Clear data in Khepri which could come from a previously aborted copy
    %% attempt. The table list order is important so we need to reverse that
    %% order to clear the data.
    ?LOG_DEBUG(
       "Feature flag `~s`:   clear data from any aborted migration attempts "
       "(if any)",
       [FeatureName]),
    ok = clear_data_from_previous_attempt(FeatureName, lists:reverse(Tables)),

    %% Subscribe to Mnesia events: we want to know about all writes and
    %% deletions happening in parallel to the copy we are about to start.
    ?LOG_DEBUG(
       "Feature flag `~s`:   subscribe to Mnesia writes",
       [FeatureName]),
    ok = subscribe_to_mnesia_changes(FeatureName, Tables),

    %% Copy from Mnesia to Khepri. Tables are copied in a specific order to
    %% make sure that if term A depends on term B, term B was copied before.
    ?LOG_DEBUG(
       "Feature flag `~s`:   copy records from Mnesia to Khepri",
       [FeatureName]),
    ok = copy_from_mnesia_to_khepri(FeatureName, Tables),

    %% Mnesia transaction to handle received Mnesia events and tables removal.
    ?LOG_DEBUG(
       "Feature flag `~s`:   final sync and Mnesia table removal",
       [FeatureName]),
    ok = final_sync_from_mnesia_to_khepri(FeatureName, Tables),

    %% Unsubscribe to Mnesia events. All Mnesia tables are synchronized and
    %% read-only at this point.
    ?LOG_DEBUG(
       "Feature flag `~s`:   subscribe to Mnesia writes",
       [FeatureName]),
    ok = unsubscribe_to_mnesia_changes(FeatureName, Tables).

clear_data_from_previous_attempt(
  FeatureName, [rabbit_vhost | Rest]) ->
    ok = rabbit_vhost:clear_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_user | Rest]) ->
    ok = rabbit_auth_backend_internal:clear_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_user_permission | Rest]) ->
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_topic_permission | Rest]) ->
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_runtime_parameters | Rest]) ->
    ok = rabbit_runtime_parameters:clear_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_exchange | Rest]) ->
    ok = rabbit_store:clear_exchange_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_durable_exchange | Rest]) ->
    ok = rabbit_store:clear_durable_exchange_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_exchange_serial | Rest]) ->
    ok = rabbit_store:clear_exchange_serial_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_queue | Rest]) ->
    ok = rabbit_store:clear_queue_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_durable_queue | Rest]) ->
    ok = rabbit_store:clear_durable_queue_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_durable_route | Rest]) ->
    ok = rabbit_store:clear_route_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_semi_durable_route | Rest]) ->
    ok = rabbit_store:clear_route_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_route | Rest]) ->
    ok = rabbit_store:clear_route_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_reverse_route | Rest]) ->
    ok = rabbit_store:clear_route_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_topic_trie_node | Rest]) ->
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_topic_trie_edge | Rest]) ->
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(
  FeatureName, [rabbit_topic_trie_binding | Rest]) ->
    ok = rabbit_store:clear_topic_trie_binding_data_in_khepri(),
    clear_data_from_previous_attempt(FeatureName, Rest);
clear_data_from_previous_attempt(_, []) ->
    ok.

subscribe_to_mnesia_changes(FeatureName, [Table | Rest]) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     subscribe to writes to ~s",
       [FeatureName, Table]),
    case mnesia:subscribe({table, Table, simple}) of
        {ok, _} -> subscribe_to_mnesia_changes(FeatureName, Rest);
        Error   -> Error
    end;
subscribe_to_mnesia_changes(_, []) ->
    ok.

unsubscribe_to_mnesia_changes(FeatureName, [Table | Rest]) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     subscribe to writes to ~s",
       [FeatureName, Table]),
    case mnesia:unsubscribe({table, Table, simple}) of
        {ok, _} -> unsubscribe_to_mnesia_changes(FeatureName, Rest);
        Error   -> Error
    end;
unsubscribe_to_mnesia_changes(_, []) ->
    ok.

copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_vhost = Table | Rest]) ->
    Fun = fun rabbit_vhost:mnesia_write_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_user = Table | Rest]) ->
    Fun = fun rabbit_auth_backend_internal:mnesia_write_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_user_permission = Table | Rest]) ->
    Fun = fun rabbit_auth_backend_internal:mnesia_write_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_topic_permission = Table | Rest]) ->
    Fun = fun rabbit_auth_backend_internal:mnesia_write_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_runtime_parameters = Table | Rest]) ->
    Fun = fun rabbit_runtime_parameters:mnesia_write_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_queue = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_queue_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_durable_queue = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_durable_queue_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_exchange = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_exchange_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_durable_exchange = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_durable_exchange_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_exchange_serial = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_exchange_serial_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_durable_route = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_durable_route_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_semi_durable_route = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_semi_durable_route_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_route = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_route_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_reverse_route = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_reverse_route_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_topic_trie_node | Rest]) ->
    %% Nothing to do, the `rabbit_topic_trie_binding` is enough to perform the migration
    %% as Khepri stores each topic binding as a single path
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_topic_trie_edge | Rest]) ->
    %% Nothing to do, the `rabbit_topic_trie_binding` is enough to perform the migration
    %% as Khepri stores each topic binding as a single path
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(
  FeatureName, [rabbit_topic_trie_binding = Table | Rest]) ->
    Fun = fun rabbit_store:mnesia_write_topic_trie_binding_to_khepri/1,
    do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun),
    copy_from_mnesia_to_khepri(FeatureName, Rest);
copy_from_mnesia_to_khepri(_, []) ->
    ok.

do_copy_from_mnesia_to_khepri(FeatureName, Table, Fun) ->
    Count = mnesia:table_info(Table, size),
    ?LOG_DEBUG(
       "Feature flag `~s`:     table ~s: about ~b record(s) to copy",
       [FeatureName, Table, Count]),
    FirstKey = mnesia:dirty_first(Table),
    do_copy_from_mnesia_to_khepri(
      FeatureName, Table, FirstKey, Fun, Count, 0).

do_copy_from_mnesia_to_khepri(
  FeatureName, Table, '$end_of_table', _, Count, Copied) ->
    ?LOG_DEBUG(
       "Feature flag `~s`:     table ~s: copy of ~b record(s) (out of ~b "
       "initially) finished",
       [FeatureName, Table, Copied, Count]),
    ok;
do_copy_from_mnesia_to_khepri(
  FeatureName, Table, Key, Fun, Count, Copied) ->
    %% TODO: Batch several records in a single Khepri insert.
    %% TODO: Can/should we parallelize?
    case Copied rem 100 of
        0 ->
            ?LOG_DEBUG(
               "Feature flag `~s`:     table ~s: copying record ~b/~b",
               [FeatureName, Table, Copied, Count]);
        _ ->
            ok
    end,
    case mnesia:dirty_read(Table, Key) of
        [Record] -> ok = Fun(Record);
        []       -> ok
    end,
    NextKey = mnesia:dirty_next(Table, Key),
    do_copy_from_mnesia_to_khepri(
      FeatureName, Table, NextKey, Fun, Count, Copied + 1).

final_sync_from_mnesia_to_khepri(FeatureName, Tables) ->
    %% Switch all tables to read-only. All concurrent and future Mnesia
    %% transaction involving a write to one of them will fail with the
    %% `{no_exists, Table}` exception.
    lists:foreach(
      fun(Table) ->
              ?LOG_DEBUG(
                 "Feature flag `~s`:     switch table ~s to read-only",
                 [FeatureName, Table]),
              {atomic, ok} = mnesia:change_table_access_mode(Table, read_only)
      end, Tables),

    %% During the first round of copy, we received all write events as
    %% messages (parallel writes were authorized). Now, we want to consume
    %% those messages to record the writes we probably missed.
    ok = consume_mnesia_events(FeatureName),

    ok.

consume_mnesia_events(FeatureName) ->
    {_, Count} = erlang:process_info(self(), message_queue_len),
    ?LOG_DEBUG(
       "Feature flag `~s`:     handling queued Mnesia events "
       "(about ~b events)",
       [FeatureName, Count]),
    consume_mnesia_events(FeatureName, Count, 0).

consume_mnesia_events(FeatureName, Count, Handled) ->
    %% TODO: Batch several events in a single Khepri command.
    Handled1 = Handled + 1,
    receive
        {mnesia_table_event, {write, NewRecord, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (write)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_write(NewRecord),
            consume_mnesia_events(FeatureName, Count, Handled1);
        {mnesia_table_event, {delete_object, OldRecord, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (delete)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_delete(OldRecord),
            consume_mnesia_events(FeatureName, Count, Handled1);
        {mnesia_table_event, {delete, {Table, Key}, _}} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:       handling event ~b/~b (delete)",
               [FeatureName, Handled1, Count]),
            handle_mnesia_delete(Table, Key),
            consume_mnesia_events(FeatureName, Count, Handled1)
    after 0 ->
              {_, MsgCount} = erlang:process_info(self(), message_queue_len),
              ?LOG_DEBUG(
                 "Feature flag `~s`:     ~b messages remaining",
                 [FeatureName, MsgCount]),
              %% TODO: Wait for confirmation from Khepri.
              ok
    end.

%% TODO handle mnesia_runtime_parameters, rabbit_amqqueue, rabbit_exchange, rabbit_binding,
%% rabbit_exchange_type_topic
handle_mnesia_write(NewRecord) when ?is_vhost(NewRecord) ->
    rabbit_vhost:mnesia_write_to_khepri(NewRecord);
handle_mnesia_write(NewRecord) when is_record(NewRecord, user_permission) ->
    rabbit_auth_backend_internal:mnesia_write_to_khepri(NewRecord);
handle_mnesia_write(NewRecord) when is_record(NewRecord, topic_permission) ->
    rabbit_auth_backend_internal:mnesia_write_to_khepri(NewRecord);
handle_mnesia_write(NewRecord) ->
    %% The record and the Mnesia table have different names.
    NewRecord1 = erlang:setelement(1, NewRecord, internal_user),
    true = ?is_internal_user(NewRecord1),
    rabbit_auth_backend_internal:mnesia_write_to_khepri(NewRecord1).

%% TODO handle mnesia_runtime_parameters, rabbit_amqqueue, rabbit_exchange, rabbit_binding,
%% rabbit_exchange_type_topic
%% TODO do we need to listen to detailed events? If we receive an amqqueue record, we don't
%% know if it belongs to queue or durable queues. On node down we remove the ram copy of queues
%% that live on the down node but they might still be durable
handle_mnesia_delete(OldRecord) when ?is_vhost(OldRecord) ->
    rabbit_vhost:mnesia_delete_to_khepri(OldRecord);
handle_mnesia_delete(OldRecord) when ?is_internal_user(OldRecord) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(OldRecord);
handle_mnesia_delete(OldRecord) when is_record(OldRecord, user_permission) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(OldRecord);
handle_mnesia_delete(OldRecord) when is_record(OldRecord, topic_permission) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(OldRecord).

handle_mnesia_delete(rabbit_vhost, VHost) ->
    rabbit_vhost:mnesia_delete_to_khepri(VHost);
handle_mnesia_delete(rabbit_user, Username) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(Username);
handle_mnesia_delete(rabbit_user_permission, UserVHost) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(UserVHost);
handle_mnesia_delete(rabbit_topic_permission, TopicPermissionKey) ->
    rabbit_auth_backend_internal:mnesia_delete_to_khepri(TopicPermissionKey);
handle_mnesia_delete(rabbit_runtime_parameters, RuntimeParamKey) ->
    rabbit_runtime_parameters:mnesia_delete_to_khepri(RuntimeParamKey);
handle_mnesia_delete(rabbit_queue, QName) ->
    rabbit_store:mnesia_delete_queue_to_khepri(QName);
handle_mnesia_delete(rabbit_durable_queue, QName) ->
    rabbit_store:mnesia_delete_durable_queue_to_khepri(QName).


%% We can't remove unused tables at this point yet. The reason is that tables
%% are synchronized before feature flags in `rabbit_mnesia`. So if a node is
%% already using Khepri and another node wants to join him, but is using Mnesia
%% only, it will hang while trying to sync the dropped tables.
%%
%% We can't simply reverse the two steps (i.e. synchronize feature flags before
%% tables) because some feature flags like `quorum_queue` need tables to modify
%% their schema.
%%
%% Another solution would be to have two groups of feature flags, depending on
%% whether a feature flag should be synchronized before or after Mnesia
%% tables.
%%
%% But for now, let's just empty the tables, add a forged record to mark them
%% as migrated and leave them around.

empty_unused_mnesia_tables(FeatureName, [Table | Rest]) ->
    %% The feature flag is enabled at this point. It means there should be no
    %% code trying to read or write the Mnesia tables.
    case mnesia:change_table_access_mode(Table, read_write) of
        {atomic, ok} ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   dropping content from unused Mnesia "
               "table ~s",
               [FeatureName, Table]),
            ok = empty_unused_mnesia_table(Table);
        {aborted, {already_exists, Table, _}} ->
            %% Another node is already taking care of this table.
            ?LOG_DEBUG(
               "Feature flag `~s`:   Mnesia table ~s already emptied",
               [FeatureName, Table]),
            ok
    end,
    empty_unused_mnesia_tables(FeatureName, Rest);
empty_unused_mnesia_tables(FeatureName, []) ->
            ?LOG_DEBUG(
               "Feature flag `~s`:   done with emptying unused Mnesia tables",
               [FeatureName]),
            ok.

empty_unused_mnesia_table(Table) ->
    FirstKey = mnesia:dirty_first(Table),
    empty_unused_mnesia_table(Table, FirstKey).

empty_unused_mnesia_table(_Table, '$end_of_table') ->
    ok;
empty_unused_mnesia_table(Table, Key) ->
    NextKey = mnesia:dirty_next(Table, Key),
    ok = mnesia:dirty_delete(Table, Key),
    empty_unused_mnesia_table(Table, NextKey).

is_mds_migration_done(FeatureName) ->
    %% To determine if the migration to Khepri was finished, we look at the
    %% state of the feature flag on another node, if any.
    ThisNode = node(),
    KhepriNodes = rabbit_khepri:nodes(),
    case KhepriNodes -- [ThisNode] of
        [] ->
            %% There are no other nodes. It means the node is unclustered
            %% and the migration function is called for the first time. This
            %% function returns `false'.
            ?LOG_DEBUG(
               "Feature flag `~s`:   migration done? false, the node is "
               "unclustered",
               [FeatureName]),
            false;
        [RemoteKhepriNode | _] ->
            %% This node is clustered already, either because of peer discovery
            %% or because of the `expand_khepri_cluster()' function.
            %%
            %% We need to distinguish two situations:
            %%
            %% - The first time the feature flag is enabled in a cluster, we
            %%   want to migrate records from Mnesia to Khepri. In this case,
            %%   the state of the feature flag will be `state_changing' on all
            %%   nodes in the cluster. That's why we can pick any node to query
            %%   its state.
            %%
            %% - When a new node is joining an existing cluster which is
            %%   already using Khepri, we DO NOT want to migrate anything
            %%   (Mnesia tables are empty, or about to be if the
            %%   `post_enabled_locally' code is still running). To determine
            %%   this, we query a remote node (but not this local node) to see
            %%   the feature flag state. If it's `true' (enabled), it means the
            %%   migration is either in progress or done. Otherwise, we are in
            %%   the first situation described above.
            ?LOG_DEBUG(
               "Feature flag `~s`:   migration done? unknown, querying node ~p",
               [FeatureName, RemoteKhepriNode]),
            IsEnabledRemotely = rabbit_misc:rpc_call(
                                  RemoteKhepriNode,
                                  rabbit_feature_flags,
                                  is_enabled,
                                  [FeatureName, non_blocking]),
            ?LOG_DEBUG(
               "Feature flag `~s`:   feature flag state on node ~p: ~p",
               [FeatureName, RemoteKhepriNode, IsEnabledRemotely]),

            %% If the RPC call fails (i.e. returns `{badrpc, ...}'), we throw
            %% an exception because we want the migration function to abort.
            Ret = case IsEnabledRemotely of
                      true            -> true;
                      state_changing  -> false;
                      {badrpc, Error} -> throw(Error)
                  end,
            ?LOG_DEBUG(
               "Feature flag `~s`:   migration done? ~s",
               [FeatureName, Ret]),
            Ret
    end.
