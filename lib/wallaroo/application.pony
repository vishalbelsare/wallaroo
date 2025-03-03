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
use "net"
use "wallaroo/core/common"
use "wallaroo/core/partitioning"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/sink"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/source/tcp_source"
use "wallaroo/core/state"
use "wallaroo/core/routing"
use "wallaroo/core/topology"
use "wallaroo/core/windows"
use "wallaroo/core/network"
use "wallaroo/core/recovery"
use "wallaroo_labs/collection_helpers"
use "wallaroo_labs/dag"
use "wallaroo_labs/mort"

primitive Wallaroo
  fun source[In: Any val](source_name: String,
    source_config: TypedSourceConfig[In]): Pipeline[In]
  =>
    Pipeline[In].from_source(source_name, source_config)

  fun build_application(env: Env, app_name: String,
    pipeline: BasicPipeline val)
  =>
    if pipeline.is_finished() then
      Startup(env, app_name, pipeline)
    else
      FatalUserError("A pipeline must terminate in a sink!")
    end

  fun range_windows(range: U64): RangeWindowsBuilder =>
    RangeWindowsBuilder(where range = range)

  fun ephemeral_windows(trigger_range: U64, post_trigger_range: U64):
    EphemeralWindowsBuilder
  =>
    EphemeralWindowsBuilder(trigger_range, post_trigger_range)

  fun count_windows(count: USize): CountWindowsBuilder =>
    CountWindowsBuilder(where count = count)

trait BasicPipeline
  fun graph(): this->Dag[LogicalStage]
  fun is_finished(): Bool
  fun size(): USize
  fun worker_source_configs(): this->Map[SourceName, WorkerSourceConfig]

type LogicalStage is (RunnerBuilder | SinkBuilder | Array[SinkBuilder] val |
  SourceConfigWrapper | RandomPartitionerBuilder | KeyPartitionerBuilder)

