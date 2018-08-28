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

use "collections"
use "ponytest"
use "wallaroo_labs/equality"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/core/source"
use "wallaroo/ent/barrier"
use "wallaroo/ent/data_receiver"
use "wallaroo/ent/in_flight_acking"
use "wallaroo/ent/network"
use "wallaroo/ent/recovery"
use "wallaroo/ent/router_registry"
use "wallaroo/ent/snapshot"
use "wallaroo/core/metrics"
use "wallaroo/core/routing"
use "wallaroo/core/state"

actor _TestRouterEquality is TestList
  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    test(_TestTargetIdRouterEquality)
    test(_TestDataRouterEqualityAfterRemove)
    test(_TestDataRouterEqualityAfterAdd)
    test(_TestLatestAfterNew)
    test(_TestLatestWithoutNew)

class iso _TestTargetIdRouterEquality is UnitTest
  """
  Test that updating TargetIdRouter creates the expected changes

  Move step id 1 from worker w1 to worker w2.
  Move step id 2 from worker w2 to worker w1 (and point to step2)
  Add new boundary to worker 3
  """
  fun name(): String =>
    "topology/TargetIdRouterEquality"

  fun ref apply(h: TestHelper) ? =>
    let auth = h.env.root as AmbientAuth
    let event_log = EventLog()
    let recovery_replayer = _RecoveryReplayerGenerator(h.env, auth)

    let step1 = _StepGenerator(auth, event_log, recovery_replayer)
    let step2 = _StepGenerator(auth, event_log, recovery_replayer)

    let boundary2 = _BoundaryGenerator("w1", auth)
    let boundary3 = _BoundaryGenerator("w1", auth)

    let target_workers = recover val ["w2"; "w3"] end

    let base_data_routes = recover trn Map[U128, Consumer] end
    base_data_routes(1) = step1

    let target_data_routes = recover trn Map[U128, Consumer] end
    target_data_routes(2) = step2

    let base_step_map = recover trn Map[U128, ProxyAddress] end
    base_step_map(1) = ProxyAddress("w1", 1)
    base_step_map(2) = ProxyAddress("w2", 2)

    let target_step_map = recover trn Map[U128, ProxyAddress] end
    target_step_map(1) = ProxyAddress("w2", 1)
    target_step_map(2) = ProxyAddress("w1", 2)

    let base_boundaries = recover trn Map[String, OutgoingBoundary] end
    base_boundaries("w2") = boundary2

    let target_boundaries = recover trn Map[String, OutgoingBoundary] end
    target_boundaries("w2") = boundary2
    target_boundaries("w3") = boundary3

    let base_stateless_partitions =
      recover trn Map[U128, StatelessPartitionRouter] end
    base_stateless_partitions(1) = _StatelessPartitionGenerator()
    base_stateless_partitions(2) = _StatelessPartitionGenerator()

    let target_stateless_partitions =
      recover trn Map[U128, StatelessPartitionRouter] end
    target_stateless_partitions(1) = _StatelessPartitionGenerator()
    target_stateless_partitions(2) = _StatelessPartitionGenerator()

    var base_router: TargetIdRouter = StateStepRouter("w1",
      consume base_data_routes, consume base_step_map,
      consume base_boundaries, consume base_stateless_partitions,
      target_workers)

    let target_router: TargetIdRouter = StateStepRouter("w1",
      consume target_data_routes, consume target_step_map,
      consume target_boundaries, consume target_stateless_partitions,
      target_workers)

    h.assert_eq[Bool](false, base_router == target_router)

    base_router = base_router.update_route_to_proxy(1, "w2")
    base_router = base_router.update_route_to_consumer(2, step2)

    h.assert_eq[Bool](true, base_router == target_router)

class iso _TestDataRouterEqualityAfterRemove is UnitTest
  """
  Test that updating DataRouter creates the expected changes

  Remove route to step id 2
  """
  fun name(): String =>
    "topology/DataRouterEqualityAfterRemove"

  fun ref apply(h: TestHelper) ? =>
    let auth = h.env.root as AmbientAuth
    let event_log = EventLog()
    let recovery_replayer = _RecoveryReplayerGenerator(h.env, auth)

    let step1 = _StepGenerator(auth, event_log, recovery_replayer)
    let step2 = _StepGenerator(auth, event_log, recovery_replayer)

    let base_routes = recover trn Map[U128, Consumer] end
    base_routes(1) = step1
    base_routes(2) = step2

    let base_partitions = recover val
      LocalStatePartitions
        .>add("state", "key1", step1)
        .>add("state", "key2", step2)
    end

    let base_partition_ids = recover val
      LocalStatePartitionIds
        .>add("state", "key1", 1)
        .>add("state", "key2", 2)
    end

    let target_routes = recover trn Map[U128, Consumer] end
    target_routes(1) = step1

    let target_partitions = recover val
      LocalStatePartitions
        .>add("state", "key1", step1)
    end

    let target_partition_ids = recover val
      LocalStatePartitionIds
        .>add("state", "key1", 1)
    end

    var base_router = DataRouter(consume base_routes, base_partitions,
      base_partition_ids)

    let target_router = DataRouter(consume target_routes, target_partitions,
      target_partition_ids)

    h.assert_eq[Bool](false, base_router == target_router)

    base_router = base_router.remove_keyed_route("state", "key2")

    h.assert_eq[Bool](true, base_router == target_router)

