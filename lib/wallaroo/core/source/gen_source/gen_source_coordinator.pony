
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

use "buffered"
use "collections"
use "crypto"
use "wallaroo/core/barrier"
use "wallaroo/core/boundary"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/partitioning"
use "wallaroo/core/recovery"
use "wallaroo/core/registries"
use "wallaroo/core/routing"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"


interface _Sourcey
  fun ref source(layout_initializer: LayoutInitializer,
    router_registry: RouterRegistry,
    outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val):
    Source

actor GenSourceCoordinator[In: Any val] is SourceCoordinator
  """
  # GenSourceCoordinator
  """
  let _routing_id_gen: RoutingIdGenerator = RoutingIdGenerator
  let _generator: GenSourceGeneratorBuilder[In]

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
  let _recovering: Bool
  let _target_router: Router

  let _sources: Array[GenSource[In]] = _sources.create()

  new create(env: Env, worker_name: WorkerName, pipeline_name: String,
    runner_builder: RunnerBuilder, partitioner_builder: PartitionerBuilder,
    router: Router, metrics_conn: MetricsSink,
    metrics_reporter: MetricsReporter iso, router_registry: RouterRegistry,
    outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val,
    event_log: EventLog, auth: AmbientAuth,
    layout_initializer: LayoutInitializer,
    recovering: Bool, target_router: Router,
    generator: GenSourceGeneratorBuilder[In])
  =>
    _env = env

    _worker_name = worker_name
    _pipeline_name = pipeline_name
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
    _recovering = recovering
    _target_router = target_router
    _generator = generator

    match router
    | let pr: StatePartitionRouter =>
      _router_registry.register_partition_router_subscriber(pr.step_group(),
        this)
    | let spr: StatelessPartitionRouter =>
      _router_registry.register_stateless_partition_router_subscriber(
        spr.partition_routing_id(), this)
    end

    _create_source()

  fun ref _create_source() =>
    let name = _worker_name + ":" + _pipeline_name + " source"
    ifdef debug then
      @printf[I32]("Created GenSource: %s\n".cstring(), name.cstring())
    end
    let temp_id = MD5(name)
    let rb = Reader
    rb.append(temp_id)

    let source_id = try rb.u128_le()? else Fail(); 0 end

    let runner = _runner_builder(_router_registry, _event_log, _auth,
      _metrics_reporter.clone(), None, _target_router, _partitioner_builder)

    // It's possible that there are more than one sink per worker for this
    // pipeline. We select our router based on our source id.
    let selected_router = _router.select_based_on_producer_id(source_id)
    let source = GenSource[In](source_id, _auth, _pipeline_name,
      consume runner, selected_router, _generator, _event_log,
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
    _sources.push(source)

  fun ref _start_sources() =>
    for s in _sources.values() do
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
    @printf[I32]("Shutting down GenSourceCoordinator\n".cstring())

  be add_worker(worker: WorkerName) =>
    None

  be remove_worker(worker: WorkerName) =>
    None

  be receive_msg(msg: SourceCoordinatorMsg) =>
    None

  // Application startup lifecycle events
  be application_begin_reporting(initializer: LocalTopologyInitializer) =>
    initializer.report_created(this)

  be application_created(initializer: LocalTopologyInitializer) =>
    initializer.report_initialized(this)

  be application_initialized(initializer: LocalTopologyInitializer) =>
    initializer.report_ready_to_work(this)

  be application_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  be cluster_ready_to_work(initializer: LocalTopologyInitializer) =>
    ifdef not "resilience" then
      // If we are building with resilience, then we can't start our sources
      // until the first checkpoint is complete.
      _start_sources()
    end

  //////////////
  // BARRIER
  //////////////
  be initiate_barrier(token: BarrierToken) =>
    for s in _sources.values() do
      s.initiate_barrier(token)
    end

  be checkpoint_complete(checkpoint_id: CheckpointId) =>
    for s in _sources.values() do
      s.checkpoint_complete(checkpoint_id)
    end
    if checkpoint_id == 1 then
      for s in _sources.values() do
        s.first_checkpoint_complete()
      end
      _start_sources()
    end

  //////////////
  // AUTOSCALE
  /////////////
  be begin_grow_migration(joining_workers: Array[WorkerName] val) =>
    _router_registry.source_coordinator_migration_complete(this)

  be begin_shrink_migration(leaving_workers: Array[WorkerName] val) =>
    _router_registry.source_coordinator_migration_complete(this)

