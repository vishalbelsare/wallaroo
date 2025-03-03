/*

Copyright 2017 The Wallaroo Authors.

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

use "assert"
use "buffered"
use "collections"
use "net"
use "promises"
use "serialise"
use "time"
use "wallaroo_labs/guid"
use "wallaroo_labs/time"
use "wallaroo/core/barrier"
use "wallaroo/core/boundary"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/invariant"
use "wallaroo/core/metrics"
use "wallaroo/core/network"
use "wallaroo/core/rebalancing"
use "wallaroo/core/recovery"
use "wallaroo/core/routing"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/state"
use "wallaroo/core/topology"
use "wallaroo/core/windows"
use "wallaroo_labs/collection_helpers"
use "wallaroo_labs/logging"
use "wallaroo_labs/mort"

use @l[I32](severity: LogSeverity, category: LogCategory, fmt: Pointer[U8] tag, ...)

actor Step is (Producer & Consumer & BarrierProcessor)
  let _auth: AmbientAuth
  let _worker_name: WorkerName
  var _id: U128
  let _runner: Runner
  var _router: Router = EmptyRouter
  let _metrics_reporter: MetricsReporter
  let _event_log: EventLog
  var _seq_id_generator: StepSeqIdGenerator = StepSeqIdGenerator

  var _phase: StepPhase = _InitialStepPhase

  var _consumer_sender: TestableConsumerSender

  // _routes contains one route per Consumer
  let _routes: SetIs[Consumer] = _routes.create()
  // _outputs keeps track of all output targets by step id. There might be
  // duplicate consumers in this map (unlike _routes) since there might be
  // multiple target step ids over a boundary
  let _outputs: Map[RoutingId, Consumer] = _outputs.create()
  // _routes contains one upstream per producer
  var _upstreams: SetIs[Producer] = _upstreams.create()
  // _inputs keeps track of all inputs by step id. There might be
  // duplicate producers in this map (unlike upstreams) since there might be
  // multiple upstream step ids over a boundary
  let _inputs: Map[RoutingId, Producer] = _inputs.create()

  // Lifecycle
  var _initializer: (LocalTopologyInitializer | None) = None
  var _initialized: Bool = false
  var _seq_id_initialized_on_recovery: Bool = false
  let _recovery_replayer: RecoveryReconnecter

  let _outgoing_boundaries: Map[String, OutgoingBoundary] =
    _outgoing_boundaries.create()

  // Watermarks
  var _watermarks: StageWatermarks = _watermarks.create()

  let _timers: Timers = Timers

  new create(auth: AmbientAuth, worker_name: WorkerName, runner: Runner iso,
    metrics_reporter: MetricsReporter iso,
    id: U128, event_log: EventLog,
    recovery_replayer: RecoveryReconnecter,
    outgoing_boundaries: Map[String, OutgoingBoundary] val,
    router': Router = EmptyRouter, is_recovering: Bool = false)
  =>
    _auth = auth
    _worker_name = worker_name
    _runner = consume runner
    _metrics_reporter = consume metrics_reporter
    _event_log = event_log
    _recovery_replayer = recovery_replayer
    _id = id
    // We must set this up first so we can pass a ref to ConsumerSender
    _consumer_sender = FailingConsumerSender(_id)
    _consumer_sender = ConsumerSender(_id, this, _metrics_reporter.clone())

    match _runner
    | let r: RollbackableRunner => r.set_step_id(id)
    end
    _recovery_replayer.register_step(this)
    for (worker, boundary) in outgoing_boundaries.pairs() do
      _outgoing_boundaries(worker) = boundary
    end
    _event_log.register_resilient(id, this)

    _update_router(router')

    for (c_id, consumer) in _router.routes().pairs() do
      _register_output(c_id, consumer)
    end

    _phase =
      if is_recovering then
        _RecoveringStepPhase(this)
      else
        _NormalStepPhase(this)
      end

    match _runner
    | let tr: TimeoutTriggeringRunner =>
      tr.set_triggers(StepTimeoutTrigger(this), _watermarks)
    end

    ifdef "identify_routing_ids" then
      @l(Log.info(), Log.step(), "===Step %s created===".cstring(),
        _id.string().cstring())

      let timer = Timer(_StepWaitingReportTimer(this), 500_000_000, 500_000_000)
      _timers(consume timer)
    end

  be step_waiting_report() =>
    ifdef "checkpoint_trace" then
      @l(Log.debug(), Log.step(), "step_waiting_report: id %s: %s".cstring(), _id.string().cstring(), _phase.step_waiting_report(_inputs).cstring())
    end

  //
  // Application startup lifecycle event
  //
  be application_begin_reporting(initializer: LocalTopologyInitializer) =>
    initializer.report_created(this)

  be application_created(initializer: LocalTopologyInitializer) =>
    _initialized = true
    initializer.report_initialized(this)

  be application_initialized(initializer: LocalTopologyInitializer) =>
    _prepare_ready_to_work(initializer)

  be quick_initialize(initializer: LocalTopologyInitializer) =>
    _prepare_ready_to_work(initializer)

  fun ref _prepare_ready_to_work(initializer: LocalTopologyInitializer) =>
    _initializer = initializer
    _report_ready_to_work()

  fun ref _report_ready_to_work() =>
    match _initializer
    | let rrtw: LocalTopologyInitializer =>
      rrtw.report_ready_to_work(this)
    else
      Fail()
    end

  be application_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  be cluster_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  fun routing_id(): RoutingId =>
    _id

  be update_router(router': Router) =>
    _update_router(router')

  fun ref _update_router(router': Router) =>
    let old_router = _router
    _router = router'
    for (old_id, outdated_consumer) in
      old_router.routes_not_in(_router).pairs()
    do
      if _outputs.contains(old_id) then
        _unregister_output(old_id, outdated_consumer)
      end
    end
    for (c_id, consumer) in _router.routes().pairs() do
      _register_output(c_id, consumer)
    end

    _phase.check_completion(inputs())

  fun ref _register_output(id: RoutingId, c: Consumer) =>
    if _outputs.contains(id) then
      try
        let old_c = _outputs(id)?
        if old_c is c then
          // We already know about this output.
          return
        end
        _unregister_output(id, old_c)
      else
        Unreachable()
      end
    end

    _outputs(id) = c
    _routes.set(c)
    _consumer_sender.register_producer(id, c)

  fun ref _unregister_output(id: RoutingId, c: Consumer) =>
    try
      _consumer_sender.unregister_producer(id, c)
      _outputs.remove(id)?
      _remove_route_if_no_output(c)
    else
      Fail()
    end

  fun ref _unregister_all_outputs() =>
    """
    This method should only be called if we are removing this step from the
    active graph (or on dispose())
    """
    let outputs_to_remove = Map[RoutingId, Consumer]
    for (id, consumer) in _outputs.pairs() do
      outputs_to_remove(id) = consumer
    end
    for (id, consumer) in outputs_to_remove.pairs() do
      _unregister_output(id, consumer)
    end

  be register_downstream() =>
    _reregister_as_producer()

  fun ref _reregister_as_producer() =>
    for (id, c) in _outputs.pairs() do
      match c
      | let ob: OutgoingBoundary =>
        ob.forward_register_producer(_id, id, this)
      else
        c.register_producer(_id, this)
      end
    end

  be remove_route_to_consumer(id: RoutingId, c: Consumer) =>
    if _outputs.contains(id) then
      ifdef debug then
        Invariant(_routes.contains(c))
      end
      _unregister_output(id, c)
    end

  fun ref _remove_route_if_no_output(c: Consumer) =>
    var have_output = false
    for consumer in _outputs.values() do
      if consumer is c then have_output = true end
    end
    if not have_output then
      _remove_route(c)
    end

  fun ref _remove_route(c: Consumer) =>
    _routes.unset(c)

  be add_boundaries(boundaries: Map[String, OutgoingBoundary] val) =>
    _add_boundaries(boundaries)

  fun ref _add_boundaries(boundaries: Map[String, OutgoingBoundary] val) =>
    for (worker, boundary) in boundaries.pairs() do
      if not _outgoing_boundaries.contains(worker) then
        _outgoing_boundaries(worker) = boundary
        _routes.set(boundary)
      end
    end

  be remove_boundary(worker: String) =>
    _remove_boundary(worker)

  fun ref _remove_boundary(worker: String) =>
    None

  be run[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    key: Key, event_ts: U64, watermark_ts: U64, i_producer_id: RoutingId,
    i_producer: Producer, msg_uid: MsgId, frac_ids: FractionalMessageId,
    i_seq_id: SeqId, latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    ifdef "trace" then
      @l(Log.debug(), Log.step(), "Received msg at Step".cstring())
    end
    _phase.run[D](metric_name, pipeline_time_spent, data, key,
      event_ts, watermark_ts, i_producer_id, i_producer, msg_uid, frac_ids,
      i_seq_id, latest_ts, metrics_id, worker_ingress_ts)

  fun ref process_message[D: Any val](metric_name: String,
    pipeline_time_spent: U64, data: D, key: Key, event_ts: U64,
    watermark_ts: U64, i_producer_id: RoutingId, i_producer: Producer,
    msg_uid: MsgId, frac_ids: FractionalMessageId, i_seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    _seq_id_generator.new_id()
    let process_ts = WallClock.nanoseconds()

    let input_watermark_ts =
      _watermarks.receive_watermark(i_producer_id, watermark_ts, process_ts)

    let my_latest_ts = ifdef "detailed-metrics" then
        process_ts
      else
        latest_ts
      end

    let my_metrics_id = ifdef "detailed-metrics" then
        _metrics_reporter.step_metric(metric_name,
          "Before receive at step behavior", metrics_id, latest_ts,
          my_latest_ts)
        metrics_id + 1
      else
        metrics_id
      end

    ifdef "trace" then
      @l(Log.debug(), Log.step(), ("Rcvd msg at " + _runner.name() + " step\n").cstring())
    end

    (let is_finished, let last_ts) = _runner.run[D](metric_name,
      pipeline_time_spent, data, key, event_ts, input_watermark_ts,
      _consumer_sender, _router, msg_uid, frac_ids, my_latest_ts,
      my_metrics_id, worker_ingress_ts)

    if is_finished then
      ifdef "trace" then
        @l(Log.debug(), Log.step(), "Filtering".cstring())
      end

      let end_ts = WallClock.nanoseconds()
      let time_spent = end_ts - worker_ingress_ts

      ifdef "detailed-metrics" then
        _metrics_reporter.step_metric(metric_name, "Before end at Step", 9999,
          last_ts, end_ts)
      end

      _metrics_reporter.pipeline_metric(metric_name,
        time_spent + pipeline_time_spent)
      _metrics_reporter.worker_metric(metric_name, time_spent)
    end

  fun inputs(): Map[RoutingId, Producer] box =>
    _inputs

  fun outputs(): Map[RoutingId, Consumer] box =>
    _outputs

  fun ref next_sequence_id(): SeqId =>
    _seq_id_generator.new_id()

  fun ref current_sequence_id(): SeqId =>
    _seq_id_generator.current_seq_id()

  fun has_route_to(c: Consumer): Bool =>
    _routes.contains(c)

  be register_producer(id: RoutingId, producer: Producer) =>
    _inputs(id) = producer
    _upstreams.set(producer)

  be unregister_producer(id: RoutingId, producer: Producer) =>
    if _inputs.contains(id) then
      try
        _inputs.remove(id)?
      else Fail() end
      _phase.remove_input(id)

      var have_input = false
      for i in _inputs.values() do
        if i is producer then have_input = true end
      end
      if not have_input then
        _upstreams.unset(producer)
      end
    end

  be report_status(code: ReportStatusCode) =>
    match code
    | BoundaryCountStatus =>
      var b_count: USize = 0
      for c in _routes.values() do
        match c
        | let ob: OutgoingBoundary => b_count = b_count + 1
        end
      end
      @l(Log.info(), Log.step(), "Step %s has %s boundaries.".cstring(), _id.string().cstring(), b_count.string().cstring())
    end

  be mute(c: Consumer) =>
    for u in _upstreams.values() do
      u.mute(c)
    end

  be unmute(c: Consumer) =>
    for u in _upstreams.values() do
      u.unmute(c)
    end

  be dispose_with_promise(promise: Promise[None]) =>
    _phase.dispose(this)
    promise(None)

  be dispose() =>
    _phase.dispose(this)

  fun ref finish_disposing() =>
    @l(Log.info(), Log.step(), "Disposing Step %s".cstring(), _id.string().cstring())
    _event_log.unregister_resilient(_id, this)
    _unregister_all_outputs()
    _timers.dispose()
    _phase = _DisposedStepPhase

  ///////////////
  // GROW-TO-FIT
  be receive_key_state(step_group: RoutingId, key: Key,
    state_bytes: ByteSeq val)
  =>
    ifdef "autoscale" then
      StepStateMigrator.receive_state(this, _runner, step_group, key,
        state_bytes)
      @l(Log.info(), Log.step(), "Received state for step %s".cstring(),
        _id.string().cstring())
    end

  be send_state(boundary: OutgoingBoundary, step_group: RoutingId, key: Key,
    checkpoint_id: CheckpointId)
  =>
    ifdef "autoscale" then
      _phase.send_state(this, _runner, _id, boundary, step_group,
        key, checkpoint_id, _auth)
    end

  //////////////
  // BARRIER
  //////////////
  be receive_barrier(step_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    ifdef "checkpoint_trace" then
      @l(Log.debug(), Log.step(), "Step %s received barrier %s from %s".cstring(),
        _id.string().cstring(), barrier_token.string().cstring(),
        step_id.string().cstring())
    end
    process_barrier(step_id, producer, barrier_token)

  fun ref process_barrier(step_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    if _inputs.contains(step_id) then
      ifdef "checkpoint_trace" then
        @l(Log.debug(), Log.step(), "Process Barrier %s at Step %s from %s".cstring(),
          barrier_token.string().cstring(), _id.string().cstring(),
          step_id.string().cstring())
      end
      // TODO: We can find a way to handle this behavior by
      // the StepPhase itself.
      match barrier_token
      | let srt: CheckpointRollbackBarrierToken =>
        _phase.prepare_for_rollback(srt)
      | let abt: AutoscaleBarrierToken =>
        if ArrayHelpers[WorkerName].contains[WorkerName](abt.leaving_workers(),
          _worker_name)
        then
          // We're leaving, so we need to flush any remaining worker local
          // state (which won't be migrated).
          _runner.flush_local_state(_consumer_sender, _router, _watermarks)
        end
      end

      _phase.receive_barrier(step_id, producer,
          barrier_token)
    else
      @l(Log.info(), Log.step(), ("Received barrier from unregistered input %s at step " +
        "%s. \n").cstring(), step_id.string().cstring(),
        _id.string().cstring())
    end

  fun ref receive_new_barrier(input_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    ifdef "checkpoint_trace" then
      @l(Log.debug(), Log.step(), "Receive New Barrier %s at Step %s from %s".cstring(),
        barrier_token.string().cstring(), _id.string().cstring(),
        input_id.string().cstring())
    end
    _phase = _BarrierStepPhase(this, _id, barrier_token)
    _phase.receive_barrier(input_id, producer, barrier_token)

  fun ref barrier_complete(barrier_token: BarrierToken) =>
    ifdef "checkpoint_trace" then
      @l(Log.debug(), Log.step(), "Barrier %s complete at Step %s".cstring(),
        barrier_token.string().cstring(), _id.string().cstring())
    end
    match barrier_token
    | let cbt: CheckpointBarrierToken =>
      checkpoint_state(cbt.id)
    end

    var queued = Array[_Queued]
    match barrier_token
    | let crbt: CheckpointRollbackBarrierToken =>
      _phase = _RecoveringStepPhase(this, crbt)
    else
      queued = _phase.queued()
      _phase = _NormalStepPhase(this)
    end
    for q in queued.values() do
      match q
      | let qm: QueuedMessage =>
        qm.process_message(this)
      | let qb: QueuedBarrier =>
        qb.inject_barrier(this)
      end
    end

  //////////////
  // CHECKPOINTS
  //////////////
  fun ref checkpoint_state(checkpoint_id: CheckpointId) =>
    ifdef "resilience" then
      StepStateCheckpointer(_runner, _id, checkpoint_id, _event_log,
        _watermarks, _auth)
    end

  be prepare_for_rollback() =>
    finish_preparing_for_rollback(None, _phase)

  fun ref finish_preparing_for_rollback(token: (BarrierToken | None),
    new_phase: StepPhase)
  =>
    @l(Log.debug(), Log.step(), "StepPhase Id %s change line %lu current _phase type %s new_phase type %s".cstring(), _id.string().cstring(), __loc.line(), _phase.name().cstring(), new_phase.name().cstring())
    _phase = new_phase

  be rollback(payload: ByteSeq val, event_log: EventLog,
    checkpoint_id: CheckpointId)
  =>
    _phase.rollback(_id, this, payload, event_log, _runner)

  fun ref finish_rolling_back() =>
    _phase = _NormalStepPhase(this)

  fun ref rollback_watermarks(bs: ByteSeq val) =>
    try
      _watermarks = StageWatermarksDeserializer(bs as Array[U8] val, _auth)?
    else
      Fail()
    end

  ///////////////
  // WATERMARKS
  ///////////////
  fun ref check_effective_input_watermark(current_ts: U64): U64 =>
    _watermarks.check_effective_input_watermark(current_ts)

  fun ref update_output_watermark(w: U64): (U64, U64) =>
    _watermarks.update_output_watermark(w)

  fun input_watermark(): U64 =>
    _watermarks.input_watermark()

  fun output_watermark(): U64 =>
    _watermarks.output_watermark()

  /////////////
  // TIMEOUTS
  /////////////
  fun ref set_timeout(t: U64) =>
    _timers(Timer(StepTimeoutNotify(this), t))

  be trigger_timeout() =>
    _phase.trigger_timeout(this)

  fun ref finish_triggering_timeout() =>
    match _runner
    | let tr: TimeoutTriggeringRunner =>
      tr.on_timeout(_consumer_sender, _router, _watermarks)
    else
      Fail()
    end

class _StepWaitingReportTimer is TimerNotify
  let _step: Step

  new iso create(step: Step) =>
    _step = step

  fun ref apply(timer: Timer, count: U64): Bool =>
    _step.step_waiting_report()
    true

