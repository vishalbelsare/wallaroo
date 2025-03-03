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
This is an example of a stateless application that takes a floating point
Celsius value and sends out a floating point Fahrenheit value.
"""

import logging
import struct
import wallaroo
import wallaroo.experimental

fmt = '%(asctime)s celsius %(levelname)-8s [%(filename)s:%(lineno)d] %(message)s'
logging.root.formatter = logging.Formatter(fmt)
stream_handler = logging.StreamHandler()
stream_handler.setFormatter(logging.root.formatter)
logging.root.addHandler(stream_handler)
logging.root.setLevel(logging.INFO)

class CelsiusGenerator(object):
    """
    Hackery to generate celsius values
    """
    def __init__(self, max=500):
        self.max = max

    def initial_value(self):
        return -40.0

    def apply(self, last_str):
        last = float(last_str)
        if last > self.max:
            logging.info('CelsiusGenerator: stopping at max={}'.format(self.max))
            return None
        return last + 1.0

def application_setup(args):
    celsius_feed = wallaroo.GenSourceConfig('Gen celsius source', CelsiusGenerator(999999))
    fahrenheit_conversion = wallaroo.experimental.SinkConnectorConfig(
        "fahrenheit_conversion",
        encoder=encode_conversion,
        decoder=decode_conversion,
        port=7200,
        cookie="Dragons-Love-Tacos")
    pipeline = (
        wallaroo.source("convert temperature readings", celsius_feed)
        .to(multiply)
        .to(add)
        .to_sink(fahrenheit_conversion)
    )
    return wallaroo.build_application("Celsius to Fahrenheit", pipeline)


@wallaroo.computation(name="multiply by 1.8")
def multiply(data):
    return data * 1.8


@wallaroo.computation(name="add 32")
def add(data):
    return data + 32


@wallaroo.experimental.stream_message_encoder
def encode_feed(data):
    return data


@wallaroo.experimental.stream_message_decoder
def decode_feed(data):
    return struct.unpack(">f", data)[0]


@wallaroo.experimental.octet_message_encoder
def encode_conversion(data):
    # Let's make line-oriented output
    x = (str(data) + '\n').encode('utf-8')
    # print('DBG: sink encode: {}'.format(x))
    return x


@wallaroo.experimental.stream_message_decoder
def decode_conversion(data):
    return data.decode('utf-8')
