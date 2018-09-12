/*

Copyright 2018 The Wallaroo Authors.

Licensed as a Wallaroo Enterprise file under the Wallaroo Community
License (the "License"); you may not use this file except in compliance with
the License. You may obtain a copy of the License at

     https://github.com/wallaroolabs/wallaroo/blob/master/LICENSE

*/

use "collections"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/core/invariant"
use "wallaroo/core/topology"
use "wallaroo_labs/mort"


class BarrierStepForwarder
  let _step_id: RoutingId
  let _step: Step ref
  var _barrier_token: BarrierToken = InitialBarrierToken
  let _inputs_blocking: Map[RoutingId, Producer] = _inputs_blocking.create()
  let _removed_inputs: SetIs[RoutingId] = _removed_inputs.create()

  // !@ Perhaps we need to add invariant wherever inputs and outputs can be
  // updated in the encapsulating actor to check if barrier is in progress.
  new create(step_id: RoutingId, step: Step ref) =>
    _step_id = step_id
    _step = step

  fun ref higher_priority(token: BarrierToken): Bool =>
    token > _barrier_token

  fun ref lower_priority(token: BarrierToken): Bool =>
    token < _barrier_token

  fun barrier_in_progress(): Bool =>
    _barrier_token != InitialBarrierToken

  fun input_blocking(id: RoutingId): Bool =>
    _inputs_blocking.contains(id)

  fun ref receive_new_barrier(step_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    // @printf[I32]("!@ StepForwarder: receive_new_barrier\n".cstring())
    _barrier_token = barrier_token
    receive_barrier(step_id, producer, barrier_token)

  fun ref receive_barrier(step_id: RoutingId, producer: Producer,
    barrier_token: BarrierToken)
  =>
    // If this new token is a higher priority token, then the forwarder should
    // have already been cleared to make way for it.
    ifdef debug then
      //!@
      if barrier_token > _barrier_token then
        @printf[I32]("Invariant violation: received barrier %s is greater than current barrier %s \n".cstring(), barrier_token.string().cstring(), _barrier_token.string().cstring())
      end

      Invariant(not (barrier_token > _barrier_token))
    end

    // @printf[I32]("!@ receive_barrier at Forwarder from %s!\n".cstring(), step_id.string().cstring())
    // If we're processing a rollback token which is higher priority than
    // this new one, then we need to drop this new one.
    if _barrier_token > barrier_token then
      return
    end

    if barrier_token != _barrier_token then
      @printf[I32]("!@ Received %s when still processing %s at step %s\n".cstring(),
        _barrier_token.string().cstring(), barrier_token.string().cstring(), _step_id.string().cstring())
      Fail()
    end

    let inputs = _step.inputs()
    if inputs.contains(step_id) then
      _inputs_blocking(step_id) = producer
      check_completion(inputs)
    else
      if not _removed_inputs.contains(step_id) then
        @printf[I32]("!@ %s: Forwarder at %s doesn't know about %s\n".cstring(), barrier_token.string().cstring(), _step_id.string().cstring(), step_id.string().cstring())
        Fail()
      end
    end

  fun ref remove_input(input_id: RoutingId) =>
    """
    Called if an input leaves the system during barrier processing. This should
    only be possible with Sources that are closed (e.g. when a TCPSource
    connection is dropped).
    """
    if _inputs_blocking.contains(input_id) then
      try
        _inputs_blocking.remove(input_id)?
      else
        Unreachable()
      end
    end
    _removed_inputs.set(input_id)
    if _inputs_blocking.contains(input_id) then
      try _inputs_blocking.remove(input_id)? else Unreachable() end
    end
    check_completion(_step.inputs())

  fun ref check_completion(inputs: Map[RoutingId, Producer] box) =>
    if (inputs.size() == (_inputs_blocking.size() + _removed_inputs.size()))
      and not _step.has_pending_messages()
    then
      // @printf[I32]("!@ That was last barrier at Forwarder.  FORWARDING!\n".cstring())
      for (o_id, o) in _step.outputs().pairs() do
        match o
        | let ob: OutgoingBoundary =>
          // @printf[I32]("!@ FORWARDING TO BOUNDARY\n".cstring())
          ob.forward_barrier(o_id, _step_id,
            _barrier_token)
        else
          // @printf[I32]("!@ FORWARDING TO NON BOUNDARY\n".cstring())
          o.receive_barrier(_step_id, _step, _barrier_token)
        end
      end
      _step.barrier_complete(_barrier_token)
      clear()
    //!@
    else
      //!@
      None
      // @printf[I32]("!@ Not last barrier at Forwarder. inputs: %s, inputs_blocking: %s, removed_inputs: %s\n".cstring(), inputs.size().string().cstring(), _inputs_blocking.size().string().cstring(), _removed_inputs.size().string().cstring())
      // @printf[I32]("!@ Inputs:\n".cstring())
      //!@
      // for i in inputs.keys() do
        // @printf[I32]("!@ -- %s\n".cstring(), i.string().cstring())
      // end
    end

  fun ref clear() =>
    _inputs_blocking.clear()
    _removed_inputs.clear()
    _barrier_token = InitialBarrierToken
