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

use "buffered"
use "collections"
use "net"
use "pony-kafka"
use "pony-kafka/customlogger"
use "time"
use "wallaroo/core/barrier"
use "wallaroo/core/checkpoint"
use "wallaroo/core/common"
use "wallaroo/core/initialization"
use "wallaroo/core/invariant"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/recovery"
use "wallaroo/core/routing"
use "wallaroo/core/sink"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"
use "wallaroo_labs/time"

actor KafkaSink is (Sink & KafkaClientManager & KafkaProducer)
  // Steplike
  let _name: String
  var _phase: SinkPhase = InitialSinkPhase
  let _sink_id: RoutingId
  let _event_log: EventLog
  var _recovering: Bool
  let _encoder: KafkaEncoderWrapper
  let _wb: Writer = Writer
  let _metrics_reporter: MetricsReporter
  var _initializer: (LocalTopologyInitializer | None) = None
  let _barrier_coordinator: BarrierCoordinator
  let _checkpoint_initiator: CheckpointInitiator

  // Consumer
  var _upstreams: SetIs[Producer] = _upstreams.create()
  // _inputs keeps track of all inputs by step id. There might be
  // duplicate producers in this map (unlike upstreams) since there might be
  // multiple upstream step ids over a boundary
  let _inputs: Map[RoutingId, Producer] = _inputs.create()
  var _mute_outstanding: Bool = false

  var _kc: (KafkaClient tag | None) = None
  let _conf: KafkaConfig val
  let _auth: TCPConnectionAuth

  // variable to hold producer mapping for sending requests to broker
  //  connections
  var _kafka_producer_mapping: (KafkaProducerMapping ref | None) = None

  var _ready_to_produce: Bool = false
  var _application_initialized: Bool = false

  let _topic: String

  var _seq_id: SeqId = 0

  // Items in tuple are: metric_name, metrics_id, send_ts, worker_ingress_ts,
  //   pipeline_time_spent, tracking_id
  let _pending_delivery_report: MapIs[Any tag, (String, U16, U64, U64, U64,
    (U64 | None))] = _pending_delivery_report.create()

  new create(sink_id: RoutingId, name: String, event_log: EventLog,
    recovering: Bool, encoder_wrapper: KafkaEncoderWrapper,
    metrics_reporter: MetricsReporter iso, conf: KafkaConfig val,
    barrier_coordinator: BarrierCoordinator, checkpoint_initiator: CheckpointInitiator,
    auth: TCPConnectionAuth)
  =>
    _name = name
    _recovering = recovering
    _sink_id = sink_id
    _event_log = event_log
    _encoder = encoder_wrapper
    _metrics_reporter = consume metrics_reporter
    _conf = conf
    _barrier_coordinator = barrier_coordinator
    _checkpoint_initiator = checkpoint_initiator
    _auth = auth

    _topic = try
               _conf.topics.keys().next()?
             else
               Fail()
               ""
             end

    _phase = NormalSinkPhase(this)

  fun ref create_producer_mapping(client: KafkaClient, mapping: KafkaProducerMapping):
    (KafkaProducerMapping | None)
  =>
    _kafka_producer_mapping = mapping

  fun ref producer_mapping(client: KafkaClient): (KafkaProducerMapping | None) =>
    _kafka_producer_mapping

  be kafka_client_error(client: KafkaClient, error_report: KafkaErrorReport) =>
    @printf[I32](("ERROR: Kafka client encountered an unrecoverable error! " +
      error_report.string() + "\n").cstring())

    Fail()

  be receive_kafka_topics_partitions(client: KafkaClient, new_topic_partitions: Map[String,
    (KafkaTopicType, Set[KafkaPartitionId])] val)
  =>
    None

  be kafka_producer_ready(client: KafkaClient) =>
    _ready_to_produce = true

    // we either signal back to intializer that we're ready to work here or in
    //  application_ready_to_work depending on which one is called second.
    if _application_initialized then
      match _initializer
      | let initializer: LocalTopologyInitializer =>
        initializer.report_ready_to_work(this)
        _initializer = None
      else
        // kafka_producer_ready should never be called twice
        Fail()
      end

      if _mute_outstanding and not _recovering then
        _unmute_upstreams()
      end
    end

  be kafka_message_delivery_report(client: KafkaClient, delivery_report: KafkaProducerDeliveryReport)
  =>
    try
      if not _pending_delivery_report.contains(delivery_report.opaque) then
        @printf[I32](("Kafka Sink: Error kafka delivery report opaque doesn't"
          + " exist in _pending_delivery_report\n").cstring())
        error
      end

      (_, (let metric_name, let metrics_id, let send_ts, let worker_ingress_ts,
        let pipeline_time_spent, let tracking_id)) =
        _pending_delivery_report.remove(delivery_report.opaque)?

      if delivery_report.status isnt ErrorNone then
        @printf[I32](("Kafka Sink: Error reported in kafka delivery report: "
          + delivery_report.status.string() + "\n").cstring())
        error
      end

      let end_ts = WallClock.nanoseconds()
      _metrics_reporter.step_metric(metric_name, "Kafka send time", metrics_id,
        send_ts, end_ts)

      let final_ts = WallClock.nanoseconds()
      let time_spent = final_ts - worker_ingress_ts

      ifdef "detailed-metrics" then
        _metrics_reporter.step_metric(metric_name, "Before end at sink", 9999,
          end_ts, final_ts)
      end

      _metrics_reporter.pipeline_metric(metric_name,
        time_spent + pipeline_time_spent)
      _metrics_reporter.worker_metric(metric_name, time_spent)
    else
      // TODO: How are we supposed to handle errors?
      @printf[I32]("Error handling kafka delivery report in Kakfa Sink\n"
        .cstring())
    end

  fun inputs(): Map[RoutingId, Producer] box =>
    _inputs

  fun ref _kafka_producer_throttled(client: KafkaClient, topic_partitions_throttled: Map[String, Set[KafkaPartitionId]] val)
  =>
    if not _mute_outstanding then
      _mute_upstreams()
    end

  fun ref _kafka_producer_unthrottled(client: KafkaClient, topic_partitions_throttled: Map[String, Set[KafkaPartitionId]] val)
  =>
    if (topic_partitions_throttled.size() == 0) and _mute_outstanding then
      _unmute_upstreams()
    end

  fun ref _mute_upstreams() =>
    for u in _upstreams.values() do
      u.mute(this)
    end
    _mute_outstanding = true

  fun ref _unmute_upstreams() =>
    for u in _upstreams.values() do
      u.unmute(this)
    end
    _mute_outstanding = false

  be application_begin_reporting(initializer: LocalTopologyInitializer) =>
    _initializer = initializer
    initializer.report_created(this)

  be application_created(initializer: LocalTopologyInitializer) =>
    _mute_upstreams()

    initializer.report_initialized(this)

    // create kafka client
    let kc = KafkaClient(_auth, _conf, this)
    _kc = kc
    kc.register_producer(this)

  be application_initialized(initializer: LocalTopologyInitializer) =>
    _application_initialized = true

    if _ready_to_produce then
      initializer.report_ready_to_work(this)
      _initializer = None

      if _mute_outstanding and not _recovering then
        _unmute_upstreams()
      end
    end

  be application_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  be cluster_ready_to_work(initializer: LocalTopologyInitializer) =>
    None

  be register_producer(id: RoutingId, producer: Producer) =>
    // If we have at least one input, then we are involved in checkpointing.
    if _inputs.size() == 0 then
      _barrier_coordinator.register_sink(this)
      _checkpoint_initiator.register_sink(this)
      _event_log.register_resilient(_sink_id, this)
    end

    _inputs(id) = producer
    _upstreams.set(producer)

  be unregister_producer(id: RoutingId, producer: Producer) =>
    if _inputs.contains(id) then
      try
        _inputs.remove(id)?
      else
        Fail()
      end

      var have_input = false
      for i in _inputs.values() do
        if i is producer then have_input = true end
      end
      if not have_input then
        _upstreams.unset(producer)
      end

      // If we have no inputs, then we are not involved in checkpointing.
      if _inputs.size() == 0 then
        _barrier_coordinator.unregister_sink(this)
        _checkpoint_initiator.unregister_sink(this)
        _event_log.unregister_resilient(_sink_id, this)
      end
    end

  be report_status(code: ReportStatusCode) =>
    None

  be run[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    key: Key, event_ts: U64, watermark_ts: U64, i_producer_id: RoutingId,
    i_producer: Producer, msg_uid: MsgId, frac_ids: FractionalMessageId,
    i_seq_id: SeqId, latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    _run[D](metric_name, pipeline_time_spent,
      data, key, event_ts, watermark_ts, i_producer_id, i_producer, msg_uid,
      frac_ids, i_seq_id, latest_ts, metrics_id, worker_ingress_ts)

  fun ref _run[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    key: Key, event_ts: U64, watermark_ts: U64, i_producer_id: RoutingId,
    i_producer: Producer, msg_uid: MsgId, frac_ids: FractionalMessageId,
    i_seq_id: SeqId, latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    _phase.process_message[D](metric_name, pipeline_time_spent,
      data, key, event_ts, watermark_ts, i_producer_id, i_producer, msg_uid,
      frac_ids, i_seq_id, latest_ts, metrics_id, worker_ingress_ts)

  fun ref process_message[D: Any val](metric_name: String,
    pipeline_time_spent: U64, data: D, key: Key, event_ts: U64,
    watermark_ts: U64, i_producer_id: RoutingId, i_producer: Producer,
    msg_uid: MsgId, frac_ids: FractionalMessageId, i_seq_id: SeqId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    var my_latest_ts: U64 = latest_ts
    var my_metrics_id = ifdef "detailed-metrics" then
      my_latest_ts = WallClock.nanoseconds()
      _metrics_reporter.step_metric(metric_name, "Before receive at sink",
        metrics_id, latest_ts, my_latest_ts)
        metrics_id + 1
      else
        metrics_id
      end

    ifdef "trace" then
      @printf[I32]("Rcvd msg at KafkaSink\n".cstring())
    end
    try
      (let encoded_value, let encoded_key, let part_id) =
        _encoder.encode[D](data, _wb)?
      my_metrics_id = ifdef "detailed-metrics" then
          var old_ts = my_latest_ts = WallClock.nanoseconds()
          _metrics_reporter.step_metric(metric_name, "Sink encoding time",
            9998, old_ts, my_latest_ts)
          metrics_id + 1
        else
          metrics_id
        end

      try
        // `any` is required because if `data` is used directly, there are
        // issues with the items not being found in `_pending_delivery_report`.
        // This is mainly when `data` is a primitive where it will get automagically
        // boxed on message send and the `tag` for that boxed version of the primitive
        // will not match the when checked against the `_pending_delivery_report` map.
        let any: Any tag = data
        let ret = (_kafka_producer_mapping as KafkaProducerMapping ref)
          .send_topic_message(_topic, any, encoded_value, encoded_key where partition_id = part_id)

        // TODO: Proper error handling
        if ret isnt None then error end

        // TODO: Resilience: Write data to event log for recovery purposes

        let next_tracking_id = (_seq_id = _seq_id + 1)
        _pending_delivery_report(any) = (metric_name, my_metrics_id,
          my_latest_ts, worker_ingress_ts, pipeline_time_spent,
          next_tracking_id)
      else
        // TODO: How are we supposed to handle errors?
        @printf[I32]("Error sending message to Kafka via Kakfa Sink\n"
          .cstring())
      end

    else
      Fail()
    end

  ///////////////
  // BARRIER
  ///////////////
  be receive_barrier(input_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    process_barrier(input_id, producer, barrier_token)

  fun ref receive_new_barrier(input_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    _phase = BarrierSinkPhase(_sink_id, this, barrier_token)
    _phase.receive_barrier(input_id, producer,
      barrier_token)

  fun ref process_barrier(input_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    match barrier_token
    | let srt: CheckpointRollbackBarrierToken =>
      _phase.prepare_for_rollback(barrier_token)
    end

    _phase.receive_barrier(input_id, producer,
      barrier_token)

  fun ref barrier_complete(barrier_token: BarrierToken) =>
    _barrier_coordinator.ack_barrier(this, barrier_token)
    match barrier_token
    | let sbt: CheckpointBarrierToken =>
      checkpoint_state(sbt.id)
    end
    let queued = _phase.queued()
    _phase = NormalSinkPhase(this)
    for q in queued.values() do
      match q
      | let qm: QueuedMessage =>
        qm.run(this)
      | let qb: QueuedBarrier =>
        qb.inject_barrier(this)
      end
    end

  be checkpoint_complete(checkpoint_id: CheckpointId) =>
    None

  ///////////////
  // CHECKPOINTS
  ///////////////
  fun ref checkpoint_state(checkpoint_id: CheckpointId) =>
    """
    KafkaSinks don't currently write out any data as part of the checkpoint.
    """
    _event_log.checkpoint_state(_sink_id, checkpoint_id,
      recover val Array[ByteSeq] end)

  be prepare_for_rollback() =>
    finish_preparing_for_rollback(None)

  fun ref finish_preparing_for_rollback(token: (BarrierToken | None)) =>
    _phase = NormalSinkPhase(this)

  be rollback(payload: ByteSeq val, event_log: EventLog,
    checkpoint_id: CheckpointId)
  =>
    """
    There is currently nothing for a KafkaSink to rollback to.
    """
    event_log.ack_rollback(_sink_id)


  be dispose() =>
    @printf[I32]("Shutting down KafkaSink\n".cstring())
    try
      (_kc as KafkaClient tag).dispose()
    end
