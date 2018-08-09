# Celsius

This is an example of a stateless application that takes a floating point Celsius value and sends out a floating point Fahrenheit value.

## Prerequisites

- ponyc
- pony-stable
- Wallaroo

See [Wallaroo Environment Setup Instructions](https://github.com/WallarooLabs/wallaroo/book/getting-started/setup.md).

## Building

Build Celsius with

```bash
make
```

## Generating Data

A data generator is bundled with the application. Use it to generate a file with a fixed number of psuedo-random votes:

```
cd data_gen
./data_gen --message-count 10000
```

This will create a `celsius.msg` file in your current working directory.

## Running Celsius

In a separate shell, each:

0. In a shell, start up the Metrics UI if you don't already have it running:

```bash
docker start mui
```

1. Start a listener

```bash
../../../utils/data_receiver/data_receiver --listen 127.0.0.1:7002 --no-write \
  --ponynoblock --ponythreads=1
```

2. Start the application

```bash
./celsius --in 127.0.0.1:7010 --out 127.0.0.1:7002 --metrics 127.0.0.1:5001 \
  --control 127.0.0.1:12500 --data 127.0.0.1:12501 --external 127.0.0.1:5050 \
  --cluster-initializer --ponynoblock --ponythreads=1
```

3. Start a sender

```bash
../../../giles/sender/sender --host 127.0.0.1:7010 \
  --file data_gen/celsius.msg \
  --batch-size 5 --interval 100_000_000 --messages 150 --binary \
  --variable-size --repeat --ponythreads=1 --ponynoblock --no-write
```

4. Shut down cluster once finished processing

```bash
../../../../utils/cluster_shutdown/cluster_shutdown 127.0.0.1:5050
```
