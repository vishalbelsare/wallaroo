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

from __future__ import print_function

# import requisite components for integration test
from integration import (add_runner,
                         clean_resilience_path,
                         cluster_status_query,
                         CrashedWorkerError,
                         ex_validate,
                         get_func_name,
                         get_port_values,
                         iter_generator,
                         Metrics,
                         MetricsData,
                         multi_states_query,
                         ObservabilityNotifier,
                         partition_counts_query,
                         partitions_query,
                         state_entity_query,
                         PipelineTestError,
                         Reader,
                         Runner,
                         runners_output_format,
                         Sender,
                         setup_resilience_path,
                         Sink,
                         SinkAwaitValue,
                         start_runners,
                         TimeoutError)

from collections import Counter
from functools import partial
from itertools import chain, cycle
import json
import logging
import os
import re
from string import lowercase
from struct import calcsize, pack, unpack
import tempfile
import time

from pytest_wait import pause_for_user


class AutoscaleTestError(Exception):
    def __init__(self, args, as_error=None, as_steps=[]):
        super(AutoscaleTestError, self).__init__(args)
        self.as_error = as_error
        self.as_steps = as_steps


class AutoscaleTimeoutError(AutoscaleTestError):
    pass


class DuplicateKeyError(AutoscaleTestError):
    pass


class MigrationError(AutoscaleTestError):
    pass


fmt = '>I2sQ'
def decode(bs):
    return unpack(fmt, bs)[1:3]


def pre_process(decoded):
    totals = {}
    for c, v in decoded:
        totals[c] = v
    return totals


def process(data):
    decoded = []
    for d in data:
        decoded.append(decode(d))
    return pre_process(decoded)


def validate(raw_data, expected):
    data = process(raw_data)
    assert(data == expected)


def send_shrink_cmd(host, port, names=[], count=1):
    # Trigger log rotation with external message
    cmd_external_trigger = ('cluster_shrinker --external {}:{} --workers {}'
                            .format(host, port,
                                    ','.join(names) if names else count))

    success, stdout, retcode, cmd = ex_validate(cmd_external_trigger)
    try:
        assert(success)
    except AssertionError:
        raise AssertionError('External shrink trigger failed with '
                             'the error:\n{}'.format(stdout))
    return stdout


def phase_validate_output(runners, sink, expected):
    # Validate captured output
    try:
        validate(sink.data, expected)
    except AssertionError:
        outputs = runners_output_format(runners)
        raise AssertionError('Validation failed on expected output. '
                             'Worker outputs are included below:'
                             '\n===\n{}'.format(outputs))


def phase_validate_partitions(runners, partitions, joined=[], left=[]):
    """
    Use the partition map to determine whether new workers have joined and
    departing workers have left.
    """
    joined_set = set(joined)
    left_set = set(left)
    # Compute set of workers with partitions
    workers = set()
    for p_type in partitions.values():
        for step in p_type.values():
            for key in step.keys():
                if len(step[key]) > 0:
                    workers.add(key)

    try:
        assert(workers.issuperset(joined_set))
    except AssertionError as err:
        missing = sorted(list(joined_set.difference(workers)))
        outputs = runners_output_format(runners)
        raise AssertionError('{} do not appear to have joined! '
                             'Worker outputs are included below:'
                             '\n===\n{}'.format(missing, outputs))

    try:
        assert(workers.isdisjoint(left_set))
    except AssertionError as err:
        reamining = sorted(list(workers.intersection(left_set)))
        outputs = runners_output_format(runners)
        raise AssertionError('{} do not appear to have left! '
                             'Worker outputs are included below:'
                             '\n===\n{}'.format(w, outputs))


def sign(i):
    if i > 0:
        return 'p'
    elif i < 0:
        return 'n'
    else:
        return 'z'


def compact_sign(ops):
    new = [ops[0]]
    for o in ops[1:]:
        if sign(new[-1]) == sign(o):
            new[-1] += o
        elif sign(o) == 'z':
            continue
        else:
            new.append(o)
    return new


