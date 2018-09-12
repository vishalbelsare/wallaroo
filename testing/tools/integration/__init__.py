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


"""
Integration contains everything that's required to run integration
tests for a Wallaro application (Python, Pony, or otherwise) via a Python
script.

It has:
    - TCPReceiver: a multi-client TCP sink receiver
    - Metrics: an alias for TCPReceiver
    - Sink: an alias for TCPReceiver
    - Sender: a TCP sender
    - Reader: a buffered reader interface wrapper for bytestream generators
    - files_generator: a file source supporting both newlines and framed modes
    - sequence_generator: a framed source encoded U64 sequence generator
        (binary)
    - iter_generator: a generic framed source encoded generator that operates
        on iterators. It takes an optional `to_string` lambda for converting
        iterator items to strings.
    - files_generator: a generic
    - Runner: Runs a single Wallaroo worker with command line parameters.
    - ex_validation: a function to execute external validation commands and
      capture their outputs

You will need to include /testing/tools in your PYTHONPATH, and the
application binary in your PATH before running your integration test.

Below is an example for running the integration test on reverse, a
python-wallaroo application, using the machida binary, the wallaroo python
api, and the the integration tester utility. The integration test script
can be found at
https://github.com/WallarooLabs/wallaroo/examples/python/reverse/_test.py.

```bash
# Add integration utility to PYTHONPATH
export PYTHONPATH="$PYTHONPATH:~/wallaroo-tutorial/wallaroo/testing/tools"
# Add wallaroo to PYTHONPATH
export PYTHONPATH="$PYTHONPATH:~/wallaroo-tutorial/wallaroo/machida:."
# Add machida to PATH
export PATH="%PATH:~/wallaroo-tutorial/wallaroo/machida/build"

# Run integration test
python2 -m pytest _test.py --verbose
```


Alternatively, for a CLI style integration tester, you may use the
`integration_test` CLI. Add
`~/wallaroo-tutorial/wallaroo/testing/tools/integration` to your PATH, then
`integration_test -h` for instructions.
"""

from cluster import (add_runner,
                     Cluster,
                     ClusterError,
                     Runner,
                     RunnerData,
                     runner_data_format,
                     start_runners)

from control import (SinkAwaitValue,
                     SinkExpect,
                     TryUntilTimeout,
                     WaitForClusterToResumeProcessing)

from end_points import (Metrics,
                        MultiSequenceGenerator,
                        Reader,
                        Sender,
                        Sink,
                        files_generator,
                        framed_file_generator,
                        iter_generator,
                        newline_file_generator,
                        sequence_generator)

from errors import (AutoscaleError,
                    CrashedWorkerError,
                    DuplicateKeyError,
                    ExpectationError,
                    MigrationError,
                    PipelineTestError,
                    StopError,
                    TimeoutError)

from external import (clean_resilience_path,
                      create_resilience_dir,
                      run_shell_cmd,
                      get_port_values,
                      is_address_available,
                      setup_resilience_path)

from integration import pipeline_test

from logger import (DEFAULT_LOG_FMT,
                    INFO2,
                    set_logging)

from metrics_parser import (MetricsData,
                            MetricsParser,
                            MetricsParseError)

from observability import (cluster_status_query,
                           get_func_name,
                           multi_states_query,
                           ObservabilityNotifier,
                           ObservabilityResponseError,
                           ObservabilityTimeoutError,
                           partition_counts_query,
                           partitions_query,
                           state_entity_query)

from stoppable_thread import StoppableThread

from typed_list import TypedList
