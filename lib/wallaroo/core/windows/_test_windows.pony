/*

Copyright 2018 The Wallaroo Authors.

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
use "itertools"
use "ponytest"
use "promises"
use "random"
use "wallaroo/core/aggregations"
use "wallaroo/core/common"
use "wallaroo/core/state"
use "wallaroo/core/topology"
use "wallaroo_labs/time"
use "time"

actor _WindowTests is TestList
  new create(env: Env) => PonyTest(env, this)
  new make() => None
  fun tag tests(test: PonyTest) =>
    test(_TumblingWindowsTriggeredOnTimeoutWatermark)
    test(_TumblingWindowsOutputEventTimes)
    test(_SlidingWindowsOutputEventTimes)
    test(_OnTimeoutWatermarkTsIsJustBeforeNextWindowStart)
    test(_EventInNewWindowCausesPreviousToFlush)
    test(_TimeoutAfterEndOfWindowCausesFlush)
    test(_OutputWatermarkTsIsJustBeforeNextWindowStart)
    test(_TestTumblingWindows)
    test(_TestSlidingWindows)
    test(_TestSlidingWindowsNoDelay)
    test(_TestSlidingWindowsOutOfOrder)
    test(_TestSlidingWindowsGCD)
    test(_TestSlidingWindowsLateData)
    test(_TestSlidingWindowsEarlyData)
    test(_TestSlidingWindowsStragglers)
    test(_TestSlidingWindowsStragglersSequence)
    test(_TestSlidingWindowsSequence)
    test(_TestCountWindows)
    test(_TestStaggerIsSane)
    test(_TestStaggerDoesNotUnderflow)
    test(_TestZeroIsAValidEventTime)

class iso _TumblingWindowsTriggeredOnTimeoutWatermark is UnitTest
  fun name(): String => "windows/_TumblingWindowsTriggeredOnTimeoutWatermark"

  fun apply(h: TestHelper) ? =>
    // given
    let watermark: U64 = Seconds(111)
    let range: U64 = Seconds(1)
    let tw = _TotalTumblingWindow(range, _Sum)
             .>apply(111, watermark, watermark)

    // when
    let res = tw.on_timeout(TimeoutWatermark(), watermark)

    // then
    let res_array = _ForceArray(res._1)?
    h.assert_eq[USize](res_array.size(), 1)
    h.assert_array_eq[USize](res_array, [111])
    h.assert_true(res._2 != TimeoutWatermark())

class iso _TumblingWindowsOutputEventTimes is UnitTest
  fun name(): String => "windows/_TumblingWindowsOutputEventTimes"

  fun apply(h: TestHelper) ? =>
    // given
    let range: U64 = Seconds(3)
    let tw = _TotalTumblingWindow(range, _Sum)
             .>apply(1, Seconds(111), Seconds(111))
             .>apply(2, Seconds(112), Seconds(112))

    // when
    let res = tw(3, Seconds(114), Seconds(114))

    // then
    let res_array = _ForceArrayWithEventTimes(res._1)?
    h.assert_eq[USize](res_array.size(), 1)
    h.assert_eq[USize](res_array(0)?._1, 1 + 2)
    h.assert_eq[U64](res_array(0)?._2, Seconds(114)-1)
    h.assert_eq[U64](res._2, Seconds(114)-1)

class iso _SlidingWindowsOutputEventTimes is UnitTest
  fun name(): String => "windows/_SlidingWindowsOutputEventTimes"

  fun apply(h: TestHelper) ? =>
    // given
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(5)
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)
        .>apply(1, Seconds(111), Seconds(111))
        .>apply(2, Seconds(121), Seconds(121))

    // when
    let res = sw(3, Seconds(141), Seconds(141))

    // then
    let res_array = _ForceArrayWithEventTimes(res._1)?

    let values =
      Iter[(USize,U64)](res_array.values())
        .map[USize]({(x) => x._1})
        .collect(Array[USize])

    let times =
      Iter[(USize,U64)](res_array.values())
        .map[U64]({(x) => x._2})
        .collect(Array[U64])

    h.assert_array_eq[USize]([1;1;2;2], values)
    h.assert_array_eq[U64]([Seconds(116)-1
                            Seconds(121)-1
                            Seconds(126)-1
                            Seconds(131)-1
                            ], times)

// !TODO!: Add tests that shows empty windows are created when an event
// 'in the future' comes in.

class iso _OnTimeoutWatermarkTsIsJustBeforeNextWindowStart is UnitTest
  fun name(): String =>
    "windows/_OnTimeoutWatermarkTsIsJustBeforeNextWindowStart"

  fun apply(h: TestHelper) ? =>
    // given
    let range: U64 = Milliseconds(50)
    let slide = range
    let delay: U64 = 0
    let tw = _TotalTumblingWindow(Milliseconds(50), _NonZeroSum)
             .>apply(1, Milliseconds(5000), Milliseconds(5000))

    // when
    let res = tw.on_timeout(TimeoutWatermark(), Milliseconds(5000)-1)

    // then
    let res_array = _ForceArray(res._1)?
    h.assert_eq[USize](res_array.size(), 1)
    h.assert_eq[USize](res_array(0)?, 1)
    h.assert_eq[U64](res._2, Milliseconds(5050)-1)

class iso _EventInNewWindowCausesPreviousToFlush is UnitTest
  fun name(): String =>
    "windows/_EventInNewWindowCausesPreviousToFlush"

  fun apply(h: TestHelper) ? =>
    // given
    let tw = _TotalTumblingWindow(Milliseconds(50), _NonZeroSum)
             .>apply(1, Milliseconds(5000), Milliseconds(5000))
             .>apply(2, Milliseconds(5025), Milliseconds(5025))
    // when
    let res = tw(10, Milliseconds(5055), Milliseconds(5055))

    // then
    h.assert_array_eq[USize]([3], _ForceArray(res._1)?)

class iso _TimeoutAfterEndOfWindowCausesFlush is UnitTest
  fun name(): String =>
    "windows/_TimeoutAfterEndOfWindowCausesFlush"

  fun apply(h: TestHelper) ? =>
    // given
    let tw = _TotalTumblingWindow(Milliseconds(50), _NonZeroSum)
             .>apply(1, Milliseconds(5000), Milliseconds(5000))
             .>apply(2, Milliseconds(5025), Milliseconds(5025))
    // when
    let res = tw.on_timeout(TimeoutWatermark(), 0)//second param doesn't matter

    // then
    h.assert_array_eq[USize]([3], _ForceArray(res._1)?)

class iso _OutputWatermarkTsIsJustBeforeNextWindowStart is UnitTest
  fun name(): String =>
    "windows/_OutputWatermarkTsIsJustBeforeNextWindowStart"

  fun apply(h: TestHelper) ? =>
    // given
    let range: U64 = Milliseconds(50)
    let upstream_id: U128 = 1000
    let now: U64 = 1000
    let tw =
      RangeWindowsBuilder(range)
        .over[USize, USize, _Total](_NonZeroSum)
        .state_wrapper("key", _Zeros)
        .>apply(1, Milliseconds(5000), Milliseconds(5000))

    // when
    let res = tw(3, Milliseconds(5100), Milliseconds(5100))

    // then
    let res_array = _ForceArray(res._1)?
    h.assert_array_eq[USize]([1], _ForceArray(res._1)?)
    h.assert_eq[U64](res._2, Milliseconds(5050)-1)

class iso _TestTumblingWindows is UnitTest
  fun name(): String => "windows/_TestTumblingWindows"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    // Tumbling windows have the same slide as range
    let delay: U64 = Seconds(10)
    let tw =
      RangeWindowsBuilder(range)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // First window's data
    var res = tw(2, Seconds(96), Seconds(101))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(3, Seconds(97), Seconds(102))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(4, Seconds(98), Seconds(103))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(5, Seconds(99), Seconds(104))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)

    // Second window's data
    res = tw(1, Seconds(105), Seconds(106))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(2, Seconds(106), Seconds(107))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(3, Seconds(107), Seconds(108))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    res = tw(4, Seconds(108), Seconds(109))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)

    // Third window's data. This first message should trigger
    // first window.
    res = tw(10, Seconds(110), Seconds(111))
    h.assert_array_eq[USize]([14], _ForceArray(res._1)?)
    res = tw(20, Seconds(111), Seconds(112))
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)
    tw(30, Seconds(112), Seconds(113))
    tw(40, Seconds(113), Seconds(114))

    // Use this message to trigger windows 2 and 3
    res = tw(1, Seconds(200), Seconds(201))
    h.assert_array_eq[USize]([20;90], _ForceArray(res._1)?)

class iso _TestSlidingWindows is UnitTest
  fun name(): String => "windows/_TestSlidingWindows0"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // First 2 windows values
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(92), Seconds(100)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(93), Seconds(102)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(94), Seconds(103)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(95), Seconds(104)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Second 2 windows with values
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(102), Seconds(106)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(103), Seconds(107)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(104), Seconds(108)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(105), Seconds(109)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Third 2 windows with values.
    h.assert_array_eq[USize]([14;14],
      _OutArray(sw(10, Seconds(108), Seconds(112)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(20, Seconds(109), Seconds(113)))?)
    h.assert_array_eq[USize]([12],
      _OutArray(sw(30, Seconds(110), Seconds(114)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(40, Seconds(111), Seconds(115)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Fourth set of windows
    // Use this message to trigger 10 windows.
    h.assert_array_eq[USize]([10;10;40;110;107;100;100;70;0;0],
      _OutArray(sw(2, Seconds(192), Seconds(200)))?)
    /// first pane should start at 182s

    h.assert_array_eq[USize]([0], _OutArray(sw(3, Seconds(193), Seconds(202)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(194), Seconds(203)))?)
    h.assert_array_eq[USize]([5], _OutArray(sw(5, Seconds(195), Seconds(204)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Fifth 2 windows with values
    // These values are missing? @jtfmumm need your eye here
    h.assert_array_eq[USize]([14], _OutArray(sw(1, Seconds(202), Seconds(206)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(203), Seconds(207)))?)
    h.assert_array_eq[USize]([14], _OutArray(sw(3, Seconds(204), Seconds(208)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(205), Seconds(209)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Sixth 2 windows with values.
    h.assert_array_eq[USize]([14;14],
      _OutArray(sw(10, Seconds(211), Seconds(212)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(20, Seconds(212), Seconds(213)))?)
    h.assert_array_eq[USize]([12],
      _OutArray(sw(30, Seconds(213), Seconds(214)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(40, Seconds(214), Seconds(215)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))


class iso _TestSlidingWindowsNoDelay is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsNoDelay"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(92), Seconds(100)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(93), Seconds(102)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(94), Seconds(103)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(95), Seconds(104)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Second 2 windows with values
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(102), Seconds(106)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(103), Seconds(107)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(104), Seconds(108)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(105), Seconds(109)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Third 2 windows with values.
    h.assert_array_eq[USize]([20; 20],
      _OutArray(sw(10, Seconds(108), Seconds(112)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(20, Seconds(109), Seconds(113)))?)
    h.assert_array_eq[USize]([67],
      _OutArray(sw(30, Seconds(110), Seconds(114)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(40, Seconds(111), Seconds(115)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Fourth set of windows
    h.assert_array_eq[USize]([100;100;70;0;0],
    // Use this message to trigger 10 windows.
      _OutArray(sw(2, Seconds(192), Seconds(200)))?)
    h.assert_array_eq[USize]([5],
      _OutArray(sw(3, Seconds(193), Seconds(202)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(194), Seconds(203)))?)
    h.assert_array_eq[USize]([9],
      _OutArray(sw(5, Seconds(195), Seconds(204)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

class iso _TestSlidingWindowsOutOfOrder is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsOutOfOrder"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // First 2 windows values
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(95), Seconds(100)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(94), Seconds(102)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(93), Seconds(103)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(92), Seconds(104)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

    // Second 2 windows with values
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(105), Seconds(106)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(104), Seconds(107)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(103), Seconds(108)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(102), Seconds(109)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

    // Third 2 windows with values.
    h.assert_array_eq[USize]([14; 14],
      _OutArray(sw(40, Seconds(111), Seconds(112)))?)
    h.assert_array_eq[USize]([  ],
      _OutArray(sw(30, Seconds(110), Seconds(113)))?)
    h.assert_array_eq[USize]([12],
      _OutArray(sw(20, Seconds(109), Seconds(114)))?)
    h.assert_array_eq[USize]([  ],
      _OutArray(sw(10, Seconds(108), Seconds(115)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

    // Fourth set of windows
    h.assert_array_eq[USize]([10;10;40;110;107;100;100;70;0;0],
      // Use the below message to trigger 10 windows.
      _OutArray(sw(2, Seconds(192), Seconds(200)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

class iso _TestSlidingWindowsGCD is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsGCD"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(3)
    // This delay will be normalized up to 12 because 10 is not a multiple
    // of the slide.
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // First set of windows values
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(92), Seconds(100)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(93), Seconds(102)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(94), Seconds(103)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(95), Seconds(104)))?)

    // Second set of windows with values
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(102), Seconds(106)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(103), Seconds(107)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(104), Seconds(108)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(105), Seconds(109)))?)

    // Third set of windows with values.
    h.assert_array_eq[USize]([14],
      _OutArray(sw(10, Seconds(111), Seconds(112)))?)
    h.assert_array_eq[USize]([14],
      _OutArray(sw(20, Seconds(112), Seconds(113)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(30, Seconds(113), Seconds(114)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(40, Seconds(114), Seconds(115)))?)

    // Fourth set of windows
    h.assert_array_eq[USize]([12;10;10;39;100;100;90;0],
      _OutArray(sw(2, Seconds(192), Seconds(200)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(193), Seconds(202)))?)
    h.assert_array_eq[USize]([0],
      _OutArray(sw(4, Seconds(194), Seconds(203)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(195), Seconds(204)))?)

    // Fifth set of windows with values
    h.assert_array_eq[USize]([5],
      _OutArray(sw(1, Seconds(202), Seconds(206)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(203), Seconds(207)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(204), Seconds(208)))?)
    h.assert_array_eq[USize]([14],
      _OutArray(sw(4, Seconds(205), Seconds(209)))?)

    // Sixth set of windows with values.
    h.assert_array_eq[USize]([14],
      _OutArray(sw(10, Seconds(211), Seconds(212)))?)
    h.assert_array_eq[USize]([],
      _OutArray(sw(20, Seconds(212), Seconds(213)))?)

    h.assert_array_eq[USize]([],
      _OutArray(sw(30, Seconds(213), Seconds(214)))?)
    h.assert_array_eq[USize]([13],
      _OutArray(sw(40, Seconds(214), Seconds(215)))?)

class iso _TestSlidingWindowsLateData is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsLateData"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // Some initial values
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(92), Seconds(100)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(93), Seconds(102)))?)
    // Trigger existing values
    h.assert_array_eq[USize]([3;3;0;0;0;0;0;0;0;0],
      _OutArray(sw(10, Seconds(199), Seconds(200)))?)
    // Send in late data, which should be dropped.
    h.assert_array_eq[USize]([],
      _OutArray(sw(100, Seconds(100), Seconds(201)))?)
    // Send in more late data, which should be dropped.
    h.assert_array_eq[USize]([0;0;0;0;10;10;10;10;10;0],
      _OutArray(sw(1, Seconds(101), Seconds(220)))?)

class iso _TestSlidingWindowsEarlyData is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsEarlyData"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(10)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // First values
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(92), Seconds(100)))?)
    // Send in a bunch of early values
    h.assert_array_eq[USize]([], _OutArray(sw(1, Seconds(102), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([], _OutArray(sw(2, Seconds(103), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(104), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(105), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([],
      _OutArray(sw(10, Seconds(108), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([],
      _OutArray(sw(20, Seconds(109), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([],
      _OutArray(sw(30, Seconds(110), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([],
      _OutArray(sw(40, Seconds(111), Seconds(100)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    // Send in more normal values
    h.assert_array_eq[USize]([], _OutArray(sw(3, Seconds(93), Seconds(102)))?)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))
    h.assert_array_eq[USize]([], _OutArray(sw(4, Seconds(94), Seconds(103)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(5, Seconds(95), Seconds(104)))?)
    // Send in late values just to trigger stuff
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(106)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(107)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(108)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(109)))?)
    h.assert_array_eq[USize]([14;14],
      _OutArray(sw(0, Seconds(1), Seconds(112)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(113)))?)
    h.assert_array_eq[USize]([12], _OutArray(sw(0, Seconds(1), Seconds(114)))?)
    h.assert_array_eq[USize]([], _OutArray(sw(0, Seconds(1), Seconds(115)))?)

    // Fourth set of windows
    h.assert_array_eq[USize]([10;10;40;110;107;100;100;70;0;0;0],
      _OutArray(sw(2, Seconds(192), Seconds(200)))?)

class iso _TestSlidingWindowsStragglers is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsStragglers"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(1_000)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)

    // Last heard threshold of 100 seconds
    let watermarks = StageWatermarks(Seconds(100_000))

    var wm = Seconds(10_000)
    var cur_ts = Seconds(50_000)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    var res = sw(1, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)

    wm = Seconds(10_001)
    cur_ts = Seconds(50_001)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(3, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArray(res._1)?.size(), 0)

    wm = Seconds(10_002)
    cur_ts = Seconds(50_002)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(5, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_array_eq[USize]([], _ForceArray(res._1)?)

    // It's been a while since we've heard from anyone
    cur_ts = Seconds(10_000_000)
    let input_w = watermarks.check_effective_input_watermark(cur_ts)
    let output_w = watermarks.output_watermark()
    res = sw.on_timeout(input_w, output_w)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArray(res._1)?.size(), 502)
    for i in Range(0, 496) do
      h.assert_eq[USize](_ForceArray(res._1)?(i)?, 0)
    end
    h.assert_eq[USize](_ForceArray(res._1)?(496)?, 1 + 3)
    h.assert_eq[USize](_ForceArray(res._1)?(497)?, 1 + 3 + 5)
    h.assert_eq[USize](_ForceArray(res._1)?(498)?, 1 + 3 + 5)
    h.assert_eq[USize](_ForceArray(res._1)?(499)?, 1 + 3 + 5)
    h.assert_eq[USize](_ForceArray(res._1)?(500)?, 1 + 3 + 5)
    h.assert_eq[USize](_ForceArray(res._1)?(501)?, 5)
    h.assert_true(CheckPanesAreIncreasing[USize, USize, _Total](sw))

class iso _TestSlidingWindowsStragglersSequence is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsStragglersSequence"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(10)
    let slide: U64 = Seconds(2)
    let delay: U64 = Seconds(1_000)
    // let sw = RangeWindows[USize, Array[USize] val, _Collected]("key",
    //   _Collect, range, slide, delay, _Zeros)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, Array[USize] val, _Collected](_Collect)
        .state_wrapper("key", _Zeros)

    // Last heard threshold of 100 seconds
    let watermarks = StageWatermarks(Seconds(100_000))

    var wm = Seconds(10_000)
    var cur_ts = Seconds(50_000)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    var res = sw(1, wm, wm)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    wm = Seconds(10_001)
    cur_ts = Seconds(50_001)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(2, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    wm = Seconds(10_002)
    cur_ts = Seconds(50_002)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(3, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    wm = Seconds(10_003)
    cur_ts = Seconds(50_003)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(4, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    wm = Seconds(10_004)
    cur_ts = Seconds(50_004)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(5, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    wm = Seconds(10_005)
    cur_ts = Seconds(50_005)
    wm = watermarks.receive_watermark(1, wm, cur_ts)
    res = sw(6, wm, wm)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 0)

    // It's been awhile since we've heard from anyone
    cur_ts = Seconds(100_000_000)
    let input_w = watermarks.check_effective_input_watermark(cur_ts)
    let output_w = watermarks.output_watermark()
    res = sw.on_timeout(input_w, output_w)
    watermarks.update_output_watermark(res._2)
    h.assert_eq[USize](_ForceArrayArray(res._1)?.size(), 503)
    // Check empty windows before our stragglers
    for i in Range(0, 496) do
      h.assert_eq[USize](_sum(_ForceArrayArray(res._1)?(i)?), 0)
    end
    h.assert_eq[USize](_sum(_ForceArrayArray(res._1)?(496)?), 1 + 2)
    h.assert_eq[USize](_sum(_ForceArrayArray(res._1)?(497)?), 1 + 2 + 3 + 4)
    h.assert_eq[USize](
      _sum(_ForceArrayArray(res._1)?(498)?), 1 + 2 + 3 + 4 + 5 + 6)
    h.assert_eq[USize](
      _sum(_ForceArrayArray(res._1)?(499)?), 1 + 2 + 3 + 4 + 5 + 6)
    h.assert_eq[USize](
      _sum(_ForceArrayArray(res._1)?(500)?), 1 + 2 + 3 + 4 + 5 + 6)
    h.assert_eq[USize](_sum(_ForceArrayArray(res._1)?(501)?), 3 + 4 + 5 + 6)
    h.assert_eq[USize](_sum(_ForceArrayArray(res._1)?(502)?), 5 + 6)
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))

  fun _sum(arr: Array[USize] val): USize =>
    var sum: USize = 0
    for u in arr.values() do
      sum = sum + u
    end
    sum

class iso _TestSlidingWindowsSequence is UnitTest
  fun name(): String => "windows/_TestSlidingWindowsSequence"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(50)
    let slide: U64 = Seconds(25)
    let delay: U64 = Seconds(3000)
    let sw =
      RangeWindowsBuilder(range)
        .with_slide(slide)
        .with_delay(delay)
        .over[USize, Array[USize] val, _Collected](_Collect)
        .state_wrapper("key", _Zeros)

    // var wm: USize = 4_888
    // res = sw(0, Seconds(4_889), Seconds(wm))
    var wm: USize = 4_863
    var res = sw(0, Seconds(4_864), Seconds(wm))
    for i in Range(0, 28) do
      wm = wm + 25
      sw(i, Seconds(wm), Seconds(wm))
    end
    wm = wm + 10
    sw(28, Seconds(wm), Seconds(wm))
    wm = wm + 10
    sw(29, Seconds(wm), Seconds(wm))
    wm = wm + 10
    sw(30, Seconds(wm), Seconds(wm))

    // First values
    res = sw(20, Seconds(10_901), Seconds(10_901))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(21, Seconds(10_907), Seconds(10_907))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(22, Seconds(10_912), Seconds(10_912))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(23, Seconds(10_918), Seconds(10_918))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(24, Seconds(10_924), Seconds(10_924))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(25, Seconds(10_929), Seconds(10_929))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(26, Seconds(10_935), Seconds(10_935))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(27, Seconds(10_940), Seconds(10_940))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(28, Seconds(10_945), Seconds(10_945))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(29, Seconds(10_951), Seconds(10_951))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(30, Seconds(10_957), Seconds(10_957))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(31, Seconds(10_964), Seconds(10_964))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(32, Seconds(10_968), Seconds(10_968))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(33, Seconds(10_973), Seconds(10_973))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end
    h.assert_true(CheckPanesAreIncreasing[USize, Array[USize] val, _Collected](
      sw))
    res = sw(34, Seconds(10_979), Seconds(10_979))
    for c in _ForceArrayArray(res._1)?.values() do
      h.assert_eq[Bool](CheckAnyDecreaseOrIncreaseByOne(c), true)
    end

class iso _TestCountWindows is UnitTest
  fun name(): String => "windows/_TestCountWindows"

  fun apply(h: TestHelper) =>
    let count_trigger: USize = 4
    let cw = TumblingCountWindows[USize, USize, _Total]("key", _Sum,
      count_trigger)

    //var res: ((USize | None), U64) = (None, 0)

    // First window's data
    var res = cw(2, Seconds(96), Seconds(101))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(3, Seconds(97), Seconds(102))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(4, Seconds(98), Seconds(103))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(5, Seconds(99), Seconds(104))
    h.assert_eq[Bool](true, _result_is(res._1, 14))

    // Second window's data
    res = cw(1, Seconds(105), Seconds(106))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(2, Seconds(106), Seconds(107))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(3, Seconds(107), Seconds(108))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(4, Seconds(108), Seconds(109))
    h.assert_eq[Bool](true, _result_is(res._1, 10))

    // Third window's data.
    res = cw(10, Seconds(110), Seconds(111))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(20, Seconds(111), Seconds(112))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(30, Seconds(112), Seconds(113))
    h.assert_eq[Bool](true, _result_is(res._1, None))
    res = cw(40, Seconds(113), Seconds(114))
    h.assert_eq[Bool](true, _result_is(res._1, 100))

    true

  fun _result_is(res: (USize
                      | Array[USize] val
                      | Array[(USize, U64)] val
                      | None),
                 check: (USize | None)): Bool
  =>
    match res
    | let u: USize =>
      match check
      | let u2: USize => u == u2
      else
        false
      end
    | let n: None =>
      match check
      | let n2: None => true
      else
        false
      end
    else
      false
    end

class iso _TestStaggerIsSane is UnitTest
  fun name(): String => "windows/_TestStaggerIsSane"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(1)
    let delay: U64 = Seconds(2)
    // Make sure that for any generated window, the
    // first event is never lost due to random stagger.
    for random_window in Range(0,1000) do
      let tw =
        RangeWindowsBuilder(range)
          .with_delay(delay)
          .over[USize, USize, _Total](_Sum)
          .state_wrapper("key", Rand(Time.nanos().u64(), Time.nanos().u64()))
          .>apply(1, Seconds(10), Seconds(10))
      var res = tw(99, Seconds(14), Seconds(14))
      h.assert_array_eq[USize]([0;0;1], _ForceArray(res._1)?)
    end

class iso _TestStaggerDoesNotUnderflow is UnitTest
  fun name(): String => "windows/_TestStaggerDoesNotUnderflow"

  fun apply(h: TestHelper) ? =>
    let range: U64 = Seconds(1)
    let delay: U64 = Seconds(1)
    let tw =
      RangeWindowsBuilder(range)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Ones)
        .>apply(1, Milliseconds(999), Milliseconds(999))

    var res = tw(2, Seconds(2)+1, Seconds(2)+1)
    h.assert_array_eq[USize]([1], _ForceArray(res._1)?)

class iso _TestZeroIsAValidEventTime is UnitTest
  fun name(): String => "windows/_TestZeroIsAValidEventTime"

  fun apply(h: TestHelper) ? =>
    let range: U64 = 1
    let slide = range
    let delay: U64 = 0
    let tw =
      RangeWindowsBuilder(range)
        .with_delay(delay)
        .over[USize, USize, _Total](_Sum)
        .state_wrapper("key", _Zeros)
        .>apply(1, 0, 0)
    var res = tw(2, 1, 1)
    h.assert_array_eq[USize]([1], _ForceArray(res._1)?)


class _Total is State
  var v: USize = 0

class _Sum is Aggregation[USize, USize, _Total]
  fun initial_accumulator(): _Total => _Total
  fun update(input: USize, acc: _Total) =>
    acc.v = acc.v + input
  fun combine(acc1: _Total, acc2: _Total): _Total =>
    let new_t = _Total
    new_t.v = acc1.v + acc2.v
    new_t
  fun output(key: Key, window_end_ts: U64, acc: _Total): (USize | None) =>
    acc.v
  fun name(): String => "_Sum"

class _NonZeroSum is Aggregation[USize, USize, _Total]
  fun initial_accumulator(): _Total => _Total
  fun update(input: USize, acc: _Total) =>
    acc.v = acc.v + input
  fun combine(acc1: _Total, acc2: _Total): _Total =>
    let new_t = _Total
    new_t.v = acc1.v + acc2.v
    new_t
  fun output(key: Key, window_end_ts: U64, acc: _Total): (USize | None) =>
    if acc.v > 0 then acc.v end
  fun name(): String => "_NonZeroSum"

primitive _Collect is Aggregation[USize, Array[USize] val, _Collected]
  fun initial_accumulator(): _Collected => _Collected
  fun update(input: USize, acc: _Collected) =>
    acc.push(input)
  fun combine(acc1: _Collected, acc2: _Collected): _Collected =>
    let new_arr = _Collected
    for m1 in acc1.values() do
      new_arr.push(m1)
    end
    for m2 in acc2.values() do
      new_arr.push(m2)
    end
    new_arr
  fun output(key: Key, window_end_ts: U64, acc: _Collected): Array[USize] val =>
    let arr: Array[USize] iso = recover Array[USize] end
    for m in acc.values() do
      arr.push(m)
    end
    consume arr
  fun name(): String => "_Collect"

class _Collected is State
  let arr: Array[USize] = arr.create()

  fun ref push(u: USize) =>
    arr.push(u)

  fun values(): ArrayValues[USize, this->Array[USize]]^ =>
    arr.values()

primitive CheckAnyDecreaseOrIncreaseByOne
  fun apply(arr: Array[USize] val): Bool =>
    try
      var last = arr(0)?
      for i in Range(1, arr.size()) do
        let v = arr(i)?
        if not ((v == (last + 1)) or (v <= last)) then
          return false
        end
        last = v
      end
    else
      false
    end
    true

primitive _OutArray
  fun apply(outs_ts: (ComputationResult[USize], U64, Bool)): Array[USize] val ?
  =>
    _ForceArray(outs_ts._1)?

primitive _ForceArray
  fun apply(res: ComputationResult[USize]): Array[USize] val ? =>
    match res
    | let a: Array[(USize, U64)] val =>
      // !TODO! return the tuple itself after all tests pass
      let a' = recover iso Array[USize] end
      for (o,ts) in a.values() do
        a'.push(o)
      end
      consume a'
    else error end

primitive _ForceArrayWithEventTimes
  fun apply(res: ComputationResult[USize]): Array[(USize,U64)] val ? =>
    match res
    | let a: Array[(USize, U64)] val => a
    else error end

primitive _ForceArrayArray
  fun apply(res: ComputationResult[Array[USize] val]):
    Array[Array[USize] val] val ?
  =>
    match res
    | let a: Array[(Array[USize] val, U64)] val =>
      // !TODO! return the tuple itself after all tests pass
      let a' = recover iso Array[Array[USize] val] end
      for (subarray, _) in a.values() do
        let a'' = recover iso Array[USize] end
        for o in subarray.values() do
          a''.push(o)
        end
        a'.push(consume a'')
      end
      consume a'
    else error end

primitive _TotalTumblingWindow
  fun apply(range: U64, calculation: Aggregation[USize, USize, _Total]):
    InitializableWindows[USize, USize, _Total]
  =>
    let slide = range
    let delay: U64 = 0
    let windows_wrapper_builder = _SlidingWindowsWrapperBuilder[USize, USize,
      _Total]("key", _NonZeroSum, range, slide, delay, _Zeros,
      LateDataPolicy.drop())
    InitializableWindows[USize, USize, _Total](windows_wrapper_builder)

primitive _CollectTumblingWindow
  fun apply(range: U64, calculation: Aggregation[USize, Array[USize] val,
    _Collected]): InitializableWindows[USize, Array[USize] val, _Collected]
  =>
    let slide = range
    let delay: U64 = 0
    let windows_wrapper_builder = _SlidingWindowsWrapperBuilder[USize,
      Array[USize] val, _Collected]("key", _Collect, range, slide, delay,
      _Zeros, LateDataPolicy.drop())
    InitializableWindows[USize, Array[USize] val, _Collected](
      windows_wrapper_builder)

class _Zeros is Random
  new ref create(x: U64 val = 0, y: U64 val = 0) => None
  fun ref next(): U64 => 0

class _Ones is Random
  new ref create(x: U64 val = 0, y: U64 val = 0) => None
  fun ref next(): U64 => 1

primitive CheckPanesAreIncreasing
  fun apply[In: Any val, Out: Any val, Acc: State ref](
    state_wrapper: StateWrapper[In, Out, Acc]): Bool
  =>
    match state_wrapper
    | let iw: InitializableWindows[In, Out, Acc] =>
      iw.check_panes_increasing()
    else
      false
    end