def lowest_point(ops):
    l = None
    p = 0
    for o in ops:
        p += o
        if l is None:
            l  = p
        if p < l:
            l = p
    return l


def inverted(d):
    """
    Invert a partitions query response dict from
        {stateless_partitions: {step: {worker: [partition ids]}},
         state_partitions: {step: {worker: [partition ids]}}}
    to
        {stateless_partitions: {step: {partition_id: worker}},
         state_partitions: {step: {partition_id: worker}}}
    """
    o = {}
    for ptype in d:
        o[ptype] = {}
        for step in d[ptype]:
            o[ptype][step] = {}
            for worker in d[ptype][step]:
                for pid in d[ptype][step][worker]:
                    o[ptype][step][pid] = worker
    return o


# Observability Validation Test Functions
def get_crashed_runners(runners):
    """
    Get a list of crashed runners, if any exist.
    """
    return filter(lambda r: r.poll(), runners)



def joined_partition_query_data(responses):
    """
    Join partition query responses from multiple workers into a single
    partition map.
    Raise error on duplicate partitions.
    """
    steps = {}
    for worker in responses.keys():
        for step in responses[worker].keys():
            if step not in steps:
                steps[step] = {}
            for part in responses[worker][step]:
                if part in steps[step]:
                    dup0 = worker
                    dup1 = steps[step][part]
                    raise DuplicateKeyError("Found duplicate keys! Step: {}, "
                                            "Key: {}, Loc1: {}, Loc2: {}"
                                            .format(step, part, dup0, dup1))
                steps[step][part] = worker
    return steps


def test_crashed_workers(runners):
    """
    Test if there are any crashed workers and raise an error if yes
    """
    crashed = get_crashed_runners(runners)
    if crashed:
        raise CrashedWorkerError("Some workers have crashed.")


def test_worker_count(count, status):
    """
    Test that there `count` workers are reported as active in the
    cluster status query response
    """
    assert(len(status['worker_names']) == count)
    assert(status['worker_count'] == count)


def test_all_workers_have_partitions(partitions):
    """
    Test that all workers have partitions
    """
    assert(map(len, partitions['state_partitions']['letter-state']
                    .values()).count(0) == 0)


def test_worker_has_state_entities(state_entities):
    """
    Test that the worker has state_entities
    """
    assert(len(state_entities['letter-state']) > 0)


def test_cluster_is_processing(status):
    """
    Test that the cluster's 'processing_messages' status is True
    """
    assert(status['processing_messages'] is True)


def test_cluster_is_not_processing(status):
    """
    Test that the cluster's 'processing messages' status is False
    """
    assert(status['processing_messages'] is False)


def test_migration(pre_partitions, post_partitions, workers):
    """
    - Test that no "joining" workers are present in the pre set
    - Test that no "leaving" workers are present in the post set
    - Test that state partitions moved between the pre_partitions map and
      the post_partitions map.
    - Test that all of the states present in the `pre` set are also present
      in the `post` set. New state are allowed in the `post` because of
      dynamic partitioning (new partitions may be created in real time).
    """
    # prepare some useful sets for set-wise comparison
    pre_parts = {step: set(pre_partitions[step].keys()) for step in
                 pre_partitions}
    post_parts = {step: set(post_partitions[step].keys()) for step in
                  post_partitions}
    pre_workers = set(chain(*[pre_partitions[step].values() for step in
                             pre_partitions]))
    post_workers = set(chain(*[post_partitions[step].values() for step in
                               post_partitions]))
    joining = set(workers.get('joining', []))
    leaving = set(workers.get('leaving', []))

    print('pre', pre_workers)
    print('post', post_workers)
    print('joining', joining)
    print('leaving', leaving)
    # test no joining workers are present in pre set
    assert((pre_workers - joining) == pre_workers)

    # test no leaving workers are present in post set
    assert((post_workers - leaving) == post_workers)

    # test that no parts go missing after migration
    for step in pre_parts:
        assert(step in post_parts)
        assert(post_parts[step] <= pre_parts[step])

    # test that state parts moved between pre and post (by step)
    for step in pre_partitions:
        # Test step did not disappear after migration
        assert(step in post_partitions)
        # Test some partitions moved
        assert(pre_partitions[step] != post_partitions[step])


