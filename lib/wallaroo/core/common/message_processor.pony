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

use "wallaroo_labs/mort"
use "wallaroo/core/invariant"
use "wallaroo/core/topology"

trait StepMessageProcessor
  fun ref run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)

  fun ref ack_snapshot(s: Snapshottable, s_id: SnapshotId) =>
    Fail()

  fun ref flush(omni_router: OmniRouter)

class EmptyStepMessageProcessor is StepMessageProcessor
  fun ref run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    Fail()

  fun ref flush(omni_router: OmniRouter) =>
    Fail()

class NormalStepMessageProcessor is StepMessageProcessor
  let step: Step ref

  new create(s: Step ref) =>
    step = s

  fun ref run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    step.process_message[D](metric_name, pipeline_time_spent, data,
      i_producer_id, i_producer, msg_uid, frac_ids, i_seq_id, i_route_id,
      latest_ts, metrics_id, worker_ingress_ts)

  fun ref flush(omni_router: OmniRouter) =>
    ifdef debug then
      @printf[I32]("Flushing NormalStepMessageProcessor does nothing.\n"
        .cstring())
    end
    None

class QueueingStepMessageProcessor is StepMessageProcessor
  let step: Step ref
  var messages: Array[QueuedStepMessage] = messages.create()

  new create(s: Step ref, messages': Array[QueuedStepMessage] val =
    recover Array[QueuedStepMessage] end)
  =>
    step = s
    for m in messages'.values() do
      messages.push(m)
    end

  fun ref run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    let msg = TypedQueuedStepMessage[D](metric_name, pipeline_time_spent, data,
      i_producer_id, msg_uid, frac_ids, i_seq_id, i_route_id, latest_ts,
      metrics_id, worker_ingress_ts)
    messages.push(msg)
    step.filter_queued_msg(i_producer, i_route_id, i_seq_id)

  fun ref begin_snapshot(p: Producer, s_id: SnapshotId) =>
    Fail()

  fun ref ack_snapshot(c: Consumer, s_id: SnapshotId) =>
    Fail()

  fun ref flush(omni_router: OmniRouter) =>
    for msg in messages.values() do
      msg.run(step, omni_router)
    end
    messages = Array[QueuedStepMessage]

class SnapshotStepMessageProcessor is StepMessageProcessor
  let step: Step ref
  let _snapshot_acker: SnapshotAcker
  var messages: Array[QueuedStepMessage] = messages.create()

  new create(s: Step ref, snapshot_acker: SnapshotAcker)
  =>
    step = s
    _snapshot_acker = snapshot_acker

  fun ref run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)
  =>
    if _snapshot_acker.input_blocking(i_producer) then
      let msg = TypedQueuedStepMessage[D](metric_name, pipeline_time_spent,
        data, i_producer_id, msg_uid, frac_ids, i_seq_id, i_route_id,
        latest_ts, metrics_id, worker_ingress_ts)
      messages.push(msg)
    else
      step.process_message[D](metric_name, pipeline_time_spent, data,
        i_producer_id, i_producer, msg_uid, frac_ids, i_seq_id, i_route_id,
        latest_ts, metrics_id, worker_ingress_ts)
    end

  fun ref ack_snapshot(s: Snapshottable, s_id: SnapshotId) =>
    _snapshot_acker.ack_snapshot(s, s_id)

  fun ref flush(omni_router: OmniRouter) =>
    for msg in messages.values() do
      msg.run(step, omni_router)
    end
    messages = Array[QueuedStepMessage]

trait val QueuedStepMessage
  fun run(step: Step ref, omni_router: OmniRouter)

class val TypedQueuedStepMessage[D: Any val] is QueuedStepMessage
  let metric_name: String
  let pipeline_time_spent: U64
  let data: D
  let i_producer_id: StepId
  let msg_uid: MsgId
  let frac_ids: FractionalMessageId
  let i_seq_id: SeqId
  let i_route_id: RouteId
  let latest_ts: U64
  let metrics_id: U16
  let worker_ingress_ts: U64

  new val create(metric_name': String, pipeline_time_spent': U64,
    data': D, i_producer_id': StepId, msg_uid': MsgId,
    frac_ids': FractionalMessageId, i_seq_id': SeqId, i_route_id': RouteId,
    latest_ts': U64, metrics_id': U16, worker_ingress_ts': U64)
  =>
    metric_name = metric_name'
    pipeline_time_spent = pipeline_time_spent'
    data = data'
    i_producer_id = i_producer_id'
    msg_uid = msg_uid'
    frac_ids = frac_ids'
    i_seq_id = i_seq_id'
    i_route_id = i_route_id'
    latest_ts = latest_ts'
    metrics_id = metrics_id'
    worker_ingress_ts = worker_ingress_ts'

  fun run(step: Step ref, omni_router: OmniRouter) =>
    // TODO: When we develop a strategy for migrating watermark information for
    // migrated queued messages, then we should look up the correct producer
    // that we'll use to send acks to for the case when our upstream is no
    // longer on the same worker.
    let i_producer =  DummyProducer
    // let i_producer =
    //   try
    //     omni_router.producer_for(i_producer_id)?
    //   else
    //     DummyProducer
    //   end
    step.process_message[D](metric_name, pipeline_time_spent, data, i_producer_id,
      i_producer, msg_uid, frac_ids, i_seq_id, i_route_id, latest_ts,
      metrics_id, worker_ingress_ts)
