%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% @private
-module(amqp_connection_sup).

-include("amqp_client.hrl").

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link(AMQPParams) ->
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    {ok, TypeSup} = supervisor:start_child(
        Sup, #{
            id => connection_type_sup,
            start => {amqp_connection_type_sup, start_link, []},
            restart => transient,
            shutdown => ?SUPERVISOR_WAIT,
            type => supervisor,
            modules => [amqp_connection_type_sup]
        }
    ),
    {ok, Connection} = supervisor:start_child(
        Sup, #{
            id => connection,
            start => {amqp_gen_connection, start_link, [TypeSup, AMQPParams]},
            restart => transient,
            significant => true,
            shutdown => brutal_kill,
            type => worker,
            modules => [amqp_gen_connection]
        }
    ),
    {ok, Sup, Connection}.

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