def wait_for_cluster_to_resume_processing(runners):
    # Wait until all workers have resumed processing
    for r in runners:
        if not r.is_alive():
            continue
        obs = ObservabilityNotifier(cluster_status_query,
            r.external,
            tests=test_cluster_is_processing, timeout=120)
        obs.start()
        obs.join()
        if obs.error:
            raise obs.error


def try_until_timeout(test, pre_process=None, timeout=30):
    """
    Try a test until it passes or the time runs out

    :parameters
    `test` - a runnable test function that raises an error if it fails
    `pre_process` - a runnable function that generates test input.
        The test input is used as the parameters for the function given by
        `test`.
    `timeout` - the timeout, in seconds, before the test is failed.
    """
    t0 = time.time()
    c = 0
    while True:
        c += 1
        try:
            if pre_process:
                args = pre_process()
                test(*args)
            else:
                test()
        except:
            if time.time() - t0 > timeout:
                print("Failed on attempt {} of test: {}..."
                      .format(c, get_func_name(test)))
                raise
            time.sleep(2)
        else:
            return


# Autoscale tests runner functions

def autoscale_sequence(command, ops=[1], cycles=1, initial=None):
    """
    Run an autoscale test for a given command by performing grow and shrink
    operations, as denoted by positive and negative integers in the `ops`
    parameter, a `cycles` number of times.
    `initial` may be used to define the starting number of workers. If it is
    left undefined, the minimum number required so that the number of workers
    never goes below zero will be determined and used.
    """
    try:
        _autoscale_sequence(command, ops, cycles, initial)
    except Exception as err:
        if hasattr(err, 'as_steps'):
            print("Autoscale Sequence test failed after the operations {}."
                  .format(err.as_steps))
        if hasattr(err, 'as_error'):
            print("Autoscale Sequence test had the following the error "
                  "message:\n{}".format(err.as_error))
        if hasattr(err, 'runners'):
            if filter(lambda r: r.poll() != 0, err.runners):
                outputs = runners_output_format(err.runners,
                        from_tail=5, filter_fn=lambda r: r.poll() != 0)
                print("Some autoscale Sequence runners exited badly. "
                      "They had the following "
                      "output tails:\n===\n{}".format(outputs))
        if hasattr(err, 'query_result') and 'PRINT_QUERY' in os.environ:
            logging.error("The test error had the following query result"
                          " attached:\n{}"
                          .format(json.dumps(err.query_result)))
        raise

