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
use "wallaroo/core/boundary"
use "wallaroo/ent/data_receiver"
use "wallaroo/core/initialization"
use "wallaroo/core/routing"
use "wallaroo/core/topology"

trait tag InFlightAckRequester
  be receive_in_flight_ack(request_id: RequestId)
  be receive_in_flight_resume_ack(request_id: RequestId)
  be try_finish_in_flight_request_early(requester_id: StepId)

trait tag InFlightAckResponder
  be request_in_flight_ack(request_id: RequestId, requester_id: StepId,
    requester: InFlightAckRequester)
  be request_in_flight_resume_ack(in_flight_resume_ack_id: InFlightResumeAckId,
    request_id: RequestId, requester_id: StepId,
    requester: InFlightAckRequester, leaving_workers: Array[String] val)

trait tag StatusReporter
  be report_status(code: ReportStatusCode)

trait tag Producer is (Muteable & Ackable & AckRequester &
  InFlightAckRequester & SnapshotRequester)
  fun ref route_to(c: Consumer): (Route | None)
  fun ref next_sequence_id(): SeqId
  fun ref current_sequence_id(): SeqId
  fun ref unknown_key(state_name: String, key: Key,
    routing_args: RoutingArguments)
  be remove_route_to_consumer(id: StepId, c: Consumer)

trait tag SnapshotRequester
  fun ref snapshot_state()
  fun ref snapshot_complete()

interface tag RouterUpdateable
  be update_router(r: Router)

interface tag BoundaryUpdateable
  be remove_boundary(worker: String)

trait tag Consumer is (Runnable & StateReceiver & AckRequester &
  Initializable & InFlightAckResponder & StatusReporter & Snapshottable)
  // TODO: For now, since we do not allow application graph cycles, all back
  // edges are from DataReceivers. This allows us to simply identify them
  // directly. Once we allow application cycles, we will need a more
  // flexible approach.
  be register_producer(id: StepId, producer: Producer, back_edge: Bool)
  be unregister_producer(id: StepId, producer: Producer, back_edge: Bool)

trait Snapshottable
  be receive_snapshot_barrier(sr: SnapshotRequester, snapshot_id: SnapshotId)

trait tag Runnable
  be run[D: Any val](metric_name: String, pipeline_time_spent: U64, data: D,
    i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)

  be replay_run[D: Any val](metric_name: String, pipeline_time_spent: U64,
    data: D, i_producer_id: StepId, i_producer: Producer, msg_uid: MsgId,
    frac_ids: FractionalMessageId, i_seq_id: SeqId, i_route_id: RouteId,
    latest_ts: U64, metrics_id: U16, worker_ingress_ts: U64)

trait tag Muteable
  be mute(c: Consumer)
  be unmute(c: Consumer)

trait tag StateReceiver
  be receive_state(state: ByteSeq val)

trait tag AckRequester
  be request_ack()

trait tag Initializable
  be application_begin_reporting(initializer: LocalTopologyInitializer)
  be application_created(initializer: LocalTopologyInitializer,
    omni_router: OmniRouter)

  be application_initialized(initializer: LocalTopologyInitializer)
  be application_ready_to_work(initializer: LocalTopologyInitializer)
