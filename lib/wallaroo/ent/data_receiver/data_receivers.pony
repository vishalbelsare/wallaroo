/*

Copyright 2017 The Wallaroo Authors.

Licensed as a Wallaroo Enterprise file under the Wallaroo Community
License (the "License"); you may not use this file except in compliance with
the License. You may obtain a copy of the License at

     https://github.com/wallaroolabs/wallaroo/blob/master/LICENSE

*/

use "collections"
use "wallaroo/core/common"
use "wallaroo/core/data_channel"
use "wallaroo/ent/network"
use "wallaroo/ent/recovery"
use "wallaroo/ent/router_registry"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"


interface DataReceiversSubscriber
  be data_receiver_added(sender_name: String, boundary_step_id: RoutingId,
    dr: DataReceiver)

actor DataReceivers
  let _auth: AmbientAuth
  let _connections: Connections
  let _worker_name: String

  var _initialized: Bool = false

  let _data_receivers: Map[BoundaryId, DataReceiver] =
    _data_receivers.create()
  var _data_router: DataRouter
  let _subscribers: SetIs[DataReceiversSubscriber tag] = _subscribers.create()

  var _router_registry: (RouterRegistry | None) = None

  let _state_step_creator: StateStepCreator

  new create(auth: AmbientAuth, connections: Connections, worker_name: String,
    state_step_creator: StateStepCreator, is_recovering: Bool = false)
  =>
    _auth = auth
    _connections = connections
    _worker_name = worker_name
    _state_step_creator = state_step_creator
    _data_router =
      DataRouter(_worker_name, recover Map[RoutingId, Consumer] end,
        recover LocalStatePartitions end, recover LocalStatePartitionIds end,
        recover Map[RoutingId, StateName] end)
    if not is_recovering then
      _initialized = true
    end

  be set_router_registry(rr: RouterRegistry) =>
    _router_registry = rr

  be subscribe(sub: DataReceiversSubscriber tag) =>
    _subscribers.set(sub)

  fun _inform_subscribers(b_id: BoundaryId, dr: DataReceiver) =>
    for sub in _subscribers.values() do
      sub.data_receiver_added(b_id.name, b_id.step_id, dr)
    end

  be request_data_receiver(sender_name: String, sender_boundary_id: RoutingId,
    conn: DataChannel)
  =>
    """
    Called when a DataChannel is first created and needs to know the
    DataReceiver corresponding to the relevant OutgoingBoundary. If this
    is the first time that OutgoingBoundary has connected to this worker,
    then we create a new DataReceiver here.
    """
    let boundary_id = BoundaryId(sender_name, sender_boundary_id)
    let dr =
      try
        _data_receivers(boundary_id)?
      else
        // !@ this should be recoverable
        let id = RoutingIdGenerator()

        let new_dr = DataReceiver(_auth, id, _worker_name, sender_name,
          _data_router, _state_step_creator, _initialized)
        //!@
        // new_dr.update_router(_data_router)
        match _router_registry
        | let rr: RouterRegistry =>
          rr.register_data_receiver(sender_name, new_dr)
        else
          Fail()
        end
        _data_receivers(boundary_id) = new_dr
        _connections.register_disposable(new_dr)
        new_dr
      end
    conn.identify_data_receiver(dr, sender_boundary_id)
    _inform_subscribers(boundary_id, dr)

    //!@
  be start_replay_processing() =>
    None
    //!@
    // for dr in _data_receivers.values() do
    //   dr.start_replay_processing()
    // end

  be start_normal_message_processing() =>
    _initialized = true
    for dr in _data_receivers.values() do
      dr.start_normal_message_processing()
    end

  be update_data_router(dr: DataRouter) =>
    _data_router = dr
    for data_receiver in _data_receivers.values() do
      data_receiver.update_router(_data_router)
    end
