/*

Copyright 2018 The Wallaroo Authors.

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

use "collections"
use "net"
use "promises"
use "time"
use "wallaroo"
use "wallaroo/core/autoscale"
use "wallaroo/core/barrier"
use "wallaroo/core/boundary"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/data_channel"
use "wallaroo/core/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/invariant"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/network"
use "wallaroo/core/recovery"
use "wallaroo/core/routing"
use "wallaroo/core/source"
use "wallaroo/core/step"
use "wallaroo/core/topology"
use "wallaroo_labs/collection_helpers"
use "wallaroo_labs/messages"
use "wallaroo_labs/mort"
use "wallaroo_labs/query"
use "wallaroo_labs/string_set"


type _RouterSub is (BoundaryUpdatable & RouterUpdatable)

trait tag WorldStopperAndResumer
  be stop_the_world(exclusions: Array[WorkerName] val =
    recover Array[WorkerName] end)
  be resume_the_world(initiator: WorkerName)

actor RouterRegistry is (KeyRegistry & SourceRegistry & DisposableRegistry &
  WorldStopperAndResumer)
  let _self: RouterRegistry tag = this

  let _id: RoutingId
  let _auth: AmbientAuth
  let _data_receivers: DataReceivers
  let _worker_name: WorkerName
  let _connections: Connections
  let _recovery_file_cleaner: RecoveryFileCleaner
  let _barrier_coordinator: BarrierCoordinator
  let _checkpoint_initiator: CheckpointInitiator
  var _data_router: DataRouter
  var _local_keys: Map[RoutingId, KeySet] = _local_keys.create()
  var _local_step_keys: Map[RoutingId, Map[RoutingId, KeySet]] =
    _local_step_keys.create()
  let _partition_routers: Map[RoutingId, StatePartitionRouter] =
    _partition_routers.create()
  let _stateless_partition_routers: Map[RoutingId, StatelessPartitionRouter] =
    _stateless_partition_routers.create()

  // TODO: Remove this. This is here to be threaded to joining workers as
  // the primary checkpoint initiator worker. We need to enable this role to
  // shift to other workers, and this means we need our CheckpointInitiator
  // to add to the information we send to a joining worker (since it will
  // know who the primary checkpoint worker is).
  let _initializer_name: WorkerName

  var _local_topology_initializer: (LocalTopologyInitializer | None) = None

  var _application_ready_to_work: Bool = false

  ////////////////
  // Subscribers
  // All steps that have a StatePartitionRouter, registered by partition
  // state name
  let _partition_router_subs: Map[RoutingId, SetIs[_RouterSub]] =
    _partition_router_subs.create()
  // All steps that have a StatelessPartitionRouter, registered by
  // partition id
  let _stateless_partition_router_subs:
    Map[U128, SetIs[_RouterSub]] =
      _stateless_partition_router_subs.create()

  // Certain TargetIdRouters need to keep track of changes to particular
  // stateless partition routers. This is true when a state step needs to
  // route outputs to a stateless partition. Map is from partition id to
  // state name of state steps that need to know.
  let _stateless_partition_routers_router_subs:
    Map[U128, KeySet] =
    _stateless_partition_routers_router_subs.create()
  //
  ////////////////

  let _producers: SetIs[Producer] = _producers.create()
  let _sources: Map[RoutingId, Source] = _sources.create()
  let _source_coordinators: SetIs[SourceCoordinator] = _source_coordinators.create()
  // Map from Source digestof value to source id
  let _source_ids: Map[USize, RoutingId] = _source_ids.create()
  let _data_channel_listeners: SetIs[DataChannelListener] =
    _data_channel_listeners.create()
  let _control_channel_listeners: SetIs[TCPListener] =
    _control_channel_listeners.create()
  let _data_channels: SetIs[DataChannel] = _data_channels.create()
  // Boundary builders are used by new TCPSources to create their own
  // individual boundaries to other workers (to allow for increased
  // throughput).
  let _outgoing_boundaries_builders: Map[WorkerName, OutgoingBoundaryBuilder] =
    _outgoing_boundaries_builders.create()
  let _outgoing_boundaries: Map[WorkerName, OutgoingBoundary] =
    _outgoing_boundaries.create()

  //////
  // Partition Migration
  //////
  var _autoscale: (Autoscale | None) = None

  var _stop_the_world_in_process: Bool = false

  // TODO: Add management of pending keys to Autoscale protocol class
  // Keys migrated out and waiting for acknowledgement
  let _key_waiting_list: KeySet = _key_waiting_list.create()

  // TODO: Add management of pending source listeners to Autoscale protocol
  // class
  // Source Listeners migrated out and waiting for acknowledgment
    let _source_coordinators_waiting_list: SetIs[SourceCoordinator] =
    _source_coordinators_waiting_list.create()

  // Workers in running cluster that have been stopped for stop the world
  let _stopped_worker_waiting_list: StringSet =
    _stopped_worker_waiting_list.create()

  // TODO: Move management of this list to Autoscale class
  var _leaving_workers: Array[WorkerName] val =
    recover Array[WorkerName] end

  var _stop_the_world_pause: U64

  var _data_receivers_initialized: Bool = false
  var _waiting_to_finish_join: Bool = false
  var _joining_step_group_routing_ids:
    (Map[RoutingId, RoutingId] val | None) = None

  var _initiated_stop_the_world: Bool = false

  // If this is a worker that joined during an autoscale event, then there
  // is one worker we contacted to join.
  let _contacted_worker: (WorkerName | None)

  let _request_id_gen: RequestIdGenerator = RequestIdGenerator
  let _pending_cluster_msg_requests: Map[RequestId,
    (TCPConnection, Map[WorkerName, String], Set[WorkerName])] =
    _pending_cluster_msg_requests.create()

  new create(auth: AmbientAuth, worker_name: WorkerName,
    data_receivers: DataReceivers, c: Connections,
    recovery_file_cleaner: RecoveryFileCleaner, stop_the_world_pause: U64,
    is_joining: Bool, initializer_name: WorkerName,
    barrier_coordinator: BarrierCoordinator,
    checkpoint_initiator: CheckpointInitiator,
    contacted_worker: (WorkerName | None) = None)
  =>
    _auth = auth
    _worker_name = worker_name
    _data_receivers = data_receivers
    _connections = c
    _recovery_file_cleaner = recovery_file_cleaner
    _barrier_coordinator = barrier_coordinator
    _checkpoint_initiator = checkpoint_initiator
    _stop_the_world_pause = stop_the_world_pause
    _connections.register_disposable(this)
    _id = (digestof this).u128()
    _data_receivers.set_router_registry(this)
    _contacted_worker = contacted_worker
    _data_router =
      DataRouter(_worker_name, recover Map[RoutingId, Consumer] end,
        recover Map[RoutingId, Array[Step] val] end,
        recover Map[RoutingId, RoutingId] end)
    _initializer_name = initializer_name

  fun _worker_count(): USize =>
    _outgoing_boundaries.size() + 1

  fun producers(): SetIs[Producer] =>
    let ps: SetIs[Producer] = ps.create()
    for p in _producers.values() do
      ps.set(p)
    end
    ps

  fun outgoing_boundaries(): SetIs[OutgoingBoundary] =>
    let obs: SetIs[OutgoingBoundary] = obs.create()
    for b in _outgoing_boundaries.values() do
      obs.set(b)
    end
    obs

  fun sources(): SetIs[Source] =>
    let ss = SetIs[Source]
    for s in _sources.values() do
      ss.set(s)
    end
    ss

  be dispose() =>
    None

  be application_ready_to_work() =>
    _application_ready_to_work = true

  be data_receivers_initialized() =>
    _data_receivers_initialized = true
    if _waiting_to_finish_join then
      match _joining_step_group_routing_ids
      | let sri: Map[RoutingId, RoutingId] val =>
        if _inform_contacted_worker_of_initialization(sri) then
          _waiting_to_finish_join = false
        end
      else
        Fail()
      end
    end

  be set_autoscale(a: Autoscale) =>
    _autoscale = a

  be set_data_router(dr: DataRouter) =>
    _data_router = dr
    _distribute_data_router()

  be set_state_partition_router(step_group: RoutingId,
    pr: StatePartitionRouter)
  =>
    _partition_routers(step_group) = pr
    if not _local_keys.contains(step_group) then
      _local_keys(step_group) = KeySet
    end

  be set_stateless_partition_router(partition_id: U128,
    pr: StatelessPartitionRouter)
  =>
    _stateless_partition_routers(partition_id) = pr

  be register_local_topology_initializer(lt: LocalTopologyInitializer) =>
    _local_topology_initializer = lt

  // TODO: We need a new approach to registering all disposable actors.
  // This is a stopgap to register boundaries generated by a Source.
  // See issue #1411.
  be register_disposable(d: DisposableActor) =>
    _connections.register_disposable(d)

  be register_source(source: Source, source_id: RoutingId) =>
    _producers.set(source)
    _sources(source_id) = source
    _source_ids(digestof source) = source_id

    if not _stop_the_world_in_process and _application_ready_to_work then
      source.unmute(this)
    end
    _connections.register_disposable(source)
    _connections.notify_cluster_of_new_source(source_id)

  be unregister_source(source: Source, source_id: RoutingId) =>
    try
      _unregister_producer(source)
      _sources.remove(source_id)?
      _source_ids.remove(digestof source)?
      _connections.register_disposable(source)
      // _connections.notify_cluster_of_source_leaving(source_id)
    else
      ifdef debug then
        @printf[I32]("Couldn't find Source %s to unregister\n".cstring(),
          source_id.string().cstring())
      end
    end

  be register_remote_source(sender: WorkerName, source_id: RoutingId) =>
    None

  be register_source_coordinator(source_coordinator: SourceCoordinator) =>
    _source_coordinators.set(source_coordinator)
    _connections.register_disposable(source_coordinator)
    _checkpoint_initiator.register_source_coordinator(source_coordinator)
    _barrier_coordinator.register_source_coordinator(source_coordinator)

  be register_data_channel_listener(dchl: DataChannelListener) =>
    _data_channel_listeners.set(dchl)
    if _waiting_to_finish_join and
      (_control_channel_listeners.size() != 0)
    then
      match _joining_step_group_routing_ids
      | let sri: Map[RoutingId, RoutingId] val =>
        _inform_contacted_worker_of_initialization(sri)
        _waiting_to_finish_join = false
      else
        Fail()
      end
    end

  be register_control_channel_listener(cchl: TCPListener) =>
    _control_channel_listeners.set(cchl)
    if _waiting_to_finish_join and
      (_data_channel_listeners.size() != 0)
    then
      match _joining_step_group_routing_ids
      | let sri: Map[RoutingId, RoutingId] val =>
        _inform_contacted_worker_of_initialization(sri)
        _waiting_to_finish_join = false
      else
        Fail()
      end
    end

  be register_data_channel(dc: DataChannel) =>
    // TODO: These need to be unregistered if they close
    _data_channels.set(dc)

  be register_partition_router_subscriber(step_group: RoutingId,
    sub: _RouterSub)
  =>
    _register_partition_router_subscriber(step_group, sub)

  fun ref _register_partition_router_subscriber(step_group: RoutingId,
    sub: _RouterSub)
  =>
    try
      _partition_router_subs.insert_if_absent(step_group,
        SetIs[_RouterSub])?
      _partition_router_subs(step_group)?.set(sub)
    else
      Fail()
    end

  be unregister_partition_router_subscriber(step_group: RoutingId,
    sub: _RouterSub)
  =>
    Invariant(_partition_router_subs.contains(step_group))
    try
      _partition_router_subs(step_group)?.unset(sub)
    else
      Fail()
    end

  be register_stateless_partition_router_subscriber(partition_id: U128,
    sub: _RouterSub)
  =>
    _register_stateless_partition_router_subscriber(partition_id, sub)

  fun ref _register_stateless_partition_router_subscriber(
    partition_id: U128, sub: _RouterSub)
  =>
    try
      if _stateless_partition_router_subs.contains(partition_id) then
        _stateless_partition_router_subs(partition_id)?.set(sub)
      else
        _stateless_partition_router_subs(partition_id) =
          SetIs[_RouterSub]
        _stateless_partition_router_subs(partition_id)?.set(sub)
      end
    else
      Fail()
    end

  be unregister_stateless_partition_router_subscriber(partition_id: U128,
    sub: _RouterSub)
  =>
    Invariant(_stateless_partition_router_subs.contains(partition_id))
    try
      _stateless_partition_router_subs(partition_id)?.unset(sub)
    else
      Fail()
    end

  be register_boundaries(bs: Map[WorkerName, OutgoingBoundary] val,
    bbs: Map[WorkerName, OutgoingBoundaryBuilder] val)
  =>
    // Boundaries
    let new_boundaries = recover trn Map[WorkerName, OutgoingBoundary] end
    for (worker, boundary) in bs.pairs() do
      if not _outgoing_boundaries.contains(worker) then
        _outgoing_boundaries(worker) = boundary
        new_boundaries(worker) = boundary
      end
    end
    let new_boundaries_sendable: Map[WorkerName, OutgoingBoundary] val =
      consume new_boundaries

    for ps in _partition_router_subs.values() do
      for producer in ps.values() do
        match producer
        | let s: Step =>
          s.add_boundaries(new_boundaries_sendable)
        end
      end
    end
    for ps in _stateless_partition_router_subs.values() do
      for producer in ps.values() do
        match producer
        | let s: Step =>
          s.add_boundaries(new_boundaries_sendable)
        end
      end
    end
    for step in _data_router.routes().values() do
      match step
      | let s: Step => s.add_boundaries(new_boundaries_sendable)
      end
    end

    // Boundary builders
    let new_boundary_builders =
      recover trn Map[WorkerName, OutgoingBoundaryBuilder] end
    for (worker, builder) in bbs.pairs() do
      // Boundary builders should always be registered after the canonical
      // boundary for each builder. The canonical is used on all Steps.
      // Sources use the builders to create a new boundary per source
      // connection.
      if not _outgoing_boundaries.contains(worker) then
        Fail()
      end
      if not _outgoing_boundaries_builders.contains(worker) then
        _outgoing_boundaries_builders(worker) = builder
        new_boundary_builders(worker) = builder
      end
    end

    let new_boundary_builders_sendable:
      Map[WorkerName, OutgoingBoundaryBuilder] val =
        consume new_boundary_builders

    for source_coordinator in _source_coordinators.values() do
      source_coordinator.add_boundary_builders(new_boundary_builders_sendable)
    end

    for source in _sources.values() do
      source.add_boundary_builders(new_boundary_builders_sendable)
    end

  be register_key(step_group: RoutingId, key: Key,
    checkpoint_id: (CheckpointId | None) = None)
  =>
    _register_key(step_group, key, checkpoint_id)

  fun ref _register_key(step_group: RoutingId, key: Key,
    checkpoint_id: (CheckpointId | None) = None)
  =>
    try
      if not _local_keys.contains(step_group) then
        _local_keys(step_group) = KeySet
      end
      _local_keys(step_group)?.set(key)
      _record_step_key(step_group, key)?
      (_local_topology_initializer as LocalTopologyInitializer)
        .register_key(step_group, key, checkpoint_id)
    else
      Fail()
    end

  fun ref _record_step_key(step_group: RoutingId, key: Key) ? =>
    _local_step_keys.insert_if_absent(step_group, Map[RoutingId, KeySet])?
    let step_keys = _local_step_keys(step_group)?
    let partition_router = _partition_routers(step_group)?
    let step_id = partition_router.step_id_for_key(key)?
    step_keys.insert_if_absent(step_id, KeySet)?
    step_keys(step_id)?.set(key)

  be unregister_key(step_group: RoutingId, key: Key,
    checkpoint_id: (CheckpointId | None) = None)
  =>
    _unregister_key(step_group, key, checkpoint_id)

  fun ref _unregister_key(step_group: RoutingId, key: Key,
    checkpoint_id: (CheckpointId | None) = None)
  =>
    try
      _local_keys.insert_if_absent(step_group, KeySet)?
      _local_keys(step_group)?.unset(key)
      _remove_step_key(step_group, key)?
      (_local_topology_initializer as LocalTopologyInitializer)
        .unregister_key(step_group, key, checkpoint_id)
    else
      Fail()
    end

  fun ref _remove_step_key(step_group: RoutingId, key: Key) ? =>
    _local_step_keys.insert_if_absent(step_group, Map[RoutingId, KeySet])?
    let step_keys = _local_step_keys(step_group)?
    let partition_router = _partition_routers(step_group)?
    let step_id = partition_router.step_id_for_key(key)?
    step_keys.insert_if_absent(step_id, KeySet)?
    step_keys(step_id)?.unset(key)

  be register_producer(p: Producer) =>
    _producers.set(p)

  be unregister_producer(p: Producer) =>
    _unregister_producer(p)

  fun ref _unregister_producer(p: Producer) =>
    _producers.unset(p)

  fun _distribute_data_router() =>
    _data_receivers.update_data_router(_data_router)

  fun ref _distribute_partition_router(partition_router: StatePartitionRouter)
  =>
    let step_group = partition_router.step_group()

    try
      _partition_router_subs.insert_if_absent(step_group,
        SetIs[_RouterSub])?

      for sub in _partition_router_subs(step_group)?.values() do
        sub.update_router(partition_router)
      end
    else
      Fail()
    end

  fun ref _distribute_stateless_partition_router(
    partition_router: StatelessPartitionRouter)
  =>
    let partition_id = partition_router.partition_routing_id()

    try
      if not _stateless_partition_router_subs.contains(partition_id) then
        _stateless_partition_router_subs(partition_id) =
          SetIs[_RouterSub]
      end
      for sub in
        _stateless_partition_router_subs(partition_id)?.values()
      do
        sub.update_router(partition_router)
      end
    else
      Fail()
    end

  fun ref _remove_worker(worker: WorkerName) =>
    _distribute_boundary_removal(worker)

  fun ref _distribute_boundary_removal(worker: WorkerName) =>
    for subs in _partition_router_subs.values() do
      for sub in subs.values() do
        match sub
        | let r: BoundaryUpdatable =>
          r.remove_boundary(worker)
        end
      end
    end
    for subs in _stateless_partition_router_subs.values() do
      for sub in subs.values() do
        match sub
        | let r: BoundaryUpdatable =>
          r.remove_boundary(worker)
        end
      end
    end

    for source in _sources.values() do
      source.remove_boundary(worker)
    end
    for source_coordinator in _source_coordinators.values() do
      source_coordinator.remove_boundary(worker)
    end

    match _local_topology_initializer
    | let lt: LocalTopologyInitializer =>
      lt.remove_boundary(worker)
    else
      Fail()
    end

  fun _distribute_boundary_builders() =>
    let boundary_builders =
      recover trn Map[String, OutgoingBoundaryBuilder] end
    for (worker, builder) in _outgoing_boundaries_builders.pairs() do
      boundary_builders(worker) = builder
    end

    let boundary_builders_to_send = consume val boundary_builders

    for source_coordinator in _source_coordinators.values() do
      source_coordinator.update_boundary_builders(boundary_builders_to_send)
    end

  be report_status(code: ReportStatusCode) =>
    match code
    | BoundaryCountStatus =>
      @printf[I32]("RouterRegistry knows about %s boundaries\n"
        .cstring(), _outgoing_boundaries.size().string().cstring())
    end
    for source in _sources.values() do
      source.report_status(code)
    end
    for boundary in _outgoing_boundaries.values() do
      boundary.report_status(code)
    end

  be dispose_producers(promise: Promise[None]) =>
    _dispose_producers(promise)

  fun ref _dispose_producers(promise: Promise[None]) =>
    let ps = Array[Promise[None]]
    for producer in _producers.values() do
      let p = Promise[None]
      ps.push(p)
      producer.dispose_with_promise(p)
    end
    let promises = Promises[None].join(ps.values())
    promises.next[None]({(_: None) => promise(None)})

  // TODO: How should we handle this pattern? This is where we send a promise
  // to retrieve a value that we need before we can continue processing. Pub
  // sub doesn't work in cases where we need to ensure we have the latest
  // value at certain point.
  be list_producers(promise: Promise[SetIs[Producer] val]) =>
    let ps: SetIs[Producer] iso = recover SetIs[Producer] end
    for p in _producers.values() do
      ps.set(p)
    end
    promise(consume ps)

  be list_boundaries(promise: Promise[Map[WorkerName, OutgoingBoundary] val])
  =>
    let bs: Map[WorkerName, OutgoingBoundary] iso =
      recover Map[WorkerName, OutgoingBoundary] end
    for (w, b) in _outgoing_boundaries.pairs() do
      bs(w) = b
    end
    promise(consume bs)

  // !TODO!: This probably shouldn't be here.
  be clean_shutdown() =>
    _recovery_file_cleaner.clean_shutdown()

  // TODO: Move management of stop the world to another actor
  /////////////////////////////////////////////////////////////////////////////
  // STOP THE WORLD
  /////////////////////////////////////////////////////////////////////////////
  be stop_the_world(exclusions: Array[WorkerName] val =
    recover Array[WorkerName] end)
  =>
    // !TODO!: What do we do if one is already in progress?
    _stop_the_world(exclusions)

  be resume_the_world(initiator: WorkerName) =>
    """
    Stop the world is complete and we're ready to resume message processing
    and notify the cluster.
    """
    _resume_all_remote()
    _resume_the_world(initiator)

  be resume_processing(initiator: WorkerName) =>
    """
    Received when another worker has decided the cluster is ready to resume
    the world.
    """
    _resume_the_world(initiator)

  fun ref _stop_the_world(exclusions: Array[WorkerName] val =
    recover Array[WorkerName] end)
  =>
    _stop_the_world_in_process = true
    _mute_request(_worker_name)
    _connections.stop_the_world(exclusions)

  be initiate_stop_the_world_for_grow_migration(
    new_workers: Array[WorkerName] val)
  =>
    _initiated_stop_the_world = true
    _stop_the_world_for_grow_migration(new_workers)

  be stop_the_world_for_grow_migration(
    new_workers: Array[WorkerName] val)
  =>
    """
    Called when new workers join the cluster and we are ready to start
    the partition migration process. We first check that all
    in-flight messages have finished processing.
    """
    _stop_the_world_for_grow_migration(new_workers)

  fun ref _stop_the_world_for_grow_migration(exclusions: Array[WorkerName] val)
  =>
    """
    We currently stop all message processing before migrating partitions and
    updating routers/routes.
    """
    @printf[I32]("~~~Stopping message processing for state migration.~~~\n"
      .cstring())
    _stop_the_world(exclusions)

  be initiate_stop_the_world_for_shrink_migration(
    remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    _initiated_stop_the_world = true
    _stop_the_world_for_shrink_migration()

  be stop_the_world_for_shrink_migration(
    remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    _stop_the_world_for_shrink_migration()

  fun ref _stop_the_world_for_shrink_migration() =>
    """
    We currently stop all message processing before migrating partitions and
    updating routers/routes.
    """
    @printf[I32]("~~~Stopping message processing for leaving workers.~~~\n"
      .cstring())
    _stop_the_world()

  // !TODO!: Currently we are conflating autoscale with the more general
  // stop and resume the world protocol. These need to be disentangled.
  fun ref _try_resume_the_world() =>
    if _initiated_stop_the_world then
      try
        (_autoscale as Autoscale).ready_to_resume_the_world()
      else
        Fail()
      end

      // We are done with this round of leaving workers
      //!TODO!: RouterRegistry shouldn't know about autoscale-specific
      // concepts.
      _leaving_workers = recover Array[WorkerName] end
    end

  fun ref _resume_the_world(initiator: WorkerName) =>
    _initiated_stop_the_world = false
    _stop_the_world_in_process = false
    _resume_all_local()
    @printf[I32]("~~~Resuming message processing.~~~\n".cstring())

  be remote_mute_request(originating_worker: WorkerName) =>
    """
    A remote worker requests that we mute all sources and data channel.
    """

    _mute_request(originating_worker)

  fun ref _mute_request(originating_worker: WorkerName) =>
    _stopped_worker_waiting_list.set(originating_worker)
    _stop_all_local()

  be remote_unmute_request(originating_worker: WorkerName) =>
    """
    A remote worker requests that we unmute all sources and data channel.
    """
    _unmute_request(originating_worker)

  fun ref _unmute_request(originating_worker: WorkerName) =>
    if _stopped_worker_waiting_list.size() > 0 then
      _stopped_worker_waiting_list.unset(originating_worker)
      if (_stopped_worker_waiting_list.size() == 0) then
        _try_resume_the_world()
      end
    end

  fun _stop_all_local() =>
    """
    Mute all sources and data channel.
    """
    ifdef debug then
      @printf[I32]("RouterRegistry muting any local sources.\n".cstring())
    end
    for source in _sources.values() do
      source.mute(this)
    end

  fun _resume_all_local() =>
    """
    Unmute all sources and data channel.
    """
    ifdef debug then
      @printf[I32]("RouterRegistry unmuting any local sources.\n".cstring())
    end
    for source in _sources.values() do
      source.unmute(this)
    end

  fun _resume_all_remote() =>
    try
      let msg = ChannelMsgEncoder.resume_processing(_worker_name, _auth)?
      _connections.send_control_to_cluster(msg)
    else
      Fail()
    end

  fun ref try_to_resume_processing_immediately() =>
    if ((_key_waiting_list.size() == 0) and
        (_source_coordinators_waiting_list.size() == 0))
    then
      try
        (_autoscale as Autoscale).all_migration_complete()
      else
        Fail()
      end
    end

  /////////////////////////////////////////////////////////////////////////////
  // ROLLBACK
  /////////////////////////////////////////////////////////////////////////////
  be rollback_keys(r_keys: Map[RoutingId, KeySet val] val,
    promise: Promise[None])
  =>
    let new_keys = Map[RoutingId, KeySet]
    for (step_group, keys) in r_keys.pairs() do
      let ks = KeySet
      for k in keys.values() do
        ks.set(k)
      end
      new_keys(step_group) = consume ks
    end

    _local_keys = new_keys

    promise(None)

  /////////////////////////////////////////////////////////////////////////////
  // JOINING WORKER
  /////////////////////////////////////////////////////////////////////////////
  be add_joining_worker_to_routers(worker: WorkerName,
    step_group_routing_ids: Map[RoutingId, RoutingId] val)
  =>
    for (sg_rid, w_rid) in step_group_routing_ids.pairs() do
      // Check if this is a step group we know about
      if _partition_routers.contains(sg_rid) then
        try
          let new_router = _partition_routers(sg_rid)?
            .add_worker_routing_id(worker, w_rid)
          _partition_routers(sg_rid) = new_router
          _distribute_partition_router(new_router)
        else
          Unreachable()
        end
      elseif _stateless_partition_routers.contains(sg_rid) then
        try
          let proxy_router = ProxyRouter(_worker_name,
            _outgoing_boundaries(worker)?,
            ProxyAddress(worker, w_rid), _auth)

          let new_router = _stateless_partition_routers(sg_rid)?
            .add_worker(worker, w_rid, proxy_router)
          _stateless_partition_routers(sg_rid) = new_router
          _distribute_stateless_partition_router(new_router)
        else
          Fail()
        end
      else
        ifdef debug then
          @printf[I32]("This worker doesn't know about step group %s\n"
            .cstring(), sg_rid.string().cstring())
        end
      end
    end

  // Called if we are the joining worker and we need to announce we're
  // initialized
  be inform_contacted_worker_of_initialization(
    step_group_routing_ids: Map[RoutingId, RoutingId] val)
  =>
    _inform_contacted_worker_of_initialization(step_group_routing_ids)

  fun ref _inform_contacted_worker_of_initialization(
    step_group_routing_ids: Map[RoutingId, RoutingId] val): Bool
  =>
    match _contacted_worker
    | let cw: WorkerName =>
      if (_data_channel_listeners.size() != 0) and
         (_control_channel_listeners.size() != 0) and
         _data_receivers_initialized
      then
        _connections.inform_contacted_worker_of_initialization(cw,
          step_group_routing_ids)
        true
      else
        _joining_step_group_routing_ids = step_group_routing_ids
        _waiting_to_finish_join = true
        false
      end
    else
      Fail()
      false
    end

  be inform_worker_of_boundary_count(target_worker: WorkerName) =>
    // There is one boundary per source plus the canonical boundary.
    // BarrierSource, a special case, is not counted here because it uses the
    // canonical boundary and doesn't register as a normal source.
    let count = _sources.size() + 1
    _connections.inform_worker_of_boundary_count(target_worker, count)

  be reconnect_source_boundaries(target_worker: WorkerName) =>
    for source in _sources.values() do
      source.reconnect_boundary(target_worker)
    end

  /////////////////////////////////////////////////////////////////////////////
  // NEW WORKER PARTITION MIGRATION
  /////////////////////////////////////////////////////////////////////////////

  // !TODO!
  // Once all workers connect to joining workers, the coordinator hands
  // the reigns over to RouterRegistry to handle join migration. This
  // shouldn't be a behavior anymore. In fact, should RouterRegistry be
  // involved here at all?
  //
  // Once we get a checkpoint id from CheckpointInitiator, we initiate.
  // This currently includes, telling BarrierCoordinator about new workers,
  // informing other non-coordinators to begin migration, informing joining
  // workers of joining worker names, telling source coordinators to begin
  // migration, and telling routers to migrate steps.
  be prepare_grow_migration(target_workers: Array[WorkerName] val) =>
    let lookup_next_checkpoint_id = Promise[CheckpointId]
    lookup_next_checkpoint_id.next[None](
      _self~initiate_grow_migration(target_workers))
    _checkpoint_initiator.lookup_next_checkpoint_id(lookup_next_checkpoint_id)

  be initiate_grow_migration(target_workers: Array[WorkerName] val,
    next_checkpoint_id: CheckpointId)
  =>
    // Update BarrierCoordinator about new workers
    for w in target_workers.values() do
      _barrier_coordinator.add_worker(w)
      for source_coordinator in _source_coordinators.values() do
        source_coordinator.add_worker(w)
      end
    end

    // Inform other current workers to begin migration
    try
      let msg =
        ChannelMsgEncoder.initiate_grow_migration(target_workers,
          next_checkpoint_id, _auth)?
      _connections.send_control_to_cluster_with_exclusions(msg, target_workers)
    else
      Fail()
    end

    // Inform joining workers of joining worker names
    try
      let msg =
        ChannelMsgEncoder.pre_register_joining_workers(target_workers, _auth)?
      for w in target_workers.values() do
        _connections.send_control(w, msg)
      end
    else
      Fail()
    end

    _begin_grow_migration(target_workers, next_checkpoint_id)

  //!@<- Fix naming initiate vs. begin is confusing
  be begin_grow_migration(target_workers: Array[WorkerName] val,
    next_checkpoint_id: CheckpointId)
  =>
    _begin_grow_migration(target_workers, next_checkpoint_id)

  fun ref _begin_grow_migration(target_workers: Array[WorkerName] val,
    next_checkpoint_id: CheckpointId)
  =>
    """
    Begin partition migration to joining workers
    """
    for source_coordinator in _source_coordinators.values() do
      _source_coordinators_waiting_list.set(source_coordinator)
      // !TODO!: Are we missing the source coordinators on non-coordinator
      // workers for autoscale?
      source_coordinator.begin_grow_migration(target_workers)
    end
    if ((_partition_routers.size() == 0) and
        (_source_coordinators_waiting_list.size() == 0))
    then
      //no steps have been migrated
      @printf[I32](("Resuming message processing immediately. No partitions " +
        "to migrate.\n").cstring())
      _resume_the_world(_worker_name)
    end
    for w in target_workers.values() do
      @printf[I32]("Migrating partitions to %s\n".cstring(), w.cstring())
    end
    var had_steps_to_migrate = false
    for step_group in _partition_routers.keys() do
      let had_steps_to_migrate_for_this_state =
        _migrate_partition_steps(step_group, target_workers,
          next_checkpoint_id)
      if had_steps_to_migrate_for_this_state then
        had_steps_to_migrate = true
      end
    end
    // !TODO! This might miss source coordinators that need to migrate stuff.
    if not had_steps_to_migrate then
      try_to_resume_processing_immediately()
    end

  be key_migration_complete(key: Key) =>
    """
    State for the provided key has been migrated to another worker.
    """
    if _key_waiting_list.size() > 0 then
      _key_waiting_list.unset(key)
      try_to_resume_processing_immediately()
    end

  be source_coordinator_migration_complete(source_coordinator: SourceCoordinator) =>
    try
      _source_coordinators_waiting_list.extract(source_coordinator)?
      try_to_resume_processing_immediately()
    end

  be send_migration_batch_complete_msg(target: WorkerName) =>
    """
    Inform migration target that the entire migration batch has been sent.
    """
    try
      _outgoing_boundaries(target)?.send_migration_batch_complete()
    else
      Fail()
    end

  be inform_joining_workers_of_hash_partitions(
    joining_workers: Array[WorkerName] val)
  =>
    let hash_partitions_trn = recover trn Map[RoutingId, HashPartitions] end
    for (step_group, pr) in _partition_routers.pairs() do
      hash_partitions_trn(step_group) = pr.hash_partitions()
    end
    let hash_partitions = consume val hash_partitions_trn
    try
      let msg = ChannelMsgEncoder.announce_hash_partitions_grow(_worker_name,
        joining_workers, hash_partitions, _auth)?
      for w in joining_workers.values() do
        _connections.send_control(w, msg)
      end
    else
      Fail()
    end
    for w in joining_workers.values() do
      _checkpoint_initiator.add_worker(w)
    end

  be complete_grow(joining_workers: Array[WorkerName] val,
    is_coordinator: Bool)
  =>
    _connections.request_cluster_unmute()
    _unmute_request(_worker_name)

  be update_hash_partitions(
    hash_partitions: Map[RoutingId, HashPartitions] val)
  =>
    """
    Called on joining workers after migration is complete and they've been
    informed of all hash partitions.
    """
    for (step_group, pr) in _partition_routers.pairs() do
      var new_pr = pr.update_boundaries(_auth, _outgoing_boundaries)
      try
        new_pr = new_pr.update_hash_partitions(hash_partitions(step_group)?)
        _distribute_partition_router(new_pr)
        _partition_routers(step_group) = new_pr
      else
        Fail()
      end
    end

  fun ref _migrate_partition_steps(step_group: RoutingId,
    target_workers: Array[WorkerName] val, next_checkpoint_id: CheckpointId):
    Bool
  =>
    """
    Called to initiate migrating partition steps to a target worker in order
    to rebalance. Return false if there were no steps to migrate.
    """
    try
      for w in target_workers.values() do
        @printf[I32]("Migrating steps for %s partition to %s\n".cstring(),
          step_group.string().cstring(), w.cstring())
      end

      let sorted_target_workers =
        ArrayHelpers[WorkerName].sorted[WorkerName](target_workers)

      let tws = recover trn Array[(WorkerName, OutgoingBoundary)] end
      for w in sorted_target_workers.values() do
        let boundary = _outgoing_boundaries(w)?
        tws.push((w, boundary))
      end
      let partition_router = _partition_routers(step_group)?
      // Simultaneously calculate new partition router and initiate individual
      // step migration. We get the new router back as well as a Bool
      // indicating whether any steps were migrated.
      (let new_partition_router, let had_steps_to_migrate) =
        partition_router.rebalance_steps_grow(_auth, consume tws, this,
          _local_keys(step_group)?, next_checkpoint_id)
      // TODO: It could be if had_steps_to_migrate is false then we don't
      // need to distribute the router because it didn't change. Investigate.
      _distribute_partition_router(new_partition_router)
      _partition_routers(step_group) = new_partition_router
      had_steps_to_migrate
    else
      Fail()
      false
    end

  fun ref _migrate_all_partition_steps(step_group: RoutingId,
    target_workers: Array[(WorkerName, OutgoingBoundary)] val,
    leaving_workers: Array[WorkerName] val,
    next_checkpoint_id: CheckpointId): Bool
  =>
    """
    Called to initiate migrating all partition steps the set of remaining
    workers. Return false if there is nothing to migrate.
    """
    try
      @printf[I32]("Migrating steps for %s partition to %d workers\n"
        .cstring(), step_group.string().cstring(), target_workers.size())
      let partition_router = _partition_routers(step_group)?
      partition_router.rebalance_steps_shrink(target_workers, leaving_workers,
        this, _local_keys(step_group)?, next_checkpoint_id)
    else
      Fail()
      false
    end

  fun ref add_to_key_waiting_list(key: Key) =>
    _key_waiting_list.set(key)

  /////////////////////////////////////////////////////////////////////////////
  // SHRINK TO FIT
  /////////////////////////////////////////////////////////////////////////////

  be initiate_shrink(remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    """
    This is called on the worker contacted via an external message to
    initiate. It's called when the initial shrink barrier is complete. If the
    contacted worker is not eligible to be coordinator, it will
    forward it to someone else. Right now this happens if the contacted worker
    is going to be a leaving worker.
    """
    if ArrayHelpers[WorkerName].contains[WorkerName](leaving_workers,
      _worker_name)
    then
      // Since we're one of the leaving workers, we're handing off
      // responsibility for the shrink to one of the remaining workers.
      try
        let shrink_initiator = remaining_workers(0)?
        let msg = ChannelMsgEncoder.initiate_shrink(remaining_workers,
          leaving_workers, _auth)?
        _connections.send_control(shrink_initiator, msg)
      else
        Fail()
      end
    else
      @printf[I32]("~~~Initiating shrink~~~\n".cstring())
      @printf[I32]("-- Remaining workers: \n".cstring())
      for w in remaining_workers.values() do
        @printf[I32]("-- -- %s\n".cstring(), w.cstring())
      end

      @printf[I32]("-- Leaving workers: \n".cstring())
      for w in leaving_workers.values() do
        @printf[I32]("-- -- %s\n".cstring(), w.cstring())
      end
      try
        let msg = ChannelMsgEncoder.prepare_shrink(remaining_workers,
          leaving_workers, _auth)?
        for w in remaining_workers.values() do
          if w != _worker_name then
            _connections.send_control(w, msg)
          end
        end
      else
        Fail()
      end
      _prepare_shrink(remaining_workers, leaving_workers)

      let promise = Promise[None]
      _announce_leaving_migration(remaining_workers, leaving_workers)
    end

  be prepare_shrink(remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    """
    One worker is contacted via external message to begin autoscale
    shrink. That worker then informs every other worker to prepare for
    shrink. This behavior is called in response to receiving that message
    from the contacted worker.
    """
    _prepare_shrink(remaining_workers, leaving_workers)

  fun ref _prepare_shrink(remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    for (p_id, router) in _stateless_partition_routers.pairs() do
      let new_router = router.remove_workers(leaving_workers)
      _distribute_stateless_partition_router(new_router)
      _stateless_partition_routers(p_id) = new_router
    end
    // Inform remaining source listeners of shrink
    for listener in _source_coordinators.values() do
      listener.begin_shrink_migration(leaving_workers)
    end

  //!@<- begin vs. initiate
  be begin_leaving_migration(remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val, next_checkpoint_id: CheckpointId)
  =>
    """
    This should only be called on a worker designated to leave the cluster
    as part of shrink to fit.
    """
    @printf[I32]("Beginning process of leaving cluster.\n".cstring())
    for source_coordinator in _source_coordinators.values() do
      _source_coordinators_waiting_list.set(source_coordinator)
      source_coordinator.begin_shrink_migration(leaving_workers)
    end

    _leaving_workers = leaving_workers
    if ((_partition_routers.size() == 0) and
        (_source_coordinators_waiting_list.size() == 0))
    then
      @printf[I32](("No partitions to migrate.\n").cstring())
      try
        (_autoscale as Autoscale).all_migration_complete()
      else
        Fail()
      end
      return
    end

    let sorted_remaining_workers =
      ArrayHelpers[WorkerName].sorted[WorkerName](remaining_workers)

    let rws_trn = recover trn Array[(String, OutgoingBoundary)] end
    for w in sorted_remaining_workers.values() do
      try
        let boundary = _outgoing_boundaries(w)?
        rws_trn.push((w, boundary))
      else
        Fail()
      end
    end
    let rws = consume val rws_trn
    if rws.size() == 0 then Fail() end

    @printf[I32]("Migrating all partitions to %d remaining workers\n"
      .cstring(), remaining_workers.size())

    var had_steps_to_migrate = false
    for step_group in _partition_routers.keys() do
      let steps_to_migrate_for_this_state =
        _migrate_all_partition_steps(step_group, rws, leaving_workers,
          next_checkpoint_id)
      if steps_to_migrate_for_this_state then
        had_steps_to_migrate = true
      end
    end
    if not had_steps_to_migrate then
      try_to_resume_processing_immediately()
    end

  fun _announce_leaving_migration(remaining_workers: Array[WorkerName] val,
    leaving_workers: Array[WorkerName] val)
  =>
    try
      let msg = ChannelMsgEncoder.begin_leaving_migration(remaining_workers,
        leaving_workers, _auth)?
      for w in leaving_workers.values() do
        if w == _worker_name then
          // Leaving workers shouldn't be managing the shrink process.
          Fail()
        else
          _connections.send_control(w, msg)?
        end
      end
    else
      Fail()
    end

  be disconnect_from_leaving_worker(worker: WorkerName) =>
    _connections.disconnect_from(worker)
    try
      _remove_worker(worker)
      _outgoing_boundaries(worker)?.dispose()
      for s in _sources.values() do
        s.disconnect_boundary(worker)
      end
      _outgoing_boundaries.remove(worker)?
      _outgoing_boundaries_builders.remove(worker)?
      _unmute_request(worker)
    else
      Fail()
    end

    _distribute_boundary_builders()

    try
      (_autoscale as Autoscale).leaving_worker_finished_migration(worker)
    else
      Fail()
    end

  be all_leaving_workers_finished(leaving_workers: Array[WorkerName] val) =>
    for w in leaving_workers.values() do
      _barrier_coordinator.remove_worker(w)
      _checkpoint_initiator.remove_worker(w)
      for source_coordinator in _source_coordinators.values() do
        source_coordinator.remove_worker(w)
      end
      // !TODO!: Do we need this ??
      _unmute_request(w)
    end
    for (step_group, pr) in _partition_routers.pairs() do
      let new_pr = pr.recalculate_hash_partitions_for_shrink(leaving_workers)
      _partition_routers(step_group) = new_pr
      // !TODO!: Do we need to keep distributing like this?
      _distribute_partition_router(new_pr)
    end
    _connections.request_cluster_unmute()
    _unmute_request(_worker_name)

  /////////////////////////////////////////////////////////////////////////////
  // Key moved onto this worker
  /////////////////////////////////////////////////////////////////////////////

  be receive_immigrant_key(msg: KeyMigrationMsg) =>
    try
      _register_key(msg.step_group(), msg.key(), msg.checkpoint_id())
      _partition_routers(msg.step_group())?
        .receive_key_state(msg.key(), msg.state())
      _connections.notify_cluster_of_new_key(msg.key(), msg.step_group())
    else
      Fail()
    end

  /////////////////////////////////////////////////////////////////////////////
  // EXTERNAL QUERIES
  /////////////////////////////////////////////////////////////////////////////
  be partition_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.partition_query_response(
      _partition_routers, _stateless_partition_routers)
    conn.writev(msg)

  be partition_count_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.partition_count_query_response(
      _partition_routers, _stateless_partition_routers)
    conn.writev(msg)

  be cluster_status_query_not_initialized(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.cluster_status_query_reponse_not_initialized()
    conn.writev(msg)

  be cluster_status_query(worker_names: Array[WorkerName] val,
    conn: TCPConnection)
  =>
    let msg = ExternalMsgEncoder.cluster_status_query_response(
      worker_names.size(), worker_names, _stop_the_world_in_process)
    conn.writev(msg)

  be source_ids_query(conn: TCPConnection) =>
    let ids = recover iso Array[String] end
    for s_id in _source_ids.values() do
      ids.push(s_id.string())
    end
    let msg = ExternalMsgEncoder.source_ids_query_response(
      consume ids)
    conn.writev(msg)

  be state_entity_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.state_entity_query_response(_local_keys)
    conn.writev(msg)

  be stateless_partition_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.stateless_partition_query_response(
      _stateless_partition_routers)
    conn.writev(msg)

  be state_entity_count_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.state_entity_count_query_response(
      _local_keys)
    conn.writev(msg)

  be cluster_state_entity_count_query(conn: TCPConnection,
    worker_names: Array[WorkerName] val)
  =>
    let req_id = _request_id_gen()
    let cluster_state_entity_counts = Map[WorkerName, String]()
    let worker_digest =
      ExternalMsgEncoder.step_state_entity_digest(_local_step_keys)
    let state_entity_count_json =
       StepStateEntityCountQueryEncoder.step_state_entity_count(worker_digest)
    cluster_state_entity_counts(_worker_name) = state_entity_count_json
    let pending_set = Set[WorkerName]()
    for worker_name in worker_names.values() do
      if worker_name != _worker_name then
        pending_set.set(worker_name)
        _request_worker_state_entity_count(req_id, worker_name)
      end
    end
    _pending_cluster_msg_requests(req_id) =
      (conn, cluster_state_entity_counts, pending_set)
    _check_pending_cluster_msg_requests(req_id)

  be stateless_partition_count_query(conn: TCPConnection) =>
    let msg = ExternalMsgEncoder.stateless_partition_count_query_response(
      _stateless_partition_routers)
    conn.writev(msg)

  be update_worker_data_service(worker: WorkerName,
    host: String, service: String)
  =>
    @printf[I32]("SLF: RouterRegistry: update_worker_data_service: %s -> %s %s\n".cstring(), worker.cstring(), host.cstring(), service.cstring())
    try
      let b = _outgoing_boundaries(worker)?
      b.update_worker_data_service(worker, host, service)
    else
      Fail()
    end
    try
      let old_bb = _outgoing_boundaries_builders(worker)?
      let new_bb = old_bb.clone_with_new_service(host, service)
      _outgoing_boundaries_builders(worker) = new_bb
    else
      Fail()
    end
    _distribute_boundary_builders()
    for source in _sources.values() do
      source.update_worker_data_service(worker, host, service)
    end

  be receive_source_coordinator_msg(msg: SourceCoordinatorMsg) =>
    _receive_source_coordinator_msg(msg)

  be receive_worker_state_entity_count_request_msg(
    msg: WorkerStateEntityCountRequestMsg)
  =>
    _receive_worker_state_entity_count_request_msg(msg)

  be receive_worker_state_entity_count_response_msg(
    msg: WorkerStateEntityCountResponseMsg)
  =>
    _receive_worker_state_entity_count_response_msg(msg)


  fun ref _receive_worker_state_entity_count_request_msg(
    msg: WorkerStateEntityCountRequestMsg)
  =>
    let requester = msg.requester
    let request_id = msg.request_id

    let digest = ExternalMsgEncoder.step_state_entity_digest(_local_step_keys)
    let state_entity_count_json =
      StepStateEntityCountQueryEncoder.step_state_entity_count(digest)
    try
      let out_msg =
        ChannelMsgEncoder.worker_state_entity_count_response(_worker_name,
          request_id, state_entity_count_json, _auth)?
      _connections.send_control(requester, out_msg)
    else
      Fail()
    end

  fun ref _receive_worker_state_entity_count_response_msg(
    msg: WorkerStateEntityCountResponseMsg)
  =>
    let worker_name = msg.worker_name
    let request_id = msg.request_id
    let state_entity_count_json = msg.state_entity_count_json
    try
      (let conn, let cluster_state_entity_counts, let pending_set) =
        _pending_cluster_msg_requests(request_id)?
      if pending_set.contains(worker_name) then
        cluster_state_entity_counts(worker_name) = state_entity_count_json
        pending_set.unset(worker_name)
      end
      _check_pending_cluster_msg_requests(request_id)
    else
      Fail()
    end

  fun ref _receive_source_coordinator_msg(msg: SourceCoordinatorMsg) =>
    for source_coordinator in _source_coordinators.values() do
      source_coordinator.receive_msg(msg)
    end

  fun ref _request_worker_state_entity_count(request_id: RequestId,
    worker_name: WorkerName)
  =>
    try
      let msg =
        ChannelMsgEncoder.worker_state_entity_count_request(worker_name,
          _worker_name, request_id, _auth)?
      _connections.send_control(worker_name, msg)
    else
      Fail()
    end

  fun ref _check_pending_cluster_msg_requests(request_id: RequestId) =>
    try
      (let conn, let cluster_state_entity_counts, let pending_set) =
        _pending_cluster_msg_requests(request_id)?
      if pending_set.size() == 0 then
        _external_cluster_state_entity_count_query_response(conn,
          cluster_state_entity_counts)
        _pending_cluster_msg_requests.remove(request_id)?
      end
    else
      Fail()
    end

  fun ref _external_cluster_state_entity_count_query_response(
    conn: TCPConnection, cluster_state_entity_counts: Map[WorkerName, String])
  =>
    try
      let msg = ExternalMsgEncoder.cluster_state_entity_count_query_response(
        cluster_state_entity_counts)?
      conn.writev(msg)
    else
      Fail()
    end
