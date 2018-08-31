/*

Copyright 2017 The Wallaroo Authors.

Licensed as a Wallaroo Enterprise file under the Wallaroo Community
License (the "License"); you may not use this file except in compliance with
the License. You may obtain a copy of the License at

     https://github.com/wallaroolabs/wallaroo/blob/master/LICENSE

*/

use "ponytest"
use "wallaroo/core/common"
use "wallaroo/ent/network"
use "wallaroo/core/routing"

actor Main is TestList
  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    test(_TestDropsConnectionWhenConnectingWhenSpiked)
    test(_TestDoesntDropConnectionWhenConnectingWhenNotSpiked)
    test(_TestDropsConnectionWhenConnectedWhenSpiked)
    test(_TestDoesntDropConnectionWhenConnectedWhenNotSpiked)
    test(_TestDoesntDropConnectionWhenConnectFailedWhenSpiked)
    test(_TestDoesntDropConnectionWhenConnectFailedWhenNotSpiked)
    test(_TestDoesntDropConnectionWhenClosedWhenSpiked)
    test(_TestDoesntDropConnectionWhenClosedWhenNotSpiked)
    test(_TestDropsConnectionWhenSentvWhenSpiked)
    test(_TestDoesntDropConnectionWhenSentvWhenNotSpiked)
    test(_TestDropsConnectionWhenReceivedWhenSpiked)
    test(_TestDoesntDropConnectionWhenReceivedWhenNotSpiked)
    test(_TestDoesntDropConnectionWhenExpectWhenSpiked)
    test(_TestDoesntDropConnectionWhenExpectWhenNotSpiked)
    test(_TestDoesntDropConnectionWhenThrottledWhenSpiked)
    test(_TestDoesntDropConnectionWhenThrottledWhenNotSpiked)
    test(_TestDoesntDropConnectionWhenUnthrottledWhenSpiked)
    test(_TestDoesntDropConnectionWhenUnthrottledWhenNotSpiked)
    test(_TestDropsConnectionWhenSpikedWithMargin)

class iso _TestDropsConnectionWhenConnectingWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DropsConnectionWhenConnectingWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, true)
    let connection_count = U32(1)

    let notify = ConnectingNotify(h, connection, connection_count)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("connecting")
    h.expect_action("closed")

    spike.connecting(connection, connection_count)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenConnectingWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenConnectingWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let connection_count = U32(1)

    let notify = ConnectingNotify(h, connection, connection_count)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
    margin'=0)?, consume notify) end

    h.expect_action("connecting")

    spike.connecting(connection, connection_count)

    h.long_test(1)

class ConnectingNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag
  let _count: U32

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag,
    connection_count: U32)
   =>
    _h = h
    _conn = conn
    _count = connection_count

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.complete_action("connecting")
    _h.assert_true(conn is _conn)
    _h.assert_eq[U32](count, _count)

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDropsConnectionWhenConnectedWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DropsConnectionWhenConnectedWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, true)
    let connection_count = U32(1)

    let notify = ConnectedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
    margin'=0)?, consume notify) end

    h.expect_action("connected")
    h.expect_action("closed")

    spike.connected(connection)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenConnectedWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenConnectedWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let connection_count = U32(1)

    let notify = ConnectedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
    margin'=0)?, consume notify) end

    h.expect_action("connected")

    spike.connected(connection)

    h.long_test(1)

class ConnectedNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag) =>
    _h = h
    _conn = conn

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.complete_action("connected")
    _h.assert_true(conn is _conn)

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDoesntDropConnectionWhenConnectFailedWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenConnectFailed"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ConnectFailedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
    margin'=0)?, consume notify) end

    h.expect_action("connect_failed")

    spike.connect_failed(connection)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenConnectFailedWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenConnectFailedWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ConnectFailedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
    margin'=0)?, consume notify) end

    h.expect_action("connect_failed")

    spike.connect_failed(connection)

    h.long_test(1)

class ConnectFailedNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag) =>
    _h = h
    _conn = conn

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.complete_action("connect_failed")
    _h.assert_true(conn is _conn)

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDoesntDropConnectionWhenClosedWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenConnectFailed"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ClosedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
    margin'=0)?, consume notify) end

    h.expect_action("closed")

    spike.closed(connection)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenClosedWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenClosedWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ClosedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("closed")

    spike.closed(connection)

    h.long_test(1)

class ClosedNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag) =>
    _h = h
    _conn = conn

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.complete_action("closed")
    _h.assert_true(conn is _conn)

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDropsConnectionWhenSentvWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DropsConnectionWhenSentvWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, true)
    let data = recover val ["Hello"; "Willow"] end

    let notify = SentvNotify(h, connection, data)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("sentv")
    h.expect_action("closed")

    spike.sentv(connection, data)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenSentvWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenSentvWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let data = recover val ["Goodbye"; "Angel"] end

    let notify = SentvNotify(h, connection, data)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("sentv")

    spike.sentv(connection, data)

    h.long_test(1)

class SentvNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag
  let _data: ByteSeqIter

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag,
    data: ByteSeqIter)
   =>
    _h = h
    _conn = conn
    _data = data

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.complete_action("sentv")
    _h.assert_true(conn is _conn)
    _h.assert_true(data is _data)
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDropsConnectionWhenReceivedWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DropsConnectionWhenReceivedWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, true)
    let expected_data = recover val [as U8: 1; 2; 3; 4; 5; 10] end
    let send_data = recover iso [as U8: 1; 2; 3; 4; 5; 10] end
    let times = USize(3)

    let notify = ReceivedNotify(h, connection, expected_data, times)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("received")
    h.expect_action("closed")

    spike.received(connection, consume send_data, times)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenReceivedWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenReceivedWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let expected_data = recover val [as U8: 1; 2; 3; 4; 5; 10] end
    let send_data = recover iso [as U8: 1; 2; 3; 4; 5; 10] end
    let times = USize(3)

    let notify = ReceivedNotify(h, connection, expected_data, times)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("received")

    spike.received(connection, consume send_data, times)

    h.long_test(1)

class ReceivedNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag
  let _data: String
  let _times: USize

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag,
    data: Array[U8] val, times: USize)
   =>
    _h = h
    _conn = conn
    _data = String.from_array(data)
    _times = times

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.complete_action("received")
    _h.assert_true(conn is _conn)
    _h.assert_eq[String](String.from_array(consume data), _data)
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDoesntDropConnectionWhenExpectWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenExpectWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let qty = USize(13)

    let notify = ExpectNotify(h, connection, qty)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("expect")

    spike.expect(connection, qty)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenExpectWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenExpectWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)
    let qty = USize(18)

    let notify = ExpectNotify(h, connection, qty)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("expect")

    spike.expect(connection, qty)

    h.long_test(1)

class ExpectNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag
  let _qty: USize

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag,
    qty: USize)
  =>
    _h = h
    _conn = conn
    _qty = qty

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.complete_action("expect")
    _h.assert_true(conn is _conn)
    _h.assert_eq[USize](qty, _qty)
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDoesntDropConnectionWhenThrottledWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenThrottledWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ThrottledNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("throttled")

    spike.throttled(connection)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenThrottledWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenThrottledWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = ThrottledNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("throttled")

    spike.throttled(connection)

    h.long_test(1)

class ThrottledNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag) =>
    _h = h
    _conn = conn

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.complete_action("throttled")
    _h.assert_true(conn is _conn)

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

class iso _TestDoesntDropConnectionWhenUnthrottledWhenSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenUnthrottledWhenSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = UnthrottledNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
      margin'=0)?, consume notify) end

    h.expect_action("unthrottled")

    spike.unthrottled(connection)

    h.long_test(1)

class iso _TestDoesntDropConnectionWhenUnthrottledWhenNotSpiked is UnitTest
  fun name(): String =>
    "spike/DoesntDropConnectionWhenUnthrottledWhenNotSpiked"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, false)

    let notify = UnthrottledNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=0,
      margin'=0)?, consume notify) end

    h.expect_action("unthrottled")

    spike.unthrottled(connection)

    h.long_test(1)

class UnthrottledNotify is WallarooOutgoingNetworkActorNotify
  let _h: TestHelper
  let _conn: WallarooOutgoingNetworkActor tag

  new iso create(h: TestHelper, conn: WallarooOutgoingNetworkActor tag) =>
    _h = h
    _conn = conn

  fun ref connecting(conn: WallarooOutgoingNetworkActor ref, count: U32) =>
    _h.fail()

  fun ref connected(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref connect_failed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref closed(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref sentv(conn: WallarooOutgoingNetworkActor ref,
    data: ByteSeqIter): ByteSeqIter
  =>
    _h.fail()
    data

  fun ref received(conn: WallarooOutgoingNetworkActor ref, data: Array[U8] iso,
    times: USize): Bool
  =>
    _h.fail()
    true

  fun ref expect(conn: WallarooOutgoingNetworkActor ref, qty: USize): USize =>
    _h.fail()
    qty

  fun ref throttled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.fail()

  fun ref unthrottled(conn: WallarooOutgoingNetworkActor ref) =>
    _h.complete_action("unthrottled")
    _h.assert_true(conn is _conn)

class iso _TestDropsConnectionWhenSpikedWithMargin is UnitTest
  fun name(): String =>
    "spike/DropsConnectionWhenSpikedWithMargin"

  fun ref apply(h: TestHelper) ? =>
    let connection = NullWallarooOutgoingNetworkActor(h, true)
    let connection_count = U32(1)

    let notify = ConnectedNotify(h, connection)
    let spike = recover ref DropConnection(SpikeConfig(where seed'=1, prob'=1,
    margin'=3)?, consume notify) end
    // if margin = 3, the 4th action should drop
    h.expect_action("connected")
    h.expect_action("connected")
    h.expect_action("connected")
    h.expect_action("closed")

    spike.connected(connection)
    spike.connected(connection)
    spike.connected(connection)
    spike.connected(connection)

    h.long_test(1)

class NullWallarooOutgoingNetworkActor is WallarooOutgoingNetworkActor
  let _h: TestHelper
  let _should_close: Bool

  new ref create(h: TestHelper, should_close: Bool) =>
    _h = h
    _should_close = should_close

  fun ref set_nodelay(state: Bool) =>
    None

  fun ref expect(qty: USize = 0) =>
    None

  fun ref receive_ack(seq_id: SeqId) =>
    None

  fun ref receive_connect_ack(seq_id: SeqId) =>
    None

  fun ref resend_producer_registrations() =>
    None

  fun ref start_normal_sending() =>
    None

  fun ref close() =>
    if _should_close then
      _h.complete_action("closed")
    else
      _h.fail()
    end