class Pipeline[Out: Any val] is BasicPipeline
  let _stages: Dag[LogicalStage]
  let _dag_sink_ids: Array[RoutingId]
  var _worker_source_configs: Map[SourceName, WorkerSourceConfig] =
    _worker_source_configs.create()
  var _finished: Bool

  var _last_is_shuffle: Bool
  var _last_is_key_by: Bool
  // A local_key_by call means we keep using worker-local routing until we
  // come to collect() or key_by()
  var _local_routing: Bool

  new from_source(n: String, source_config: TypedSourceConfig[Out]) =>
    _stages = Dag[LogicalStage]
    _dag_sink_ids = Array[RoutingId]
    _finished = false
    _last_is_shuffle = false
    _last_is_key_by = false
    _local_routing = false
    let sc_wrapper = SourceConfigWrapper(n, source_config)
    let source_id' = _stages.add_node(sc_wrapper)
    _dag_sink_ids.push(source_id')
    _worker_source_configs.update(sc_wrapper.name(),
      source_config.worker_source_config())

  new create(stages: Dag[LogicalStage] = Dag[LogicalStage],
    dag_sink_ids: Array[RoutingId] = Array[RoutingId],
    worker_source_configs': Map[SourceName, WorkerSourceConfig],
    local_routing: Bool,
    finished: Bool = false,
    last_is_shuffle: Bool = false,
    last_is_key_by: Bool = false)
  =>
    _stages = stages
    _dag_sink_ids = dag_sink_ids
    _worker_source_configs = worker_source_configs'
    _finished = finished
    _last_is_shuffle = last_is_shuffle
    _last_is_key_by = last_is_key_by
    _local_routing = local_routing

  fun is_finished(): Bool => _finished

  fun ref merge[MergeOut: Any val](pipeline: Pipeline[MergeOut]):
    Pipeline[(Out | MergeOut)]
  =>
    if _finished then
      _try_merge_with_finished_pipeline()
    elseif (_last_is_shuffle and not pipeline._last_is_shuffle) or
      (not _last_is_shuffle and pipeline._last_is_shuffle)
    then
      _only_one_is_shuffle()
    elseif (_last_is_key_by and not pipeline._last_is_key_by) or
      (not _last_is_key_by and pipeline._last_is_key_by)
    then
      _only_one_is_key_by()
    else
      // Successful merge
      try
        _stages.merge(pipeline._stages)?
        _worker_source_configs.concat(pipeline.worker_source_configs().pairs())
      else
        // We should have ruled this out through the if branches
        Unreachable()
      end
      _dag_sink_ids.append(pipeline._dag_sink_ids)
      return Pipeline[(Out | MergeOut)](_stages, _dag_sink_ids,
        _worker_source_configs where local_routing = _local_routing,
        last_is_shuffle = _last_is_shuffle,
        last_is_key_by = _last_is_key_by)
    end
    Pipeline[(Out | MergeOut)](_stages, _dag_sink_ids, _worker_source_configs
      where local_routing = _local_routing)

  fun ref to[Next: Any val](comp: Computation[Out, Next],
    parallelism: USize = 10): Pipeline[Next]
  =>
    let node_id = RoutingIdGenerator()
    if not _finished then
      let runner_builder = comp.runner_builder(node_id, parallelism,
        _local_routing)
      _stages.add_node(runner_builder, node_id)
      try
        for sink_id in _dag_sink_ids.values() do
          _stages.add_edge(sink_id, node_id)?
        end
      else
        Fail()
      end
      Pipeline[Next](_stages, [node_id], _worker_source_configs
        where local_routing = _local_routing)
    else
      _try_add_to_finished_pipeline()
      Pipeline[Next](_stages, _dag_sink_ids, _worker_source_configs
        where local_routing = _local_routing)
    end

  fun ref to_sink(sink_information: SinkConfig[Out],
    parallelism: USize = 1): Pipeline[Out]
  =>
    if not _finished then
      let sink_builder = sink_information(parallelism)
      let node_id = _stages.add_node(sink_builder)
      try
        for dag_sink_id in _dag_sink_ids.values() do
          _stages.add_edge(dag_sink_id, node_id)?
        end
      else
        Fail()
      end
      Pipeline[Out](_stages, [node_id], _worker_source_configs
        where local_routing = _local_routing, finished = true)
    else
      _try_add_to_finished_pipeline()
      Pipeline[Out](_stages, _dag_sink_ids, _worker_source_configs
        where local_routing = _local_routing)
    end

  fun ref to_sinks(sink_configs: Array[SinkConfig[Out]] box,
    parallelism: USize = 1): Pipeline[Out]
  =>
    if not _finished then
      if sink_configs.size() == 0 then
        FatalUserError("You must specify at least one sink when using " +
          "to_sinks()")
      end
      let sink_bs = recover iso Array[SinkBuilder] end
      for config in sink_configs.values() do
        sink_bs.push(config(parallelism))
      end
      let node_id = _stages.add_node(consume sink_bs)
      try
        for dag_sink_id in _dag_sink_ids.values() do
          _stages.add_edge(dag_sink_id, node_id)?
        end
      else
        Fail()
      end
      Pipeline[Out](_stages, [node_id], _worker_source_configs
        where local_routing = _local_routing, finished = true)
    else
      _try_add_to_finished_pipeline()
      Pipeline[Out](_stages, _dag_sink_ids, _worker_source_configs
        where local_routing = _local_routing)
    end

  fun ref key_by(pf: KeyExtractor[Out], local_routing: Bool = false):
    Pipeline[Out]
  =>
    if not _finished then
      let node_id = _stages.add_node(TypedKeyPartitionerBuilder[Out](pf))
      try
        for sink_id in _dag_sink_ids.values() do
          _stages.add_edge(sink_id, node_id)?
        end
      else
        Fail()
      end
      Pipeline[Out](_stages, [node_id], _worker_source_configs
        where local_routing = local_routing, last_is_key_by = true)
    else
      _try_add_to_finished_pipeline()
      Pipeline[Out](_stages, _dag_sink_ids, _worker_source_configs
        where local_routing = local_routing)
    end

  // local_key_by indicates that all messages will be routed to steps on the
  // same worker. This will apply to all stages following a local_key_by that
  // come before a subsequent key_by() or collect(). Worker local routing
  // allows applications to reduce network traffic by performing local
  // pre-aggregations before sending the results of these pre-aggregations
  // downstream to a final aggregation.
  fun ref local_key_by(pf: KeyExtractor[Out]): Pipeline[Out] =>
    key_by(pf where local_routing = true)

  fun ref collect(local_routing: Bool = false): Pipeline[Out] =>
    let collect_key = CollectKeyGenerator()
    key_by(CollectKeyExtractor[Out](collect_key)
      where local_routing = local_routing)

  fun ref local_collect(): Pipeline[Out] =>
    collect(where local_routing = true)

  fun graph(): this->Dag[LogicalStage] => _stages

  fun worker_source_configs(): this->Map[SourceName, WorkerSourceConfig] =>
    _worker_source_configs

  fun size(): USize => _stages.size()

  fun _try_add_to_finished_pipeline() =>
    FatalUserError("You can't add further stages after a sink!")

  fun _try_merge_with_finished_pipeline() =>
    FatalUserError("You can't merge with a terminated pipeline!")

  fun _only_one_is_shuffle() =>
    FatalUserError(
      "A pipeline ending with shuffle can only be merged with another!")

  fun _only_one_is_key_by() =>
    FatalUserError(
      "A pipeline ending with key_by can only be merged with another!")
