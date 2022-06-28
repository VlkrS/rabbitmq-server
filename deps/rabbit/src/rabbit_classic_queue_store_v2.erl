%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% The classic queue store works as follow:
%%
%% When a message needs to be written to disk, it is appended to
%% its corresponding segment file. An offset is returned and that
%% offset will be added to the #msg_status (in lieu of msg_id)
%% and eventually written to disk by the index as well.
%%
%% The corresponding segment file is found by looking at the
%% SeqId, just like the index. There's a 1:1 abstract mapping
%% between index segment files and store segment files. (But
%% whether there are two files for each segment is another
%% question.)
%%
%% Messages are only ever written once to the store. Messages
%% are not reference counted, and are not shared between queues.
%%
%% Messages cannot be removed from the message store individually.
%% Instead, when the index deletes one of its segment files, it
%% tells the queue to also delete the corresponding segment files
%% in the store. This means that store segment files can grow
%% very large because their size is only limited by the number
%% of entries in the index.
%%
%% Messages are synced to disk only when the index tells us
%% they should be. What this effectively means is that the
%% ?STORE:sync function is called right before the ?INDEX:sync
%% function, and only if there are outstanding confirms in the
%% index.
%%
%% The old rabbit_msg_store has separate transient/persistent stores
%% to make recovery of data on disk quicker. We do not need to
%% do this here, because the recovery is only done via the index,
%% which already knows about persistent messages and does not
%% need to look into the store to discard them. Messages on disk
%% will be dropped at the same time as the index deletes the
%% corresponding segment file.
%%
%% The file_handle_cache reservations are done by the v2 index
%% because they are handled at a pid level. Since we are using
%% up to 2 FDs in this module we make the index reserve 2 extra
%% FDs.

-module(rabbit_classic_queue_store_v2).

-export([init/1, terminate/1,
         write/4, sync/1, read/3, check_msg_on_disk/3,
         remove/2, delete_segments/2]).

-define(SEGMENT_EXTENSION, ".qs").

-define(MAGIC, 16#52435153). %% "RCQS"
-define(VERSION, 2).
-define(HEADER_SIZE,       64). %% bytes
-define(ENTRY_HEADER_SIZE,  8). %% bytes

-include_lib("rabbit_common/include/rabbit.hrl").

%% Set to true to get an awful lot of debug logs.
-if(false).
-define(DEBUG(X,Y), logger:debug("~0p: " ++ X, [?FUNCTION_NAME|Y])).
-else.
-define(DEBUG(X,Y), _ = X, _ = Y, ok).
-endif.

-type buffer() :: #{
    %% SeqId => {Offset, Size, Msg}
    rabbit_variable_queue:seq_id() => {non_neg_integer(), non_neg_integer(), #basic_message{}}
}.

-record(qs, {
    %% Store directory - same as the queue index.
    dir :: file:filename(),

    %% We keep track of which segment is open
    %% and the current offset in the file. This offset
    %% is the position at which the next message will
    %% be written. The offset will be returned to be
    %% kept track of in the queue (or queue index) for
    %% later reads.
    write_segment = undefined :: undefined | non_neg_integer(),
    write_offset = ?HEADER_SIZE :: non_neg_integer(),

    %% We must keep the offset, expected size and message in order
    %% to write the message.
    write_buffer = #{} :: buffer(),
    write_buffer_size = 0 :: non_neg_integer(),

    %% We keep a cache of messages for faster reading
    %% for the cases where consumers can keep up with
    %% producers. The write_buffer becomes the cache
    %% when it is written to disk.
    cache = #{} :: buffer(),

    %% Similarly, we keep track of a single read fd.
    %% We cannot share this fd with the write fd because
    %% we are using file:pread/3 which leaves the file
    %% position undetermined.
    read_segment = undefined :: undefined | non_neg_integer(),
    read_fd = undefined :: undefined | file:fd()
}).

-type state() :: #qs{}.

-type msg_location() :: {?MODULE, non_neg_integer(), non_neg_integer()}.
-export_type([msg_location/0]).

-spec init(rabbit_amqqueue:name()) -> state().

init(#resource{ virtual_host = VHost } = Name) ->
    ?DEBUG("~0p", [Name]),
    VHostDir = rabbit_vhost:msg_store_dir_path(VHost),
    Dir = rabbit_classic_queue_index_v2:queue_dir(VHostDir, Name),
    #qs{dir = Dir}.

-spec terminate(State) -> State when State::state().

terminate(State0 = #qs{ read_fd = ReadFd }) ->
    ?DEBUG("~0p", [State0]),
    State = flush_buffer(State0),
    maybe_close_fd(ReadFd),
    State#qs{ write_segment = undefined,
              write_offset = ?HEADER_SIZE,
              read_segment = undefined,
              read_fd = undefined }.

maybe_close_fd(undefined) ->
    ok;
maybe_close_fd(Fd) ->
    ok = file:close(Fd).

-spec write(rabbit_variable_queue:seq_id(), rabbit_types:basic_message(),
            rabbit_types:message_properties(), State)
        -> {msg_location(), State} when State::state().

%% @todo I think we can disable the old message store at the same
%%       place where we create MsgId. If many queues receive the
%%       message, then we create an MsgId. If not, we don't. But
%%       we can only do this after removing support for v1.
write(SeqId, Msg, Props, State0 = #qs{ write_buffer = WriteBuffer0,
                                       write_buffer_size = WriteBufferSize }) ->
    ?DEBUG("~0p ~0p ~0p ~0p", [SeqId, Msg, Props, State0]),
    SegmentEntryCount = segment_entry_count(),
    Segment = SeqId div SegmentEntryCount,
    Size = erlang:external_size(Msg),
    {Offset, State1} = get_write_offset(Segment, Size, State0),
    WriteBuffer = WriteBuffer0#{SeqId => {Offset, Size, Msg}},
    State = State1#qs{ write_buffer = WriteBuffer,
                       write_buffer_size = WriteBufferSize + Size },
    {{?MODULE, Offset, Size}, maybe_flush_buffer(State)}.

