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

type SeqId is U64
type RoutingId is U128
// TODO: Remove this with old watermarking algo.
type RouteId is U64
type RequestId is U64

// We assign each stateless partition a sequential index so that we can route
// messages in a round robin fashion modding over the incoming sequence ids.
type SeqPartitionIndex is U64
