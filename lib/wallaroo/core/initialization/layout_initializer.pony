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
use "promises"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/core/messages"
use "wallaroo/core/data_receiver"
use "wallaroo/core/checkpoint"

trait tag LayoutInitializer
  be initialize(cluster_initializer: (ClusterInitializer | None) = None,
    checkpoint_target: (CheckpointId | None) = None,
    recovering_without_resilience: Bool = false)

  be report_created(initializable: Initializable)

  be report_initialized(initializable: Initializable)

  be report_ready_to_work(initializable: Initializable)

  be worker_report_ready_to_work(w: WorkerName)

  be all_workers_ready_to_work()

  be update_boundaries(bs: Map[String, OutgoingBoundary] val,
    bbs: Map[String, OutgoingBoundaryBuilder] val)

  be create_data_channel_listener(ws: Array[String] val,
    host: String, service: String,
    cluster_initializer: (ClusterInitializer | None) = None)

  be rollback_local_keys(checkpoint_id: CheckpointId,
    promise: Promise[None])