get_write_offset(Segment, Size, State = #qs{ write_segment = Segment,
                                             write_offset = Offset }) ->
    {Offset, State#qs{ write_offset = Offset + ?ENTRY_HEADER_SIZE + Size }};
get_write_offset(Segment, Size, State = #qs{ write_segment = WriteSegment })
        when Segment > WriteSegment; WriteSegment =:= undefined ->
    SegmentEntryCount = segment_entry_count(),
    FromSeqId = Segment * SegmentEntryCount,
    ToSeqId = FromSeqId + SegmentEntryCount,
    ok = file:write_file(segment_file(Segment, State),
        << ?MAGIC:32,
           ?VERSION:8,
           FromSeqId:64/unsigned,
           ToSeqId:64/unsigned,
           0:344 >>,
        [raw]),
    {?HEADER_SIZE, State#qs{ write_segment = Segment,
                             write_offset = ?HEADER_SIZE + ?ENTRY_HEADER_SIZE + Size }}.

-spec sync(State) -> State when State::state().

sync(State) ->
    ?DEBUG("~0p", [State]),
    flush_buffer(State).

maybe_flush_buffer(State = #qs{ write_buffer_size = WriteBufferSize }) ->
    case WriteBufferSize >= max_cache_size() of
        true -> flush_buffer(State);
        false -> State
    end.

flush_buffer(State = #qs{ write_buffer_size = 0 }) ->
    State;
flush_buffer(State0 = #qs{ write_buffer = WriteBuffer }) ->
    CheckCRC32 = check_crc32(),
    SegmentEntryCount = segment_entry_count(),
    %% First we prepare the writes sorted by segment.
    WriteList = lists:sort(maps:to_list(WriteBuffer)),
    Writes = flush_buffer_build(WriteList, CheckCRC32, SegmentEntryCount),
    %% Then we do the writes for each segment.
    State = lists:foldl(fun({Segment, LocBytes}, FoldState) ->
        {ok, Fd} = file:open(segment_file(Segment, FoldState), [read, write, raw, binary]),
        ok = file:pwrite(Fd, lists:sort(LocBytes)),
        ok = file:close(Fd),
        FoldState
    end, State0, Writes),
    %% Finally we move the write_buffer to the cache.
    State#qs{ write_buffer = #{},
              write_buffer_size = 0,
              cache = WriteBuffer }.

flush_buffer_build(WriteBuffer = [{FirstSeqId, {Offset, _, _}}|_],
                   CheckCRC32, SegmentEntryCount) ->
    Segment = FirstSeqId div SegmentEntryCount,
    SegmentThreshold = (1 + Segment) * SegmentEntryCount,
    {Tail, LocBytes} = flush_buffer_build(WriteBuffer,
        CheckCRC32, SegmentThreshold, ?HEADER_SIZE, Offset, [], []),
    [{Segment, LocBytes}|flush_buffer_build(Tail, CheckCRC32, SegmentEntryCount)];
flush_buffer_build([], _, _) ->
    [].

flush_buffer_build(Tail = [{SeqId, _}|_], _, SegmentThreshold, _, WriteOffset, WriteAcc, Acc)
        when SeqId >= SegmentThreshold ->
    case WriteAcc of
        [] -> {Tail, Acc};
        _ -> {Tail, [{WriteOffset, lists:reverse(WriteAcc)}|Acc]}
    end;
flush_buffer_build([{_, Entry = {Offset, Size, _}}|Tail],
        CheckCRC32, SegmentEntryCount, Offset, WriteOffset, WriteAcc, Acc) ->
    flush_buffer_build(Tail, CheckCRC32, SegmentEntryCount,
        Offset + ?ENTRY_HEADER_SIZE + Size, WriteOffset,
        [build_data(Entry, CheckCRC32)|WriteAcc], Acc);
flush_buffer_build([{_, Entry = {Offset, Size, _}}|Tail],
        CheckCRC32, SegmentEntryCount, _, _, [], Acc) ->
    flush_buffer_build(Tail, CheckCRC32, SegmentEntryCount,
        Offset + ?ENTRY_HEADER_SIZE + Size, Offset, [build_data(Entry, CheckCRC32)], Acc);
flush_buffer_build([{_, Entry = {Offset, Size, _}}|Tail],
        CheckCRC32, SegmentEntryCount, _, WriteOffset, WriteAcc, Acc) ->
    flush_buffer_build(Tail, CheckCRC32, SegmentEntryCount,
        Offset + ?ENTRY_HEADER_SIZE + Size, Offset, [build_data(Entry, CheckCRC32)],
        [{WriteOffset, lists:reverse(WriteAcc)}|Acc]);
flush_buffer_build([], _, _, _, _, [], Acc) ->
    {[], Acc};
flush_buffer_build([], _, _, _, WriteOffset, WriteAcc, Acc) ->
    {[], [{WriteOffset, lists:reverse(WriteAcc)}|Acc]}.

build_data({_, Size, Msg}, CheckCRC32) ->
    MsgIovec = term_to_iovec(Msg),
    Padding = (Size - iolist_size(MsgIovec)) * 8,
    %% Calculate the CRC for the data if configured to do so.
    %% We will truncate the CRC to 16 bits to save on space. (Idea taken from postgres.)
    {UseCRC32, CRC32} = case CheckCRC32 of
        true -> {1, erlang:crc32(MsgIovec)};
        false -> {0, 0}
    end,
    [
        <<Size:32/unsigned, 0:7, UseCRC32:1, CRC32:16, 0:8>>,
        MsgIovec, <<0:Padding>>
    ].

-spec read(rabbit_variable_queue:seq_id(), msg_location(), State)
        -> {rabbit_types:basic_message(), State} when State::state().

%% @todo We should try to have a read_many for when reading many from the index
%%       so that we fetch many different messages in a single file:pread. See
%%       if that helps improve the performance.
read(SeqId, DiskLocation, State = #qs{ write_buffer = WriteBuffer,
                                       cache = Cache }) ->
    ?DEBUG("~0p ~0p ~0p", [SeqId, DiskLocation, State]),
    case WriteBuffer of
        #{ SeqId := {_, _, Msg} } ->
            {Msg, State};
        _ ->
            case Cache of
                #{ SeqId := {_, _, Msg} } ->
                    {Msg, State};
                _ ->
                    read_from_disk(SeqId, DiskLocation, State)
            end
    end.

read_from_disk(SeqId, {?MODULE, Offset, Size}, State0) ->
    SegmentEntryCount = segment_entry_count(),
    Segment = SeqId div SegmentEntryCount,
    {ok, Fd, State} = get_read_fd(Segment, State0),
    {ok, MsgBin0} = file:pread(Fd, Offset, ?ENTRY_HEADER_SIZE + Size),
    %% Assert the size to make sure we read the correct data.
    %% Check the CRC if configured to do so.
    <<Size:32/unsigned, _:7, UseCRC32:1, CRC32Expected:16/bits, _:8, MsgBin:Size/binary>> = MsgBin0,
    case UseCRC32 of
        0 ->
            ok;
        1 ->
            %% Always check the CRC32 if it was computed on write.
            CRC32 = erlang:crc32(MsgBin),
            %% We currently crash if the CRC32 is incorrect as we cannot recover automatically.
            try
                CRC32Expected = <<CRC32:16>>,
                ok
            catch C:E:S ->
                rabbit_log:error("Per-queue store CRC32 check failed in ~s seq id ~b offset ~b size ~b",
                                 [segment_file(Segment, State), SeqId, Offset, Size]),
                erlang:raise(C, E, S)
            end
    end,
    Msg = binary_to_term(MsgBin),
    {Msg, State}.

get_read_fd(Segment, State = #qs{ read_segment = Segment,
                                  read_fd = Fd }) ->
    {ok, Fd, State};
get_read_fd(Segment, State = #qs{ read_fd = OldFd }) ->
    maybe_close_fd(OldFd),
    case file:open(segment_file(Segment, State), [read, raw, binary]) of
        {ok, Fd} ->
            case file:read(Fd, ?HEADER_SIZE) of
                {ok, <<?MAGIC:32,?VERSION:8,
                       _FromSeqId:64/unsigned,_ToSeqId:64/unsigned,
                       _/bits>>} ->
                    {ok, Fd, State#qs{ read_segment = Segment,
                                       read_fd = Fd }};
                eof ->
                    %% Something is wrong with the file. Close it
                    %% and let the caller decide what to do with it.
                    file:close(Fd),
                    {{error, bad_header}, State#qs{ read_segment = undefined,
                                                    read_fd = undefined }}
            end;
        {error, enoent} ->
            {{error, no_file}, State}
    end.

