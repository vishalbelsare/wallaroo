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
use "wallaroo/ent/network"
use "wallaroo/ent/recovery"
use "wallaroo_labs/mort"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/sink"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/source/tcp_source"
use "wallaroo/core/state"
use "wallaroo/core/routing"
use "wallaroo/core/topology"
use "wallaroo_labs/collection_helpers"

class Application
  let _name: String
  let pipelines: Array[BasicPipeline] = Array[BasicPipeline]
  // _state_builders maps from state_name to StateSubpartitions
  let _state_builders: Map[String, PartitionsBuilder] = _state_builders.create()
  var sink_count: USize = 0

  new create(name': String) =>
    _name = name'

  fun ref new_pipeline[In: Any val, Out: Any val] (pipeline_name: String,
    source_config: SourceConfig[In]): PipelineBuilder[In, Out, In]
  =>
    // We have removed the ability to turn coalescing off at the command line.
    let coalescing = true
    let pipeline_id = pipelines.size()
    let pipeline = Pipeline[In, Out](_name, pipeline_id, pipeline_name,
      source_config, coalescing)
    PipelineBuilder[In, Out, In](this, pipeline)

  fun ref add_pipeline(p: BasicPipeline) =>
    pipelines.push(p)

  fun ref add_state_builder(state_name: String,
    state_partition: PartitionsBuilder)
  =>
    _state_builders(state_name) = state_partition

  fun ref increment_sink_count() =>
    sink_count = sink_count + 1

  fun state_builder(state_name: String): PartitionsBuilder ? =>
    _state_builders(state_name)?

  fun state_builders(): Map[String, PartitionsBuilder] val =>
    let builders = recover trn Map[String, PartitionsBuilder] end
    for (k, v) in _state_builders.pairs() do
      builders(k) = v
    end
    consume builders

  fun name(): String => _name

  // Returns a String with an error message if this application fails this
  // validation test
  fun validate(): (String | None) =>
    if pipelines.size() == 0 then
      "You must provide at least 1 pipeline in an application. Did you " +
        "forget to close out a pipeline?"
    else
      None
    end

trait BasicPipeline
  fun name(): String
  fun source_id(): USize
  fun source_builder(): SourceBuilderBuilder ?
  fun source_listener_builder_builder(): SourceListenerBuilderBuilder
  fun val sink_builders(): Array[SinkBuilder] val
  fun val sink_ids(): Array[RoutingId] val
  fun is_coalesced(): Bool
  fun apply(i: USize): RunnerBuilder ?
  fun size(): USize

class Pipeline[In: Any val, Out: Any val] is BasicPipeline
  let _pipeline_id: USize
  let _name: String
  let _app_name: String
  let _runner_builders: Array[RunnerBuilder]
  var _source_builder: (SourceBuilderBuilder | None) = None
  let _source_listener_builder_builder: SourceListenerBuilderBuilder
  var _sink_builders: Array[SinkBuilder] = Array[SinkBuilder]

  var _sink_ids: Array[RoutingId] = Array[RoutingId]
  let _is_coalesced: Bool

  new create(app_name: String, p_id: USize, n: String,
    sc: SourceConfig[In], coalescing: Bool)
  =>
    _pipeline_id = p_id
    _runner_builders = Array[RunnerBuilder]
    _name = n
    _app_name = app_name
    _is_coalesced = coalescing
    _source_listener_builder_builder = sc.source_listener_builder_builder()
    _source_builder = sc.source_builder(_app_name, _name)

  fun ref add_runner_builder(p: RunnerBuilder) =>
    _runner_builders.push(p)

  fun apply(i: USize): RunnerBuilder ? => _runner_builders(i)?

  fun ref add_sink(sink_builder: SinkBuilder) =>
    _sink_builders.push(sink_builder)
    _add_sink_id()

  fun source_id(): USize => _pipeline_id

  fun source_builder(): SourceBuilderBuilder ? =>
    _source_builder as SourceBuilderBuilder

  fun source_listener_builder_builder(): SourceListenerBuilderBuilder =>
    _source_listener_builder_builder

  fun val sink_builders(): Array[SinkBuilder] val => _sink_builders

  fun val sink_ids(): Array[RoutingId] val => _sink_ids

  fun ref _add_sink_id() =>
    _sink_ids.push(RoutingIdGenerator())

  fun is_coalesced(): Bool => _is_coalesced

  fun size(): USize => _runner_builders.size()

  fun name(): String => _name

class PipelineBuilder[In: Any val, Out: Any val, Last: Any val]
  let _a: Application
  let _p: Pipeline[In, Out]
  let _pipeline_state_names: Array[String] = _pipeline_state_names.create()

  new create(a: Application, p: Pipeline[In, Out]) =>
    _a = a
    _p = p

  fun ref to[Next: Any val](
    comp_builder: ComputationBuilder[Last, Next],
    id: U128 = 0): PipelineBuilder[In, Out, Next]
  =>
    let next_builder = ComputationRunnerBuilder[Last, Next](comp_builder)
    _p.add_runner_builder(next_builder)
    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_parallel[Next: Any val](
    comp_builder: ComputationBuilder[Last, Next],
    id: U128 = 0): PipelineBuilder[In, Out, Next]
  =>
    let next_builder = ComputationRunnerBuilder[Last, Next](
      comp_builder where parallelized' = true)
    _p.add_runner_builder(next_builder)
    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_stateful[Next: Any val, S: State ref](
    s_comp: StateComputation[Last, Next, S] val,
    s_initializer: StateBuilder[S],
    state_name: String): PipelineBuilder[In, Out, Next]
  =>
    if ArrayHelpers[String].contains[String](_pipeline_state_names, state_name)
    then
      FatalUserError("Wallaroo does not currently support application " +
        "cycles. You cannot use the same state name twice in the same " +
        "pipeline.")
    end
    _pipeline_state_names.push(state_name)

    // TODO: This is a shortcut. Non-partitioned state is being treated as a
    // special case of partitioned state with one partition. This works but is
    // a bit confusing when reading the code.
    let routing_id_gen = RoutingIdGenerator
    let single_step_partition = Partitions[Last](
      SingleStepPartitionFunction[Last], recover ["key"] end)
    let step_id_map = recover trn Map[Key, RoutingId] end

    step_id_map("key") = routing_id_gen()

    let next_builder = PreStateRunnerBuilder[Last, Next, Last, S](
      s_comp, state_name, SingleStepPartitionFunction[Last])

    _p.add_runner_builder(next_builder)

    let state_builder = PartitionedStateRunnerBuilder[Last, S](_p.name(),
      state_name, consume step_id_map, single_step_partition,
      StateRunnerBuilder[S](s_initializer, state_name,
        s_comp.state_change_builders()))

    _a.add_state_builder(state_name, state_builder)

    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_state_partition[PIn: Any val, Next: Any val = PIn,
    S: State ref](
      s_comp: StateComputation[Last, Next, S] val,
      s_initializer: StateBuilder[S],
      state_name: String,
      partition: Partitions[PIn],
      multi_worker: Bool = false): PipelineBuilder[In, Out, Next]
  =>
    if ArrayHelpers[String].contains[String](_pipeline_state_names, state_name)
    then
      FatalUserError("Wallaroo does not currently support application " +
        "cycles. You cannot use the same state name twice in the same " +
        "pipeline.")
    end
    _pipeline_state_names.push(state_name)

    let routing_id_gen = RoutingIdGenerator
    let step_id_map = recover trn Map[Key, U128] end

    for key in partition.keys().values() do
      step_id_map(key) = routing_id_gen()
    end

    let next_builder = PreStateRunnerBuilder[Last, Next, PIn, S](
      s_comp, state_name, partition.function()
      where multi_worker = multi_worker)

    _p.add_runner_builder(next_builder)

    let state_builder = PartitionedStateRunnerBuilder[PIn, S](_p.name(),
      state_name, consume step_id_map, partition,
      StateRunnerBuilder[S](s_initializer, state_name,
        s_comp.state_change_builders())
      where multi_worker = multi_worker)

    _a.add_state_builder(state_name, state_builder)

    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref done(): Application =>
    _a.add_pipeline(_p)
    _a

  fun ref to_sink(sink_information: SinkConfig[Out]): Application =>
    let sink_builder = sink_information()
    _a.increment_sink_count()
    _p.add_sink(sink_builder)
    _a.add_pipeline(_p)
    _a

  fun ref to_sinks(sink_configs: Array[SinkConfig[Out]] box): Application =>
    if sink_configs.size() == 0 then
      FatalUserError("You must specify at least one sink when using " +
        "to_sinks()")
    end
    for config in sink_configs.values() do
      let sink_builder = config()
      _a.increment_sink_count()
      _p.add_sink(sink_builder)
    end
    _a.add_pipeline(_p)
    _a
