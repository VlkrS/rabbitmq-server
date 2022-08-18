%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% @private
-module(amqp_connection_type_sup).

-include("amqp_client_internal.hrl").

-behaviour(supervisor).

-export([start_link/0, start_infrastructure_fun/3, type_module/1]).

-export([init/1]).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link() ->
    supervisor:start_link(?MODULE, []).

type_module(#amqp_params_direct{})  -> {direct, amqp_direct_connection};
type_module(#amqp_params_network{}) -> {network, amqp_network_connection}.

%%---------------------------------------------------------------------------

start_channels_manager(Sup, Conn, ConnName, Type) ->
    {ok, ChSupSup} = supervisor:start_child(
        Sup,
        #{
            id => channel_sup_sup,
            start => {amqp_channel_sup_sup, start_link, [Type, Conn, ConnName]},
            restart => transient,
            significant => true,
            shutdown => ?SUPERVISOR_WAIT,
            type => supervisor,
            modules => [amqp_channel_sup_sup]
        }
    ),
    {ok, _} = supervisor:start_child(
        Sup,
        #{
            id => channels_manager,
            start => {amqp_channels_manager, start_link, [Conn, ConnName, ChSupSup]},
            restart => transient,
            shutdown => ?WORKER_WAIT,
            type => worker,
            modules => [amqp_channels_manager]
        }
    ).

start_infrastructure_fun(Sup, Conn, network) ->
    fun (Sock, ConnName) ->
            {ok, ChMgr} = start_channels_manager(Sup, Conn, ConnName, network),
            {ok, AState} = rabbit_command_assembler:init(?PROTOCOL),
            {ok, GCThreshold} = application:get_env(amqp_client, writer_gc_threshold),
            {ok, Writer} =
                supervisor:start_child(
                    Sup,
                    #{
                        id => writer,
                        start =>
                            {rabbit_writer, start_link, [
                                Sock,
                                0,
                                ?FRAME_MIN_SIZE,
                                ?PROTOCOL,
                                Conn,
                                ConnName,
                                false,
                                GCThreshold
                            ]},
                        restart => transient,
                        shutdown => ?WORKER_WAIT,
                        type => worker,
                        modules => [rabbit_writer]
                    }
                ),
            {ok, Reader} =
                supervisor:start_child(
                    Sup,
                    #{
                        id => main_reader,
                        start => {amqp_main_reader, start_link, [Sock, Conn, ChMgr, AState, ConnName]},
                        restart => transient,
                        shutdown => ?WORKER_WAIT,
                        type => worker,
                        modules => [amqp_main_reader]
                    }
                ),
        case rabbit_net:controlling_process(Sock, Reader) of
            ok ->
                case amqp_main_reader:post_init(Reader) of
                  ok ->
                    {ok, ChMgr, Writer};
                  {error, Reason} ->
                    {error, Reason}
                end;
              {error, Reason} ->
                {error, Reason}
            end
    end;
start_infrastructure_fun(Sup, Conn, direct) ->
    fun (ConnName) ->
            {ok, ChMgr} = start_channels_manager(Sup, Conn, ConnName, direct),
            {ok, Collector} =
                supervisor:start_child(
                    Sup,
                    #{
                        id => collector,
                        start => {rabbit_queue_collector, start_link, [ConnName]},
                        restart => transient,
                        shutdown => ?WORKER_WAIT,
                        type => worker,
                        modules => [rabbit_queue_collector]
                    }
                ),
            {ok, ChMgr, Collector}
    end.

%%---------------------------------------------------------------------------
%% supervisor callbacks
%%---------------------------------------------------------------------------

init([]) ->
    {ok,
        {
            #{
                strategy => one_for_all,
                intensity => 0,
                period => 1,
                auto_shutdown => any_significant
            },
            []
        }}.