def _autoscale_sequence(command, ops=[], cycles=1, initial=None):
    host = '127.0.0.1'
    sources = 1

    if isinstance(ops, int):
        ops = [ops]

    # If no initial workers value is given, determine the minimum number
    # required at the start so that the cluster never goes below 1 worker.
    # If a number is given, then verify it is sufficient.
    if ops:
        lowest = lowest_point(ops*cycles)
        if lowest < 1:
            min_workers = abs(lowest) + 1
        else:
            min_workers = 1
        if isinstance(initial, int):
            assert(initial >= min_workers)
            workers = initial
        else:
            workers = min_workers
    else:  # Test is only for setup using initial workers
        assert(initial > 0)
        workers = initial

    batch_size = 10
    interval = 0.05
    sender_timeout = 30 # Counted from when Sender is stopped
    runner_join_timeout = 30

    res_dir = tempfile.mkdtemp(dir='/tmp/', prefix='res-data.')
    setup_resilience_path(res_dir)

    steps = []

    runners = []
    try:
        try:
            # Create sink, metrics, reader, sender
            sink = Sink(host)
            metrics = Metrics(host)
            lowercase2 = [a+b for a in lowercase for b in lowercase]
            char_cycle = cycle(lowercase2)
            expected = Counter()
            def count_sent(s):
                expected[s] += 1

            reader = Reader(iter_generator(
                items=char_cycle, to_string=lambda s: pack('>2sI', s, 1),
                on_next=count_sent))

            # Start sink and metrics, and get their connection info
            sink.start()
            sink_host, sink_port = sink.get_connection_info()
            outputs = '{}:{}'.format(sink_host, sink_port)

            metrics.start()
            metrics_host, metrics_port = metrics.get_connection_info()
            time.sleep(0.05)

            num_ports = sources + 3 + 3 * workers
            ports = get_port_values(num=num_ports, host=host)
            (input_ports, worker_ports) = (
                ports[:sources],
                [ports[sources:][i:i+3] for i in xrange(0,
                    len(ports[sources:]), 3)])
            inputs = ','.join(['{}:{}'.format(host, p) for p in
                               input_ports])

            # Start the initial runners
            start_runners(runners, command, host, inputs, outputs,
                          metrics_port, res_dir, workers, worker_ports)

            # Verify cluster is processing messages
            obs = ObservabilityNotifier(cluster_status_query,
                (host, worker_ports[0][2]),
                tests=test_cluster_is_processing)
            obs.start()
            obs.join()
            if obs.error:
                raise obs.error

            # Verify that `workers` workers are active
            # Create a partial function
            partial_test_worker_count = partial(test_worker_count, workers)
            obs = ObservabilityNotifier(cluster_status_query,
                (host, worker_ports[0][2]),
                tests=partial_test_worker_count)
            obs.start()
            obs.join()
            if obs.error:
                raise obs.error

            # Verify initializer starts with partitions
            obs = ObservabilityNotifier(state_entity_query,
                (host, worker_ports[0][2]),
                 test_worker_has_state_entities)
            obs.start()
            obs.join()
            if obs.error:
                raise obs.error

            # start sender
            sender = Sender(host, input_ports[0], reader, batch_size=batch_size,
                            interval=interval)
            sender.start()
            # Give the cluster 1 second to build up some state
            time.sleep(1)

            # Perform autoscale cycles
            for cyc in range(cycles):
                for joiners in ops:
                    # Verify cluster is processing before proceeding
                    obs = ObservabilityNotifier(cluster_status_query,
                        (host, worker_ports[0][2]),
                        tests=test_cluster_is_processing, timeout=30)
                    obs.start()
                    obs.join()
                    if obs.error:
                        raise obs.error

                    # Test for crashed workers
                    test_crashed_workers(runners)

                    # get partition data before autoscale operation begins
                    addresses = [(r.name, r.external) for r in runners
                                 if r.is_alive()]
                    responses = multi_states_query(addresses)
                    pre_partitions = joined_partition_query_data(responses)
                    steps.append(joiners)
                    joined = []
                    left = []

                    if joiners > 0:  # autoscale: grow
                        # create new workers and have them join
                        new_ports = get_port_values(num=(joiners * 3), host=host,
                                                    base_port=25000)
                        joiner_ports = [new_ports[i:i+3] for i in
                                        xrange(0, len(new_ports), 3)]
                        for i in range(joiners):
                            add_runner(runners, command, host, inputs, outputs,
                                       metrics_port,
                                       worker_ports[0][0], res_dir,
                                       joiners, *joiner_ports[i])
                            joined.append(runners[-1])

                    elif joiners < 0:  # autoscale: shrink
                        # choose the most recent, still-alive runners to leave
                        leavers = abs(joiners)
                        idx = 1
                        while len(left) < leavers and idx < len(runners):
                            if runners[-idx].is_alive():
                                left.append(runners[-idx])
                            idx += 1
                        if len(left) < leavers:
                            raise AutoscaleTestError("Not enough workers left to "
                                                     "shrink! {} requested but "
                                                     "only {} live non-initializer"
                                                     "workers found!"
                                                    .format(joiners, len(left)))

                        # Send the shrink command
                        resp = send_shrink_cmd(*runners[0].external,
                                               names=[r.name for r in left])
                        print("Sent a shrink command for {}".format(
                            [r.name for r in left]))
                        print("Response was: {}".format(resp))

                    else:  # Handle the 0 case as a noop
                        continue

                    # Wait until all live workers report 'ready'
                    wait_for_cluster_to_resume_processing(runners)

                    # Test for crashed workers
                    test_crashed_workers(runners)

                    # Test: at least some states moved, and no states from
                    #       pre are missing from the post

                    # get partition data before autoscale operation begins
                    workers={'joining': [r.name for r in joined],
                             'leaving': [r.name for r in left]}
                    # use a pre_process function to recreate this data for
                    # retriable tests
                    def pre_process():
                        addresses = [(r.name, r.external) for r in runners
                                     if r.is_alive()]
                        responses = multi_states_query(addresses)
                        post_partitions = joined_partition_query_data(responses)
                        return (pre_partitions, post_partitions, workers)
                    # retry the test until it passes or a timeout elapses
                    try_until_timeout(test_migration, pre_process, timeout=120)

                    # Wait a second before the next operation, allowing some
                    # more data to go through the system
                    time.sleep(1)

            time.sleep(2)

            # Test for crashed workers
            test_crashed_workers(runners)

            # Test is done, so stop sender
            sender.stop()

            # wait until sender sends out its final batch and exits
            sender.join(sender_timeout)
            if sender.error:
                raise sender.error
            if sender.is_alive():
                sender.stop()
                raise TimeoutError('Sender did not complete in the expected '
                                   'period')

            print('Sender sent {} messages'.format(sum(expected.values())))

            # Use Sink value to determine when to stop runners and sink
            pack677 = '>I2sQ'
            await_values = [pack(pack677, calcsize(pack677)-4, c, v) for c, v in
                            expected.items()]
            stopper = SinkAwaitValue(sink, await_values, 30)
            stopper.start()
            stopper.join()
            if stopper.error:
                print('sink.data', len(sink.data))
                print('await_values', len(await_values))
                raise stopper.error

            # stop application workers
            for r in runners:
                r.stop()

            # Test for crashed workers
            test_crashed_workers(runners)

            # Stop sink
            sink.stop()

            # Stop metrics
            metrics.stop()

            # validate output
            phase_validate_output(runners, sink, expected)
        #except:
        #    # wait for user interaction to continue
        #    if os.environ.get('pause_for_user'):
        #        pause_for_user()
        #    raise
        finally:
            for r in runners:
                r.stop()
            # Wait on runners to finish waiting on their subprocesses to exit
            for r in runners:
                r.join(runner_join_timeout)
            alive = []
            for r in runners:
                if r.is_alive():
                    alive.append(r)
            for r in runners:
                ec = r.poll()
                if ec != 0:
                    print('Worker {!r} exited with return code {}'
                          .format(r.name, ec))
                    print('Its last 5 log lines were:')
                    print('\n'.join(r.get_output().splitlines()[-5:]))
                    print()
            if alive:
                alive_names = ', '.join((r.name for r in alive))
                outputs = runners_output_format(runners)
                for a in alive:
                    a.kill()
            clean_resilience_path(res_dir)
            if alive:
                raise PipelineTestError("Runners [{}] failed to exit cleanly after"
                                        " {} seconds.\n"
                                        "Runner outputs are attached below:"
                                        "\n===\n{}"
                                        .format(alive_names, runner_join_timeout,
                                                outputs))
    except Exception as err:
        if not hasattr(err, 'as_steps'):
            err.as_steps = steps
        if not hasattr(err, 'runners'):
            err.runners = runners
        raise