-spec check_msg_on_disk(rabbit_variable_queue:seq_id(), msg_location(), State)
        -> {ok | {error, any()}, State} when State::state().

check_msg_on_disk(SeqId, {?MODULE, Offset, Size}, State0) ->
    SegmentEntryCount = segment_entry_count(),
    Segment = SeqId div SegmentEntryCount,
    case get_read_fd(Segment, State0) of
        {ok, Fd, State} ->
            case file:pread(Fd, Offset, ?ENTRY_HEADER_SIZE + Size) of
                {ok, MsgBin0} ->
                    %% Assert the size to make sure we read the correct data.
                    %% Check the CRC if configured to do so.
                    case MsgBin0 of
                        <<Size:32/unsigned, _:7, UseCRC32:1, CRC32Expected:16/bits, _:8, MsgBin:Size/binary>> ->
                            case UseCRC32 of
                                0 ->
                                    {ok, State};
                                1 ->
                                    %% We only want to check the CRC32 if configured to do so.
                                    case check_crc32() of
                                        false ->
                                            {ok, State};
                                        true ->
                                            CRC32 = erlang:crc32(MsgBin),
                                            case <<CRC32:16>> of
                                                CRC32Expected -> {ok, State};
                                                _ -> {{error, bad_crc}, State}
                                            end
                                    end
                            end;
                        _ ->
                            {{error, bad_size}, State}
                    end;
                eof ->
                    {{error, eof}, State};
                Error ->
                    {Error, State}
            end;
        {Error, State} ->
            {Error, State}
    end.

