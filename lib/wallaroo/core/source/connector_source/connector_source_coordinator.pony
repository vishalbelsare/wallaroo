
/*

Copyright (C) 2016-2017, Wallaroo Labs
Copyright (C) 2016-2017, The Pony Developers
Copyright (c) 2014-2015, Causality Ltd.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

use "collections"
use "promises"
use "wallaroo/core/barrier"
use "wallaroo/core/boundary"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/invariant"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/network"
use "wallaroo/core/partitioning"
use "wallaroo/core/recovery"
use "wallaroo/core/registries"
use "wallaroo/core/routing"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/tcp_actor"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"

use @pony_asio_event_create[AsioEventID](owner: AsioEventNotify, fd: U32,
  flags: U32, nsec: U64, noisy: Bool)
use @pony_asio_event_fd[U32](event: AsioEventID)
use @pony_asio_event_unsubscribe[None](event: AsioEventID)
use @pony_asio_event_resubscribe_read[None](event: AsioEventID)
use @pony_asio_event_resubscribe_write[None](event: AsioEventID)
use @pony_asio_event_destroy[None](event: AsioEventID)
use @pony_asio_event_set_writeable[None](event: AsioEventID, writeable: Bool)


actor ConnectorSourceCoordinator[In: Any val] is
  (SourceCoordinator & Resilient)
  """
  # ConnectorSourceCoordinator
  """
  let _routing_id_gen: RoutingIdFromStringGenerator =
    RoutingIdFromStringGenerator
  let _id: RoutingId
  let _env: Env
  let _worker_name: WorkerName

  let _pipeline_name: String
  let _runner_builder: RunnerBuilder
  let _partitioner_builder: PartitionerBuilder
  var _router: Router
  let _metrics_conn: MetricsSink
  let _metrics_reporter: MetricsReporter
  let _router_registry: RouterRegistry
  var _outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val
  let _event_log: EventLog
  let _auth: AmbientAuth
  let _layout_initializer: LayoutInitializer
  let _is_recovering: Bool
  let _target_router: Router
  let _connections: Connections
  let _parallelism: USize
  let _handler: FramedSourceHandler[In] val
  let _host: String
  let _service: String
  let _cookie: String
  let _max_credits: U32
  let _refill_credits: U32

  var _fd: U32 = U32.max_value()
  var _event: AsioEventID = AsioEvent.none()
  let _limit: USize
  var _count: USize = 0
  var _closed: Bool = false
  var _init_size: USize
  var _max_size: USize
  var _max_received_count: USize

  let _connected_sources: SetIs[(RoutingId, ConnectorSource[In])] =
    _connected_sources.create()
  let _available_sources: Array[(RoutingId, ConnectorSource[In])] =
    _available_sources.create()
  var _sources_are_muted: Bool

  // Stream Registry for managing updates to local and global stream state
  let _stream_registry: LocalConnectorStreamRegistry[In]

  var _is_joining: Bool

  // TODO: These indicate an implicit state machine
  var _application_created: Bool = false
  var _ready_to_report_initialized: Bool = false

  var _initializer: (LocalTopologyInitializer | None) = None

  new create(env: Env, worker_name: WorkerName, pipeline_name: String,
    runner_builder: RunnerBuilder, partitioner_builder: PartitionerBuilder,
    router: Router, metrics_conn: MetricsSink,
    metrics_reporter: MetricsReporter iso, router_registry: RouterRegistry,
    outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val,
    event_log: EventLog, auth: AmbientAuth,
    layout_initializer: LayoutInitializer,
    is_recovering: Bool, target_router: Router = EmptyRouter,
    connections: Connections, workers_list: Array[WorkerName] val,
    is_joining: Bool,
    parallelism: USize,
    handler: FramedSourceHandler[In] val,
    host: String, service: String, cookie: String,
    max_credits: U32, refill_credits: U32,
    init_size: USize = 64, max_size: USize = 16384,
    max_received_count: USize = 50)
  =>
    """
    Listens for both IPv4 and IPv6 connections.
    """
    _env = env
    _worker_name = worker_name
    _pipeline_name = pipeline_name
    let s_name = _worker_name + _pipeline_name
    _id = try _routing_id_gen(s_name + " coordinator")? else Fail(); 0 end
    _runner_builder = runner_builder
    _partitioner_builder = partitioner_builder
    _router = router
    _metrics_conn = metrics_conn
    _metrics_reporter = consume metrics_reporter
    _router_registry = router_registry
    _outgoing_boundary_builders = outgoing_boundary_builders
    _event_log = event_log
    _auth = auth
    _layout_initializer = layout_initializer
    _is_recovering = is_recovering
    _target_router = target_router
    _connections = connections
    _is_joining = is_joining
    _parallelism = parallelism
    _handler = handler
    _host = host
    _service = service
    _cookie = cookie
    _max_credits = max_credits
    _refill_credits = refill_credits
    _limit = parallelism
    _init_size = init_size
    _max_size = max_size
    _max_received_count = max_received_count

    // Pass LocalConnectorStreamRegistry the parameters it needs to create
    // its own instance of the GlobalConnectorStreamRegistry
    _stream_registry = LocalConnectorStreamRegistry[In](this, _auth,
      _worker_name, _pipeline_name, _connections, _host, _service,
      workers_list, _is_joining)

    match router
    | let pr: StatePartitionRouter =>
      _router_registry.register_partition_router_subscriber(pr.step_group(),
        this)
    | let spr: StatelessPartitionRouter =>
      _router_registry.register_stateless_partition_router_subscriber(
        spr.partition_routing_id(), this)
    end

    @printf[I32]((pipeline_name + " source will listen (but not yet) on "
      + host + ":" + service + "\n").cstring())

    let notify_parameters = ConnectorSourceNotifyParameters[In](_pipeline_name,
      _env, _auth, _handler, _router, _metrics_reporter.clone(), _cookie,
      _max_credits, _refill_credits, _host, _service)

    for i in Range(0, _limit) do
      let source_name = _worker_name + _pipeline_name + i.string()
      let source_id = try _routing_id_gen(source_name)? else Fail(); 0 end
      let runner = _runner_builder(_router_registry, _event_log, _auth,
        _metrics_reporter.clone() where router = _target_router,
        partitioner_builder = _partitioner_builder)
      let notify = ConnectorSourceNotify[In](source_id, consume runner,
        notify_parameters, this, _is_recovering)
      // It's possible that there are more than one sink per worker for this
      // pipeline. We select our router based on our source id.
      let selected_router = _router.select_based_on_producer_id(source_id)
      let source = ConnectorSource[In](source_id, _auth, this,
        consume notify, _event_log, selected_router, SourceTCPHandlerBuilder,
        _outgoing_boundary_builders, _layout_initializer,
        _metrics_reporter.clone(), _router_registry, _router_registry)
      source.mute(this)

      _router_registry.register_source(source, source_id)
      match _router
      | let pr: StatePartitionRouter =>
        _router_registry.register_partition_router_subscriber(
          pr.step_group(), source)
      | let spr: StatelessPartitionRouter =>
        _router_registry.register_stateless_partition_router_subscriber(
          spr.partition_routing_id(), source)
      end

      _available_sources.push((source_id, source))
    end

    _sources_are_muted = true
    _event_log.register_resilient(_id, this)

  fun ref _start_listening() =>
    _event = @pony_os_listen_tcp[AsioEventID](this,
      _host.cstring(), _service.cstring())
    _fd = @pony_asio_event_fd(_event)
    _notify_listening()
    ifdef debug then
      @printf[I32]("Socket for %s now listening on %s:%s\n".cstring(),
        _pipeline_name.cstring(), _host.cstring(), _service.cstring())
    end

  fun ref _start_sources() =>
    for (source_id, s) in _available_sources.values() do
      s.unmute(this)
    end
    for (source_id, s) in _connected_sources.values() do
      s.unmute(this)
    end

  be update_router(router: Router) =>
    _router = router

  be add_boundary_builders(
    boundary_builders: Map[String, OutgoingBoundaryBuilder] val)
  =>
    let new_builders = recover trn Map[String, OutgoingBoundaryBuilder] end
    // TODO: A persistent map on the field would be much more efficient here
    for (target_worker_name, builder) in _outgoing_boundary_builders.pairs() do
      new_builders(target_worker_name) = builder
    end
    for (target_worker_name, builder) in boundary_builders.pairs() do
      if not new_builders.contains(target_worker_name) then
        new_builders(target_worker_name) = builder
      end
    end
    _outgoing_boundary_builders = consume new_builders

  be add_boundaries(bs: Map[String, OutgoingBoundary] val) =>
    None

  be update_boundary_builders(
    boundary_builders: Map[String, OutgoingBoundaryBuilder] val)
  =>
    _outgoing_boundary_builders = boundary_builders

  be remove_boundary(worker: String) =>
    let new_boundary_builders =
      recover iso Map[String, OutgoingBoundaryBuilder] end
    for (w, b) in _outgoing_boundary_builders.pairs() do
      if w != worker then new_boundary_builders(w) = b end
    end

    _outgoing_boundary_builders = consume new_boundary_builders

  be dispose() =>
    @printf[I32]("Shutting down ConnectorSourceCoordinator\n".cstring())
    _close()

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    """
    When we are readable, we accept new connections until none remain.
    """
    if event isnt _event then
      return
    end

    if AsioEvent.readable(flags) then
      _accept(arg)
    end

    if AsioEvent.disposable(flags) then
      @pony_asio_event_destroy(_event)
      _event = AsioEvent.none()
    end

  be _conn_closed(source_id: RoutingId, s: ConnectorSource[In]) =>
    """
    An accepted connection has closed. If we have dropped below the limit, try
    to accept new connections.
    """
    if _connected_sources.contains((source_id, s)) then
      _connected_sources.unset((source_id, s))
      _available_sources.push((source_id, s))
    else
      Fail()
    end
    _count = _count - 1
    ifdef debug then
      Invariant(_count == _connected_sources.size())
      Invariant(_available_sources.size() == (_limit - _count))
    end

    if _count < _limit then
      _accept()
    end

  ///////////////////////
  // Inter-worker actions
  // These are called via the connections or router actors (typically)
  ///////////////////////
  be add_worker(worker: WorkerName) =>
    _stream_registry.add_worker(worker)

  be remove_worker(worker: WorkerName) =>
    _stream_registry.remove_worker(worker)

  be receive_msg(msg: SourceCoordinatorMsg) =>
    _stream_registry.coordinator_msg_received(msg)

  ////////////////////////////////////////
  // Asynchronous stream registry actions
  // These are called by a ConnectorSource (via it's notify class)
  ////////////////////////////////////////
  be purge_pending_requests(session_id: RoutingId) =>
    _stream_registry.purge_pending_requests(session_id)

  be streams_relinquish(source_id: RoutingId, streams: Array[StreamTuple] val)
  =>
    _stream_registry.streams_relinquish(source_id, streams)

  be stream_notify(request_id: ConnectorStreamNotifyId,
    stream_id: StreamId, stream_name: String,
    point_of_ref: PointOfReference = 0,
    promise: Promise[NotifyResult[In]],
    connector_source: ConnectorSource[In] tag)
  =>
    _stream_registry.stream_notify(request_id,
      stream_id, stream_name, point_of_ref, promise, connector_source)

  ///////////////////////
  // Listener Connector
  ///////////////////////
  fun ref _accept(ns: U32 = 0) =>
    """
    Accept connections as long as we have spawned fewer than our limit.
    """
    if _closed then
      return
    elseif _count >= _limit then
      @printf[I32](("ConnectorSourceCoordinator: Already reached connection " +
        " limit\n").cstring())
      return
    end

    while _count < _limit do
      var fd = @pony_os_accept[U32](_event)

      match fd
      | -1 =>
        // Something other than EWOULDBLOCK, try again.
        None
      | 0 =>
        // EWOULDBLOCK, don't try again.
        return
      else
        _spawn(fd)
      end
    end

  fun ref _spawn(ns: U32) =>
    """
    Spawn a new connection.
    """
    try
      (let source_id, let source) = _available_sources.pop()?
      source.accept(ns, _init_size, _max_size, _max_received_count)
      _connected_sources.set((source_id, source))
      _count = _count + 1
    else
      @pony_os_socket_close[None](ns)
      Fail()
    end

  fun ref _notify_listening() =>
    """
    Inform the notifier that we're listening.
    """
    if not _event.is_null() then
      @printf[I32]((_pipeline_name + " source is listening\n")
        .cstring())
    else
      _closed = true
      @printf[I32]((_pipeline_name +
        " source is unable to listen\n").cstring())
      Fail()
    end

  fun ref _close() =>
    """
    Dispose of resources.
    """
    if _closed then
      return
    end

    _closed = true

    if not _event.is_null() then
      // When not on windows, the unsubscribe is done immediately.
      ifdef not windows then
        @pony_asio_event_unsubscribe(_event)
      end

      @pony_os_socket_close[None](_fd)
      _fd = -1
    end

  // Application startup lifecycle events
  be application_begin_reporting(initializer: LocalTopologyInitializer) =>
    initializer.report_created(this)

  be application_created(initializer: LocalTopologyInitializer) =>
    // Hold onto initializer so we can report initialized once the global
    // registry receives the leader name
    _initializer = initializer
    _application_created = true
    @printf[I32]("ConnectorSourceCoordinator for: %s created.\n".cstring(),
      _pipeline_name.cstring())
    if (not _is_joining) or _ready_to_report_initialized then
      _report_initialized()
    end

  be application_initialized(initializer: LocalTopologyInitializer) =>
    _start_listening()
    initializer.report_ready_to_work(this)

  be application_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  be cluster_ready_to_work(initializer: LocalTopologyInitializer) =>
    ifdef not "resilience" then
      // If we are building with resilience, then we can't start our sources
      // until the first checkpoint is complete.
      _start_sources()
    end

  be report_initialized() =>
    _report_initialized()

  fun ref _report_initialized() =>
    @printf[I32]("ConnectorSourceCoordinator for: %s reporting initialized.\n"
      .cstring(), _pipeline_name.cstring())
    _ready_to_report_initialized = true
    if _application_created then
      try
        (_initializer as LocalTopologyInitializer).report_initialized(this)
      else
        Fail()
      end
    end

  //////////////
  // BARRIER
  //////////////
  be initiate_barrier(token: BarrierToken) =>
    match token
    | let sbt: CheckpointBarrierToken =>
      checkpoint_state(sbt.id)
    end
    for (_, s) in _connected_sources.values() do
      s.initiate_barrier(token)
    end
    for (_, s) in _available_sources.values() do
      s.initiate_barrier(token)
    end

  be checkpoint_complete(checkpoint_id: CheckpointId) =>
    for (_, s) in _connected_sources.values() do
      s.checkpoint_complete(checkpoint_id)
    end
    for (_, s) in _available_sources.values() do
      s.checkpoint_complete(checkpoint_id)
    end
    if checkpoint_id == 1 then
      for (_, s) in _connected_sources.values() do
        s.first_checkpoint_complete()
      end
      for (_, s) in _available_sources.values() do
        s.first_checkpoint_complete()
      end
      _start_sources()
    end
    if _sources_are_muted then
      _sources_are_muted = false
      _start_sources()
    end

  //////////////
  // CHECKPOINTS
  //////////////
  fun ref checkpoint_state(checkpoint_id: CheckpointId) =>
    try
      let c_state = _stream_registry.checkpoint_state()?
      _event_log.checkpoint_state(_id, checkpoint_id, c_state)
    else
      Fail()
    end

  be prepare_for_rollback() =>
    //!@ Should we do something?
    None

  be rollback(payload: ByteSeq val, event_log: EventLog,
    checkpoint_id: CheckpointId)
  =>
    _stream_registry.rollback(payload)
    event_log.ack_rollback(_id)

  //////////////
  // AUTOSCALE
  /////////////
  be begin_grow_migration(joining_workers: Array[WorkerName] val) =>
    @printf[I32]("ConnectorSourceCoordinator completed join migration.\n"
      .cstring())
    _router_registry.source_coordinator_migration_complete(this)

  be begin_shrink_migration(leaving_workers: Array[WorkerName] val) =>
    @printf[I32]("ConnectorSourceCoordinator beginning shrink migration.\n"
      .cstring())
    // this gets called on both remaining and leaving workers
    _stream_registry.begin_shrink(leaving_workers, _connected_sources)

  be complete_shrink_migration() =>
    @printf[I32]("ConnectorSourceCoordinator completing shrink migration.\n"
      .cstring())
    _router_registry.source_coordinator_migration_complete(this)
