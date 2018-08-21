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

"""
# Wallaroo Standard Library

This package represents the unit test suite for Wallaroo.

All tests can be run by compiling and running this package.
"""
use "ponytest"
use cluster_manager = "ent/cluster_manager"
use data_channel = "core/data_channel"
use initialization = "core/initialization"
use rebalancing = "ent/rebalancing"
use recovery = "ent/recovery"
use spike = "ent/spike"
use topology = "core/topology"

actor Main is TestList
  new create(env: Env) =>
    PonyTest(env, this)

  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    cluster_manager.Main.make().tests(test)
    data_channel.Main.make().tests(test)
    initialization.Main.make().tests(test)
    rebalancing.Main.make().tests(test)
    recovery.Main.make().tests(test)
    spike.Main.make().tests(test)
    topology.Main.make().tests(test)
