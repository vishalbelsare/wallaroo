# Copyright 2017 The Wallaroo Authors.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#  implied. See the License for the specific language governing
#  permissions and limitations under the License.


# Error classes
class StopError(Exception):
    pass


class AutoscaleError(Exception):
    pass


class ClusterError(StopError):
    pass


class ClusterStoppedError(ClusterError):
    pass


class MigrationError(AutoscaleError):
    pass


class DuplicateKeyError(MigrationError):
    pass


class TimeoutError(StopError):
    pass


class SinkAwaitTimeoutError(TimeoutError):
    pass


class ExpectationError(StopError):
    pass


class PipelineTestError(Exception):
    pass


class CrashedWorkerError(StopError):
    pass


class RunnerHasntStartedError(Exception):
    pass


class NotEmptyError(Exception):
    pass


class ValidationError(Exception):
    pass