-spec remove(rabbit_variable_queue:seq_id(), State) -> State when State::state().

%% We only remove the message from the write_buffer. We will remove
%% the message from the disk when we delete the segment file, and
%% from the cache on the next write.
remove(SeqId, State = #qs{ write_buffer = WriteBuffer0,
                           write_buffer_size = WriteBufferSize }) ->
    ?DEBUG("~0p ~0p", [SeqId, State]),
    case maps:take(SeqId, WriteBuffer0) of
        error ->
            State;
        {{_, MsgSize, _}, WriteBuffer} ->
            State#qs{ write_buffer = WriteBuffer,
                      write_buffer_size = WriteBufferSize - MsgSize }
    end.

-spec delete_segments([non_neg_integer()], State) -> State when State::state().

%% First we check if the write fd points to a segment
%% that must be deleted, and we close it if that's the case.
delete_segments([], State) ->
    ?DEBUG("[] ~0p", [State]),
    State;
delete_segments(Segments, State0 = #qs{ write_buffer = WriteBuffer0,
                                        write_buffer_size = WriteBufferSize0,
                                        read_segment = ReadSegment,
                                        read_fd = ReadFd }) ->
    ?DEBUG("~0p ~0p", [Segments, State0]),
    %% First we have to close fds for the segments, if any.
    %% 'undefined' is never in Segments so we don't
    %% need to special case it.
    CloseRead = lists:member(ReadSegment, Segments),
    State = if
        CloseRead ->
            ok = file:close(ReadFd),
            State0#qs{ read_segment = undefined,
                       read_fd = undefined };
        true ->
            State0
    end,
    %% Then we delete the files.
    _ = [
        case prim_file:delete(segment_file(Segment, State)) of
            ok -> ok;
            %% The file might not have been created. This is the case
            %% if all messages were sent to the per-vhost store for example.
            {error, enoent} -> ok
        end
    || Segment <- Segments],
    %% Finally, we remove any entries from the buffer that fall within
    %% the segments that were deleted. For simplicity's sake, we take
    %% the highest SeqId from these files and remove any SeqId lower
    %% than or equal to this SeqId from the buffer.
    %%
    %% @todo If this becomes a performance issue we may take inspiration
    %%       from sets:filter/2.
    HighestSegment = lists:foldl(fun
        (S, SAcc) when S > SAcc -> S;
        (_, SAcc) -> SAcc
    end, -1, Segments),
    HighestSeqId = (1 + HighestSegment) * segment_entry_count(),
    {WriteBuffer, WriteBufferSize} = maps:fold(fun
        (SeqId, {_, MsgSize, _}, {WriteBufferAcc, WriteBufferSize1})
                when SeqId =< HighestSeqId ->
            {WriteBufferAcc, WriteBufferSize1 - MsgSize};
        (SeqId, Value, {WriteBufferAcc, WriteBufferSize1}) ->
            {WriteBufferAcc#{SeqId => Value}, WriteBufferSize1}
    end, {#{}, WriteBufferSize0}, WriteBuffer0),
    State#qs{ write_buffer = WriteBuffer,
              write_buffer_size = WriteBufferSize }.

%% ----
%%
%% Internal.

segment_entry_count() ->
    %% We use the same value as the index.
    application:get_env(rabbit, classic_queue_index_v2_segment_entry_count, 4096).

max_cache_size() ->
    application:get_env(rabbit, classic_queue_store_v2_max_cache_size, 512000).

check_crc32() ->
    application:get_env(rabbit, classic_queue_store_v2_check_crc32, true).

%% Same implementation as rabbit_classic_queue_index_v2:segment_file/2,
%% but with a different state record.
segment_file(Segment, #qs{ dir = Dir }) ->
    filename:join(Dir, integer_to_list(Segment) ++ ?SEGMENT_EXTENSION).
