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

import logging
import os
try:
    from cStringIO import StringIO      # Python 2
except ImportError:
    from io import StringIO

INFO2 = logging.INFO + 1
logging.addLevelName(INFO2, 'INFO2')

DEFAULT_LOG_FMT = '%(asctime)s %(levelname)-8s [%(filename)s:%(lineno)d] %(message)s'
DEFAULT_LOG_FMT_NAME = '%(asctime)s %(name)s %(levelname)-8s [%(filename)s:%(lineno)d] %(message)s'

LOG_LEVELS = {'none': 0,
              '1': 1,
              'debug': 10,
              'info': 20,
              'warn': 30,
              'error': 40,
              'critical': 50}
def get_log_level(value=None):
    """Get the effective log level"""
    if value is None:
        value = os.environ.get("LOGLEVEL")
    return LOG_LEVELS.get(value, 20)


def set_name(name=''):
    logging.root.name = name


def set_logging(name='', level=logging.INFO, fmt=None):
    logging.root.name = name
    logging.root.setLevel(0)
    if not fmt:
        if name:
            fmt = DEFAULT_LOG_FMT_NAME
        else:
            fmt = DEFAULT_LOG_FMT
    logging.root.formatter = logging.Formatter(fmt)
    stream_handler = logging.StreamHandler()
    stream_handler.setLevel(level)
    stream_handler.setFormatter(logging.root.formatter)
    logging.root.addHandler(stream_handler)


def add_in_memory_log_stream(name='', level=None, fmt=None):
    logging.root.setLevel(0)
    log_stream = StringIO()
    if not fmt:
        if name:
            fmt = DEFAULT_LOG_FMT_NAME
        else:
            fmt = DEFAULT_LOG_FMT
    formatter = logging.Formatter(fmt)
    sh = logging.StreamHandler(log_stream)
    if level:
        sh.setLevel(level)
    sh.setFormatter(formatter)
    logging.root.addHandler(sh)
    return log_stream


def add_file_logger(filepath, name='', level=logging.DEBUG, fmt=None):
    logging.root.setLevel(0)
    if not fmt:
        if name:
            fmt = DEFAULT_LOG_FMT_NAME
        else:
            fmt = DEFAULT_LOG_FMT
    file_handler = logging.FileHandler(filepath)
    file_handler.setLevel(level)
    file_handler.setFormatter(logging.Formatter(fmt))
    logging.root.addHandler(file_handler)