class iso _TestDataRouterEqualityAfterAdd is UnitTest
  """
  Test that updating DataRouter creates the expected changes

  Add route to step id 3
  """
  fun name(): String =>
    "topology/_TestDataRouterEqualityAfterAdd"

  fun ref apply(h: TestHelper) ? =>
    let auth = h.env.root as AmbientAuth
    let event_log = EventLog()
    let recovery_replayer = _RecoveryReplayerGenerator(h.env, auth)

    let step1 = _StepGenerator(auth, event_log, recovery_replayer)
    let step2 = _StepGenerator(auth, event_log, recovery_replayer)

    let base_routes = recover trn Map[U128, Consumer] end
    base_routes(1) = step1

    let target_routes = recover trn Map[U128, Consumer] end
    target_routes(1) = step1
    target_routes(2) = step2

    let base_keyed_routes = recover val LocalStatePartitions end

    var base_router = DataRouter(consume base_routes, base_keyed_routes,
      recover LocalStatePartitionIds end)
    let target_router = DataRouter(consume target_routes, base_keyed_routes,
      recover LocalStatePartitionIds end)

    h.assert_eq[Bool](false, base_router == target_router)

    base_router = base_router.add_keyed_route(2, "StateName", "Key", step2)

    h.assert_eq[Bool](true, base_router == target_router)

primitive _LocalMapGenerator
  fun apply(): Map[U128, Step] val =>
    recover Map[U128, Step] end

primitive _StepIdsGenerator
  fun apply(): Map[String, U128] val =>
    recover Map[String, U128] end

primitive _PartitionFunctionGenerator
  fun apply(): PartitionFunction[String] val =>
    {(s: String): String => s}

primitive _StepGenerator
  fun apply(auth: AmbientAuth, event_log: EventLog,
    recovery_replayer: RecoveryReplayer): Step
  =>
    Step(auth, RouterRunner, MetricsReporter("", "", _NullMetricsSink),
      1, event_log, recovery_replayer,
      recover Map[String, OutgoingBoundary] end,
      _StateStepCreatorGenerator(auth))

primitive _BoundaryGenerator
  fun apply(worker_name: String, auth: AmbientAuth): OutgoingBoundary =>
    OutgoingBoundary(auth, worker_name, "",
      MetricsReporter("", "", _NullMetricsSink), "", "")

primitive _RouterRegistryGenerator
  fun apply(env: Env, auth: AmbientAuth): RouterRegistry =>
    RouterRegistry(auth, "", _DataReceiversGenerator(env, auth),
      _ConnectionsGenerator(env, auth), _StateStepCreatorGenerator(auth),
      _DummyRecoveryFileCleaner, 0,
      false, _BarrierInitiatorGenerator(env, auth),
      _SnapshotInitiatorGenerator(env, auth),
      _InFlightAckInitiatorGenerator(env, auth))

primitive _BarrierInitiatorGenerator
  fun apply(env: Env, auth: AmbientAuth): BarrierInitiator =>
    BarrierInitiator(auth, "w", _ConnectionsGenerator(env, auth))

primitive _InFlightAckInitiatorGenerator
  fun apply(env: Env, auth: AmbientAuth): InFlightAckInitiator =>
    InFlightAckInitiator("w", _BarrierInitiatorGenerator(env, auth))

primitive _SnapshotInitiatorGenerator
  fun apply(env: Env, auth: AmbientAuth): SnapshotInitiator =>
    SnapshotInitiator(_ConnectionsGenerator(env, auth), 1, false)

primitive _DataReceiversGenerator
  fun apply(env: Env, auth: AmbientAuth): DataReceivers =>
    DataReceivers(auth, _ConnectionsGenerator(env, auth), "",
      _StateStepCreatorGenerator(auth))

primitive _ConnectionsGenerator
  fun apply(env: Env, auth: AmbientAuth): Connections =>
    Connections("", "", auth, "", "", "", "",
      _NullMetricsSink, "", "", false, "", false
      where event_log = EventLog())

primitive _RecoveryReplayerGenerator
  fun apply(env: Env, auth: AmbientAuth): RecoveryReplayer =>
    RecoveryReplayer(auth, "", _DataReceiversGenerator(env, auth),
      _RouterRegistryGenerator(env, auth), _Cluster)

primitive _StatelessPartitionGenerator
  fun apply(): StatelessPartitionRouter =>
    LocalStatelessPartitionRouter(0, "", recover Map[U64, U128] end,
      recover Map[U64, (Step | ProxyRouter)] end, 1)

primitive _StateStepCreatorGenerator
  fun apply(auth: AmbientAuth): StateStepCreator =>
    StateStepCreator(auth, "app", "worker", _NullMetricsSink, EventLog())

actor _Cluster is Cluster
  be notify_cluster_of_new_stateful_step(id: StepId, key: Key,
    state_name: String, exclusions: Array[String] val =
    recover Array[String] end)
  =>
    None

actor _NullMetricsSink
  be send_metrics(metrics: MetricDataList val) =>
    None

  fun ref set_nodelay(state: Bool) =>
    None

  be writev(data: ByteSeqIter) =>
    None

  be dispose() =>
    None

actor _DummyRecoveryFileCleaner
  be clean_recovery_files() =>
    None
