/*

Copyright 2017-2020 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "backpressure"
use "buffered"
use "collections"
use "promises"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/core/checkpoint"
use "wallaroo/core/data_receiver"
use "wallaroo/core/invariant"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/partitioning"
use "wallaroo/core/recovery"
use "wallaroo/core/routing"
use "wallaroo/core/source"
use "wallaroo/core/topology"
use "wallaroo_labs/bytes"
use cwm = "wallaroo_labs/connector_wire_messages"
use "wallaroo_labs/logging"
use "wallaroo_labs/mort"
use "wallaroo_labs/time"


type _ProtoFsmState is (_ProtoFsmConnected | _ProtoFsmHandshake |
                        _ProtoFsmStreaming | _ProtoFsmError |
                        _ProtoFsmDisconnected | _ProtoFsmShrinking)
primitive _ProtoFsmConnected
  fun apply(): U8 => 1
primitive _ProtoFsmHandshake
  fun apply(): U8 => 2
primitive _ProtoFsmStreaming
  fun apply(): U8 => 3
primitive _ProtoFsmError
  fun apply(): U8 => 4
primitive _ProtoFsmDisconnected
  fun apply(): U8 => 5
primitive _ProtoFsmShrinking
  fun apply(): U8 => 6


class _StreamState
  """
  A mutable SteamState class for local state management
  For sendable versions going outside of the notifier,
  use streamstate(): StreamState
  """
  let id: StreamId
  let name: String
  var last_acked: PointOfReference // last message id that was checkpointed
  var last_seen: PointOfReference  // last seen message id
  var last_checkpoint: CheckpointId // last checkpoint id
  var close_on_or_after: CheckpointId = 0 // First checkpoint where stream can be closed

  new ref create(stream_id: StreamId, stream_name: String,
    last_seen': PointOfReference,
    last_acked': PointOfReference, last_checkpoint': CheckpointId)
=>
  id = stream_id
  name = stream_name
  last_seen = last_seen'
  last_acked = last_acked'
  last_checkpoint = last_checkpoint'

  fun serialize(wb: Writer = Writer): Writer =>
    @l(Log.debug(), Log.conn_source(),
      "_Stream_state: serialize: id %s name %s last_acked %lu last_seen %lu last_checkpoint %lu".cstring(), id.string().cstring(), name.cstring(), last_acked, last_seen, last_checkpoint)
    wb.u64_be(id)
    wb.u16_be(name.size().u16())
    wb.write(name)
    wb.u64_be(last_acked)
    wb.u64_be(last_seen)
    wb.u64_be(last_checkpoint)
    wb

  new ref deserialize(rb: Reader) ? =>
    id = rb.u64_be()?
    let name_size = rb.u16_be()?.usize()
    name = String.from_array(rb.block(name_size)?)
    last_acked = rb.u64_be()?
    last_seen = rb.u64_be()?
    last_checkpoint = rb.u64_be()?
    @l(Log.debug(), Log.conn_source(),
      "_Stream_state: deserialize: id %s name %s last_acked %lu last_seen %lu last_checkpoint %lu".cstring(), id.string().cstring(), name.cstring(), last_acked, last_seen, last_checkpoint)

class val NotifyResult[In: Any val]
  """
  The type to use with Promise objects used to manage responses for the async
  parts of the stream_notify sequence
  """
  let source: ConnectorSource[In] tag
  let success: Bool
  let stream: StreamTuple

  new val create(source': ConnectorSource[In] tag,
    success': Bool, stream': StreamTuple)
  =>
    source = source'
    success = success'
    stream = stream'

class NotifyResultFulfill[In: Any val] is
  Fulfill[NotifyResult[In], None]

  let stream_id: StreamId
  let session_id: RoutingId

  new create(stream_id': StreamId, session_id': RoutingId)
  =>
    stream_id = stream_id'
    session_id = session_id'

  fun apply(t: NotifyResult[In]) =>
    t.source.stream_notify_result(session_id, t.success, t.stream)

class val ConnectorSourceNotifyParameters[In: Any val]
  let pipeline_name: String
  let env: Env
  let auth: AmbientAuth
  let handler: FramedSourceHandler[In] val
  let router: Router
  let metrics_reporter: MetricsReporter val
  let cookie: String
  let max_credits: U32
  let refill_credits: U32
  let host: String
  let service: String

  new val create(pipeline_name': String, env': Env,
    auth': AmbientAuth, handler': FramedSourceHandler[In] val,
    router': Router, metrics_reporter': MetricsReporter val,
    cookie': String, max_credits': U32, refill_credits': U32, host': String,
    service': String)
  =>
    pipeline_name = pipeline_name'
    env = env'
    auth = auth'
    handler = handler'
    router = router'
    metrics_reporter = metrics_reporter'
    cookie = cookie'
    max_credits = max_credits'
    refill_credits = refill_credits'
    host = host'
    service = service'

class ConnectorSourceNotify[In: Any val]
  let source_id: RoutingId
  let _env: Env
  let _auth: AmbientAuth
  let _msg_id_gen: MsgIdGenerator = MsgIdGenerator
  var _header: Bool = true
  let _pipeline_name: String
  let _source_name: String
  let _handler: FramedSourceHandler[In] val
  let _runner: Runner
  var _router: Router
  let _metrics_reporter: MetricsReporter
  let _header_size: USize
  var _coordinator: ConnectorSourceCoordinator[In]
  let _conn_debug: U16 = Log.make_sev_cat(Log.debug(), Log.conn_source())
  let _conn_info: U16 = Log.make_sev_cat(Log.info(), Log.conn_source())
  let _conn_err: U16 = Log.make_sev_cat(Log.err(), Log.conn_source())

  // Barrier/checkpoint id tracking
  var _barrier_checkpoint_id: CheckpointId = 0

  // we need these for RestartMsg(host, port)
  var host: String
  var service: String

  // stream state management
  var _pending_notify: Set[StreamId] = _pending_notify.create()
  var _pending_notify_checkpoint_id: (None|CheckpointId) = None
  var _active_streams: Map[StreamId, _StreamState]= _active_streams.create()
  var _pending_close: Map[StreamId, _StreamState] = _pending_close.create()
  var _pending_relinquish: Array[StreamTuple] = _pending_relinquish.create()
  var _pending_acks: Array[(StreamId, PointOfReference)] =
    _pending_acks.create()

  var _session_active: Bool = false
  var _session_id: RoutingId = 0
  var _fsm_state: _ProtoFsmState = _ProtoFsmDisconnected
  let _cookie: String
  let _max_credits: U32
  let _refill_credits: U32
  var _credits: U32 = 0
  var _program_name: String = ""
  var _instance_name: String = ""
  var _rolling_back: Bool = false
  var _prep_for_rollback: Bool = false
  let _debug_disconnect: Bool = false

  // Watermark !TODO! How do we handle this respecting per-connector-type
  // policies
  var _watermark_ts: U64 = 0

  new iso create(source_id': RoutingId, runner: Runner iso,
    parameters: ConnectorSourceNotifyParameters[In],
    coordinator': ConnectorSourceCoordinator[In], is_recovering: Bool)
  =>
    source_id = source_id'
    _pipeline_name = parameters.pipeline_name
    _source_name = parameters.pipeline_name + " source"
    _env = parameters.env
    _auth = parameters.auth
    _handler = parameters.handler
    _runner = consume runner
    _router = parameters.router
    _metrics_reporter = recover iso parameters.metrics_reporter.clone() end
    _header_size = _handler.header_length()
    _cookie = parameters.cookie
    _max_credits = parameters.max_credits
    _refill_credits = parameters.refill_credits
    host = parameters.host
    service = parameters.service

    _coordinator = coordinator'

    ifdef "trace" then
      @ll(_conn_debug, "%s: max_credits = %lu, refill_credits = %lu\n".cstring(),
      __loc.type_name().cstring(), _max_credits, _refill_credits)
    end

    if is_recovering then
      _prep_for_rollback = true
    end

  fun ref received(source: ConnectorSource[In] ref, data: Array[U8] iso,
    consumer_sender: TestableConsumerSender): Bool
  =>
    // ignore messages if session isn't active
    // necessary for dealing with overflow data during restart
    if not _session_active then return true end

    if _header then
      try
        let payload_size: USize = _handler.payload_length(consume data)?
        _header = false
        source.expect(payload_size)
      else
        Fail()
      end
      true
    else
      ifdef "trace" then
        @ll(_conn_debug, ("Rcvd msg at " + _pipeline_name + " source\n").cstring())
      end
      _metrics_reporter.pipeline_ingest(_pipeline_name, _source_name)
      let ingest_ts = WallClock.nanoseconds()
      let pipeline_time_spent: U64 = 0
      let latest_metrics_id: U16 = 1

      received_connector_msg(source, consume data, latest_metrics_id,
        ingest_ts, pipeline_time_spent, consumer_sender)
    end

  /////////////////////////////
  // Connector Message Handling
  /////////////////////////////

  fun ref received_connector_msg(source: ConnectorSource[In] ref,
    data: Array[U8] iso,
    latest_metrics_id: U16,
    ingest_ts: U64,
    pipeline_time_spent: U64,
    consumer_sender: TestableConsumerSender): Bool
  =>
    if _prep_for_rollback then
      // Anything that the connector sends us is ignored while we wait
      // for the rollback to finish.  Tell the connector to restart later.
      return _continue_perhaps(source)
    end

    _credits = _credits - 1
    if (_credits <= _refill_credits) and
        (_fsm_state is _ProtoFsmStreaming) then
      // Our client's credits are running low and we haven't replenished
      // them after checkpoint_complete() processing.  Replenish now.
      _send_acks(source)
    end

    let data': Array[U8] val = consume data
    try
      ifdef "trace" then
        @ll(_conn_debug, "TRACE: decode data: %s\n".cstring(), _print_array[U8](
          data').cstring())
      end
      let connector_msg = cwm.Frame.decode(data')?
      match connector_msg
      | let m: cwm.HelloMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got HelloMsg\n".cstring())
        end
        if _fsm_state isnt _ProtoFsmConnected then
          @ll(_conn_err, "%s.received_connector_msg: state is %d\n"
            .cstring(), __loc.type_name().cstring(), _fsm_state())
          Fail()
        end

        if m.version != "0.0.1" then
          @ll(_conn_err, "%s.received_connector_msg: unknown protocol version %s\n".cstring(),
            __loc.type_name().cstring(), m.version.cstring())
          return _to_error_state(source, "Unknown protocol version: " + m.version)
        end
        if m.cookie != _cookie then
          @ll(_conn_err, "%s.received_connector_msg: bad cookie %s\n"
            .cstring(), __loc.type_name().cstring(), m.cookie.cstring())
          return _to_error_state(source, "Bad cookie: " + m.cookie + ", wanted: " + _cookie)
        end

        // TODO: add routing logic to handle
        // m.program_name and m.instance_name routing requirements
        // Right now, we assume that all messages are to be processed
        // by this connector's one & only pipeline as defined by the
        // app's pipeline definition.

        _credits = _max_credits
        _send_reply(source, cwm.OkMsg(_credits))
        _fsm_state = _ProtoFsmStreaming
        return _continue_perhaps(source)

      | let m: cwm.OkMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got OkMsg\n".cstring())
        end
        return _to_error_state(source, "Invalid message: ok")

      | let m: cwm.ErrorMsg =>
        @ll(_conn_info, "Received ERROR msg from client: %s\n".cstring(),
          m.message.cstring())
        source.close()
        return false

      | let m: cwm.NotifyMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got NotifyMsg: %lu %s %lu\n".cstring(),
            m.stream_id, m.stream_name.cstring(), m.point_of_ref)
        end
        if _fsm_state isnt _ProtoFsmStreaming then
          return _to_error_state(source, "Bad protocol FSM state")
        end

        if _rolling_back or
           _pending_notify.contains(m.stream_id) or
           _active_streams.contains(m.stream_id) or
           _pending_close.contains(m.stream_id)
        then
          // We are rolling back, or else this notifier is already
          // handling this stream.
          // So reject directly
          @ll(_conn_debug, "TODO: got NotifyMsg: _rolling_back %s\n".cstring(),
            _rolling_back.string().cstring())
          send_notify_ack(source, false, m.stream_id, m.point_of_ref)
        else
          _process_notify(where source=source, stream_id=m.stream_id,
            stream_name=m.stream_name, point_of_reference=m.point_of_ref)
        end

      | let m: cwm.NotifyAckMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got NotifyAckMsg\n".cstring())
        end
        return _to_error_state(source, "Invalid message: notify_ack")

      | let m: cwm.EosMessageMsg =>
        try
          let s = _active_streams(m.stream_id)?
          @ll(_conn_info, ("ConnectorSource[%s] received EOS for stream_id"
            + " %s. Last_acked: %s, last_seen :%s\n").cstring(),
            _source_name.string().cstring(),
            m.stream_id.string().cstring(),
            s.last_acked.string().cstring(),
            s.last_seen.string().cstring())

          // 1. remove state from _active_streams
          _active_streams.remove(m.stream_id)?
          @ll(_conn_info, "Successfully removed %s from _active\n"
            .cstring(), m.stream_id.string().cstring())
          // 2. add state to _pending_close
          ifdef "resilience" then
            // Set the first barrier we can close this stream on
            // to the current barrier id + 1
            // This prevents premature stream closure without checkpointing
            // and acking the last_seen value after an EOS
            s.close_on_or_after = _barrier_checkpoint_id + 1
            _pending_close.update(m.stream_id, s)
          else
            // respond immediately
            _send_reply(source, cwm.AckMsg(0, [(s.id, s.last_seen)]))
            _coordinator.streams_relinquish(source_id,
              [StreamTuple(s.id, s.name, s.last_seen)])
          end
          return _continue_perhaps(source)
        else
          @ll(_conn_info, ("Something went wrong trying to remove %s " +
            "from _active\n").cstring(),
            m.stream_id.string().cstring())
          error
        end

      | let m: cwm.MessageMsg =>
        // check that we're in state that allows processing messages
        if _fsm_state isnt _ProtoFsmStreaming then
          return _to_error_state(source, "Bad protocol FSM state")
        end

        if _rolling_back then
          // We are going to roll back sometime, so do not accept any
          // new incoming data.
          //
          // TODO: I think it's OK to ignore credit management.  If we
          // wait long enough for a real rollback + send RESTART, then
          // perhaps the client would run out of credits and stop
          // sending, which is just fine, then we don't have to throw
          // these messages away.
          @ll(_conn_debug, "TODO: _rolling_back, discarding msg".cstring())
          return _continue_perhaps(source)
        end

        // try to process message
        if not _active_streams.contains(m.stream_id) then
          return _to_error_state(source, "Bad/unregistered stream_id " +
            m.stream_id.string() + " with message_id " + m.message_id.string())
        else
          try
            let s = _active_streams(m.stream_id)?
            let msg_id = m.message_id

            if s.last_seen == StreamTupleNoneSeen() then
              // This is the first record that we've seen for this stream.
              // We don't care if it starts at zero; we only care that
              // all subsequent message IDs are strictly increasing from
              // now on.
              @ll(_conn_debug, "m.message_id %lu is the first record in this stream".cstring(), msg_id)
            elseif msg_id <= s.last_seen then
              // skip processing of an already seen message
              @ll(_conn_debug, "Skip m.message_id %lu <= last_seen %lu".cstring(), msg_id, s.last_seen)
              return _continue_perhaps(source)
            end

            try
              // get bytes content of message
              let bytes = match (m.message as cwm.MessageBytes)
              | let str: String      => str.array()
              | let b: Array[U8] val => b
              end

              // decode bytes using handler, if bytes not None
              let decoded = if bytes.size() == 0 then
                None
              else
                _handler.decode(bytes)?
              end

              ifdef "trace" then
                @ll(_conn_debug, ("Msg decoded at " + _pipeline_name +
                  " source\n").cstring())
              end

              // get message key
              let key =
                match m.key
                | let k: Key =>
                  k
                else
                  ""
                end

              // process message
              return _run_and_subsequent_activity(latest_metrics_id,
                ingest_ts, pipeline_time_spent, key, source, consumer_sender,
                decoded, s, m.message_id)
            else
              // _handler.decode(bytes) failed
              if m.message is None then
                // TODO [post-source-migration] revisit this error message
                return _to_error_state(source, "No message bytes and BOUNDARY not set")
              end
              @ll(_conn_err, ("Unable to decode message at " + _pipeline_name +
                " source\n").cstring())
              ifdef debug then
                Fail()
              end
              return _to_error_state(source, "Unable to decode message")
            end
          else
            return _to_error_state(source, "Unknown StreamId")
          end
        end

      | let m: cwm.AckMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got AckMsg\n".cstring())
        end
        return _to_error_state(source, "Invalid message: ack")

      | let m: cwm.RestartMsg =>
        ifdef "trace" then
          @ll(_conn_debug, "TRACE: got RestartMsg\n".cstring())
        end
        return _to_error_state(source, "Invalid message: restart")

      end
    else
      @ll(_conn_err, ("Unable to decode message at " + _pipeline_name +
        " source\n").cstring())
      ifdef debug then
        @ll(_conn_debug, "Message bytes: %s\n".cstring(),
          _print_array[U8](data').cstring())
        Fail()
      end
      return _to_error_state(source, "Unable to decode message")
    end
    _continue_perhaps(source)

  fun ref _run_and_subsequent_activity(latest_metrics_id: U16,
    ingest_ts: U64,
    pipeline_time_spent: U64,
    key: Key,
    source: ConnectorSource[In] ref,
    consumer_sender: TestableConsumerSender,
    decoded: (In val| None val),
    s: _StreamState,
    message_id: (cwm.MessageId|None)): Bool
   =>
    let decode_end_ts = WallClock.nanoseconds()
    _metrics_reporter.step_metric(_pipeline_name,
      "Decode Time in Connector Source", latest_metrics_id, ingest_ts,
      decode_end_ts)
    let latest_metrics_id' = latest_metrics_id + 1

    let msg_uid = _msg_id_gen()

    // TODO: We need a way to determine the key based on the policy
    // for any particular connector. For example, the Kafka connector
    // needs a way to provide the Kafka key here.

    let initial_key =
      if key isnt None then
        key
      else
        // TODO [post-source-migration] should this be stream_id for messages
        // that do not provide a key?
        // What is a sane default here?
        // What does it mean to use a unique key for each message?
        msg_uid.string()
      end

    // TODO [source-migration]: We need a way to assign watermarks based on
    // the policy for any particular connector.
    if ingest_ts > _watermark_ts then
      _watermark_ts = ingest_ts
    end

    (let is_finished, let last_ts) =
      match decoded
      | None =>
        (true, ingest_ts)
      | let d: In =>
        _runner.run[In](_pipeline_name, pipeline_time_spent, d,
          consume initial_key, ingest_ts, _watermark_ts, consumer_sender,
          _router, msg_uid, None, decode_end_ts, latest_metrics_id, ingest_ts)
      end

    match message_id
    | let m_id: PointOfReference =>
      s.last_seen = m_id
      @ll(_conn_debug, "DBG: update point_of_ref last_seen = %lu".cstring(), s.last_seen)
    end

    if is_finished then
      let end_ts = WallClock.nanoseconds()
      let time_spent = end_ts - ingest_ts

      ifdef "detailed-metrics" then
        _metrics_reporter.step_metric(_pipeline_name,
          "Before end at Connector Source", 9999,
          last_ts, end_ts)
      end

      _metrics_reporter.pipeline_metric(_pipeline_name, time_spent +
        pipeline_time_spent)
      _metrics_reporter.worker_metric(_pipeline_name, time_spent)
    end

    _continue_perhaps(source)

  fun ref _continue_perhaps(source: ConnectorSource[In] ref): Bool =>
    _header = true
    source.expect(_header_size)
    _continue_perhaps2()

  fun ref _continue_perhaps2(): Bool =>
    ifdef linux then
      true
    else
      false
    end

  ///////////////////
  // Wallaroo Routing
  ///////////////////
  fun routes(): Map[RoutingId, Consumer] val =>
    _router.routes()

  fun ref update_router(router': Router) =>
    _router = router'

  fun ref update_boundaries(obs: box->Map[String, OutgoingBoundary]) =>
    match _router
    | let p_router: StatePartitionRouter =>
      _router = p_router.update_boundaries(_auth, obs)
    else
      ifdef "trace" then
        @ll(_conn_debug, ("FramedSourceNotify doesn't have StatePartitionRouter." +
          " Updating boundaries is a noop for this kind of Source.\n")
          .cstring())
      end
    end

  //////////////////////////////
  // Connection State Management
  //////////////////////////////
  fun ref accepted(source: ConnectorSource[In] ref, session_id: RoutingId) =>
    @ll(_conn_info, (_source_name + ": accepted a connection 0x%lx\n").cstring(),
      source)
    if _fsm_state isnt _ProtoFsmDisconnected then
      @ll(_conn_err, "%s.connected: state is %d\n".cstring(),
        __loc.type_name().cstring(), _fsm_state())
      Fail()
    end
    // reset/clear local state
    _fsm_state = _ProtoFsmConnected
    _header = true
    _session_active = true
    _session_id = session_id
    _clear_and_relinquish_all()
    _credits = _max_credits
    _prep_for_rollback = false
    source.expect(_header_size)

  fun ref closed(source: ConnectorSource[In] ref) =>
    @ll(_conn_info, "ConnectorSource connection closed 0x%lx\n".cstring(), source)
    _session_active = false
    _fsm_state = _ProtoFsmDisconnected
    // TODO [post-source-migration] When the SourceCoordinator actors are added
    // to participate in rollback, the following assumptions become true:
    //   1. we relinquish streams with last_seen value
    //   2. on rollback, global registry rolls back too.
    // Streams become "owned" again at the source, and will get relinquished to
    // the last_acked at the time of checkpoint.
    // So a notify_ack after a rollback will have the correct last_acked
    // and a notify_ack after an in-between-checkpoints-closed will have the
    // correct last_seen as its last_acked.
    //
    // So the assumption here is the "last_seen" vs. "last_acked" discrepancy
    // is corrected either:
    //  1. at the next checkpoint, when last_seen becomes last_acked in the
    //    checkpointed state
    //  2. during a rollback, when the state rolls back to actual last_acked
    //     and so will the registry
    // https://github.com/WallarooLabs/wallaroo/issues/2807
    _clear_and_relinquish_all()

  fun ref throttled(source: ConnectorSource[In] ref) =>
    @ll(_conn_info, "%s.throttled: %s Experiencing backpressure!\n".cstring(),
      __loc.type_name().cstring(), _pipeline_name.cstring())
    Backpressure.apply(_auth) // TODO: appropriate?

  fun ref unthrottled(source: ConnectorSource[In] ref) =>
    @ll(_conn_info, "%s.unthrottled: %s Releasing backpressure!\n".cstring(),
      __loc.type_name().cstring(), _pipeline_name.cstring())
    Backpressure.release(_auth) // TODO: appropriate?

  fun ref connecting(conn: ConnectorSource[In] ref, count: U32) =>
    """
    Called if name resolution succeeded for a ConnectorSource and we are now
    waiting for a connection to the server to succeed. The count is the number
    of connections we're trying. The notifier will be informed each time the
    count changes, until a connection is made or connect_failed() is called.
    """
    Fail()

  fun ref connected(conn: ConnectorSource[In] ref) =>
    """
    Called when we have successfully connected to the server.
    """
    Fail()

  fun ref connect_failed(conn: ConnectorSource[In] ref) =>
    """
    Called when we have failed to connect to all possible addresses for the
    server. At this point, the connection will never be established.
    """
    Fail()

  fun ref expect(conn: ConnectorSource[In] ref, qty: USize): USize =>
    """
    Called when the connection has been told to expect a certain quantity of
    bytes. This allows nested notifiers to change the expected quantity, which
    allows a lower level protocol to handle any framing (e.g. SSL).
    """
    qty

  fun ref shrink(source: ConnectorSource[In] ref) =>
    _fsm_state = _ProtoFsmShrinking
    _process_acks_for_active(source)
    _process_acks_for_pending_close(source)
    _clear_and_relinquish_all()

  ///////////////////////////////////
  // Checkpoint / Rollback // Barrier
  ///////////////////////////////////

  fun ref trigger_checkpoint_state(source: ConnectorSource[In] ref,
    checkpoint_id: CheckpointId)
  =>
    if _pending_notify.size() == 0 then
      source.log_checkpoint_state(checkpoint_id, create_checkpoint_state())
    else
      @ll(_conn_debug, "0x%lx defer checkpoint state for CheckpointId %lu".cstring(), source, checkpoint_id)
      _pending_notify_checkpoint_id = checkpoint_id
    end

  fun create_checkpoint_state(): Array[ByteSeq val] val =>
    let w: Writer = w.create()

    // We don't want to send an empty checkpoint state to EventLog,
    // because EventLog won't write it.  If EventLog doesn't write
    // it, then we'll never read it, so we'll never have rollback()
    // called, and that makes us sad.
    w.u8(nonempty_magic())

    for s_map in [_active_streams ; _pending_close].values() do
      @l(Log.debug(), Log.conn_source(), "map size = %lu".cstring(), s_map.size())
      for stream_state in s_map.values() do
        stream_state.serialize(w)
      end
    end
    @l(Log.debug(), Log.conn_source(), "_pending_relinquish size = %lu".cstring(), _pending_relinquish.size())
    for pr in _pending_relinquish.values() do
      let stream_state = _StreamState(pr.id, pr.name, pr.last_acked, pr.last_acked, 0)
      stream_state.serialize(w)
    end
    w.done()

  fun ref prepare_for_rollback(source: ConnectorSource[In] ref) =>
    _rolling_back = true
    if _session_active then
      _prep_for_rollback = true
      source.close()
      ifdef "trace" then
        @ll(_conn_debug, "TRACE: %s.%s\n".cstring(), __loc.type_name().cstring(),
          __loc.method_name().cstring())
      end
    end

  fun ref rollback(source: ConnectorSource[In] ref,
    checkpoint_id: CheckpointId, payload: ByteSeq val)
  =>
    @ll(_conn_info, "ConnectorSource[%s] is rolling back to checkpoint_id %s\n"
      .cstring(), _source_name.cstring(), checkpoint_id.string().cstring())
    _barrier_checkpoint_id = checkpoint_id

    if payload.size() < 1 then
      Fail()
    end
    // After a rollback, all streams go directly to relinquish
    // So we don't distinguish where they came from.
    let rb: Reader ref = Reader
    rb.append(payload)
    try
      if rb.u8()? != nonempty_magic() then
        Fail()
      end
      while true do
        let s = _StreamState.deserialize(rb)?
        @ll(_conn_info, "ConnectorSource[%s]: rollback: payload relinquish name %s id %s last_acked %lu\n"
          .cstring(), _source_name.cstring(), s.name.cstring(), s.id.string().cstring(), s.last_acked)
        _pending_relinquish.push(StreamTuple(s.id, s.name, s.last_acked))
        // TODO: should we remove s.id from all my other lists, _active_streams, etc??
      end
    end
    _rolling_back = false
    _relinquish_streams()
    rollback_complete(source, checkpoint_id)

  fun ref rollback_complete(source: ConnectorSource[In] ref,
    checkpoint_id: CheckpointId)
  =>
    _prep_for_rollback = false
    send_restart(source)
    _clear_and_relinquish_all()
    source.close()

  fun ref initiate_checkpoint(checkpoint_id: CheckpointId) =>
    if not _prep_for_rollback then
      ifdef debug then
        Invariant(checkpoint_id > _barrier_checkpoint_id)
      end
      _barrier_checkpoint_id = checkpoint_id

      if _session_active then
        // update last_acked and last_checkpoint for all streams in
        // _active_streams and _pending_close
        for s_map in [_active_streams ; _pending_close].values() do
          for s in s_map.values() do
            ifdef debug then
              @ll(_conn_debug, "%s ::: Updating stream_id %s last_acked to %s\n"
                .cstring(), WallClock.seconds().string().cstring(),
                s.id.string().cstring(), s.last_seen.string().cstring())
            end
            s.last_checkpoint = checkpoint_id
            s.last_acked = s.last_seen
          end
        end
      end
    end

  fun ref checkpoint_complete(source: ConnectorSource[In] ref,
    checkpoint_id: CheckpointId)
  =>
    @ll(_conn_debug, ("ConnectorSourceNotify: Checkpoint complete for id " +
      " %s _prep_for_rollback %s _session_active %s\n").cstring(),
      checkpoint_id.string().cstring(),
      _prep_for_rollback.string().cstring(), _session_active.string().cstring())
    if not _prep_for_rollback then
      ifdef debug then
        if (_barrier_checkpoint_id > 0) and (checkpoint_id != _barrier_checkpoint_id) then
          // TODO In the future, we should not be sending checkpoint
          // complete messages to new autoscale participants until they
          // have participated in at least one complete checkpoint.
          //
          // If _barrier_checkpoint_id is 0, then perhaps we have very
          // recently joined the cluster and have been told
          // checkpoint_complete without having participated in the
          // checkpoint at all.
          @ll(_conn_debug, ("ConnectorSourceNotify: Checkpoint complete for id " +
            " %s but expected %s\n").cstring(),
            checkpoint_id.string().cstring(),
            _barrier_checkpoint_id.string().cstring())
          Fail()
        end
      end

      if _session_active then
        _process_acks_for_active(source)

        // process acks for EOS/_pending_close streams
        _process_acks_for_pending_close(source)
        // process any stream relinquish requests
        _relinquish_streams()
      end
    end

  /////////////////////////
  // Local state management
  /////////////////////////
  fun ref _process_acks_for_active(source: ConnectorSource[In] ref) =>
    for (stream_id, s) in _active_streams.pairs() do
      _pending_acks.push((stream_id, s.last_acked))
    end
    if (_fsm_state is _ProtoFsmStreaming) or
       (_fsm_state is _ProtoFsmShrinking) then
      _send_acks(source)
    end

  fun ref _process_acks_for_pending_close(source: ConnectorSource[In] ref) =>
    for (stream_id, s) in _pending_close.pairs() do
      ifdef debug then
        @ll(_conn_debug, "%s ::: Processing ack for %s at %s\n".cstring(),
          WallClock.seconds().string().cstring(),
          stream_id.string().cstring(), s.last_acked.string().cstring())
      end
      if s.close_on_or_after <= _barrier_checkpoint_id then
        try _pending_close.remove(stream_id)? end
        _pending_acks.push((stream_id, s.last_acked))
        _pending_relinquish.push(StreamTuple(s.id, s.name, s.last_acked))
      else
        ifdef debug then
          @ll(_conn_debug, "Stream_id %s is not ready to close.\n".cstring(),
            stream_id.string().cstring())
        end
      end
    end
    if (_fsm_state is _ProtoFsmStreaming) or
       (_fsm_state is _ProtoFsmShrinking) then
      _send_acks(source)
    end

  fun ref _relinquish_streams() =>
    let streams = recover iso Array[StreamTuple] end
    for s in _pending_relinquish.values() do
      streams.push(s)
    end
    _pending_relinquish.clear()

    if streams.size() > 0 then
      @ll(_conn_info, "ConnectorSource relinquishing %s streams\n".cstring(),
        streams.size().string().cstring())
      _coordinator.streams_relinquish(source_id, consume streams)
    else
      if _fsm_state is _ProtoFsmShrinking then
        @ll(_conn_info, "ConnectorSource shrinking %s streams\n".cstring(),
          streams.size().string().cstring())
        _coordinator.streams_relinquish(source_id, consume streams)
      end
    end

  fun ref _clear_streams() =>
    _pending_notify.clear()
    _pending_notify_checkpoint_id = None
    _active_streams.clear()
    _pending_close.clear()
    _pending_relinquish.clear()

  fun ref _clear_and_relinquish_all() =>
    for s_map in [_active_streams ; _pending_close].values() do
      @ll(_conn_debug, "s_map.size = %lu".cstring(), s_map.size())
      for s in s_map.values() do
        _pending_relinquish.push(StreamTuple(s.id, s.name, s.last_acked))
      end
    end
    _relinquish_streams()
    _clear_streams()

  /////////
  // Notify
  /////////

  fun ref _process_notify(source: ConnectorSource[In] ref, stream_id: StreamId,
    stream_name: String, point_of_reference: PointOfReference)
  =>
    // add to _pending_notify
    _pending_notify.set(stream_id)

    // create a promise for handling result
    let promise = Promise[NotifyResult[In]]
    promise.next[None](recover NotifyResultFulfill[In](stream_id, _session_id)
      end)

    // send request to take ownership of this stream id
    let request_id = ConnectorStreamNotifyId(stream_id, _session_id)
    _coordinator.stream_notify(request_id, stream_id, stream_name,
      point_of_reference, promise, source)

  fun ref stream_notify_result(source: ConnectorSource[In] ref,
    session_id: RoutingId, success: Bool, stream: StreamTuple)
  =>
    ifdef "trace" then
      @ll(_conn_debug, "%s ::: stream_notify_result(%s, %s, StreamTuple(%s, %s, %s))\n".cstring(),
        WallClock.seconds().string().cstring(),
        session_id.string().cstring(),
        success.string().cstring(),
        stream.id.string().cstring(),
        stream.name.cstring(),
        stream.last_acked.string().cstring())
    end

    // remove entry from _pending_notify set
    _pending_notify.unset(stream.id)

    if (session_id != _session_id) or (not _session_active) then
      // This is a reply from a query that we'd sent in a prior TCP
      // connection, or else the TCP connection is closed now.

      @ll(_conn_debug, "Notify request session_id is old. Rejecting result\n"
          .cstring())
      if success then
        // Stream.id's state in the registry is now active, but it was
        // became active during session_id.

        // a. If we're now in a new session, so we know that all clients
        // from the old session_id are no longer connected.
        // b. If we're disconnected, then we are definitely not connected.  
        //
        // In either case, we can relinquish this ID safely, and we
        // must relinquish it because, right now, this ID is "leaked"
        // and unusable by anybody.  We must use the _pending_relinquish
        // mechanism, because we must maintain checkpoint-safe state
        // invariants.
        _pending_relinquish.push(stream)
      end
    else
      if success then
        // create _StreamState to place in _active_streams
        let s = _StreamState(stream.id, stream.name, stream.last_acked,
          stream.last_acked, _barrier_checkpoint_id)
        _active_streams(stream.id) = s
      end
      // send response either way
      send_notify_ack(source, success, stream.id, stream.last_acked)
      for s_map in [_active_streams ; _pending_close].values() do
        @ll(_conn_debug, "after send_notify_ack: s_map.size = %lu".cstring(), s_map.size())
      end
    end

    if _pending_notify.size() == 0 then
      match _pending_notify_checkpoint_id
      | let checkpoint_id: CheckpointId =>
        @ll(_conn_debug, "0x%lx now write our deferred checkpoint state for CheckpointId %lu".cstring(), source, checkpoint_id)
        source.log_checkpoint_state(checkpoint_id, create_checkpoint_state())
        _pending_notify_checkpoint_id = None
      end
    end

  fun ref send_notify_ack(source: ConnectorSource[In] ref, success: Bool,
    stream_id: StreamId, point_of_reference: PointOfReference)
  =>
    ifdef debug then
      @ll(_conn_debug, "%s ::: send_notify_ack(%s, %s, %s)\n".cstring(),
        WallClock.seconds().string().cstring(), success.string().cstring(),
        stream_id.string().cstring(), point_of_reference.string().cstring())
    end
    let m = cwm.NotifyAckMsg(success, stream_id, point_of_reference)
    _send_reply(source, m)

  //////////////////
  // Sending Replies
  //////////////////
  fun ref _to_error_state(source: ConnectorSource[In] ref, msg: String): Bool
  =>
    @ll(_conn_info, "_to_error_state: %s".cstring(), msg.cstring())
    _send_reply(source, cwm.ErrorMsg(msg))

    _fsm_state = _ProtoFsmError
    source.close()
    false

  fun ref _send_acks(source: ConnectorSource[In] ref) =>
    let new_credits = _max_credits - _credits
    let acks = recover iso Array[(StreamId, PointOfReference)] end
    for v in _pending_acks.values() do
      ifdef "trace" then
        @ll(_conn_debug, "%s ::: Acking stream_id %s to por %s\n".cstring(),
          WallClock.seconds().string().cstring(),
          v._1.string().cstring(),
          v._2.string().cstring())
      end
      acks.push(v)
    end
    _pending_acks.clear()
    // only send acks if there are new credits or new acks to send
    if (new_credits > 0) or (acks.size() > 0) then
      // !TODO!: Is this too noisy?
      @ll(_conn_info, "Sending acks for %s streams\n".cstring(),
        _pending_acks.size().string().cstring())
      _send_reply(source, cwm.AckMsg(new_credits, consume acks))
    end
    _credits = _credits + new_credits

  fun ref send_restart(source: ConnectorSource[In] ref) =>
    if _session_active then
      @ll(_conn_info, "Sending RESTART(%s:%s)\n".cstring(),
        host.cstring(), service.cstring())
      _send_reply(source, cwm.RestartMsg(host + ":" + service))
    end

  fun _send_reply(source: ConnectorSource[In] ref, msg: cwm.Message) =>
    let w1: Writer = w1.create()
    let b1 = cwm.Frame.encode(msg, w1)
    source.writev_final(Bytes.length_encode(b1))

  fun nonempty_magic(): U8 =>
    """An arbitrary constant."""
    84

  fun _print_array[A: U8](array: Array[A] val): String =>
    """
    Generate a printable string of the contents of the given readseq to use in
    error messages.
    """
    ifdef "verbose_debug" then
      if (array.size() == 97) or (array.size() == 98) then
        let hack = recover trn Array[U8] end
        let skip = array.size() - match array.size()
          | 97 =>
            49
          | 98 => 50
          else
            49
          end
        var count: USize = 0
        for b in array.values() do
          if count >= skip then
            hack.push(b)
          end
          count = count + 1
        end
        let hack2 = consume hack
        String.from_array(consume hack2)
      else
        "[len=" + array.size().string() + ": " + ",".join(array.values()) + "]"
      end
    else
      "[len=" + array.size().string() + ": " + "...]"
    end
