# Alerts (local aggregations)

## About The Application

This is an example of a stateful application that builds up worker
local aggregations before sending the results downstream where they
are tallied across workers.

## Prerequisites
	
- ponyc
- pony-stable
- Wallaroo
        
See [Wallaroo Environment Setup Instructions](https://docs.wallaroolabs.com/pony-installation/).

## Building

Build Alerts (local aggregations) with
```bash
make
```

## alerts_local_aggregations arguments

In a shell, run the following to get help on arguments to the application:

```bash
./alerts_local_aggregations --help
```

### Input

For simplicity, we use a generator source that creates a stream of transaction
objects.

## Running Alerts

You will need four separate shells to run this application (please see [starting a new shell](https://docs.wallaroolabs.com/python-tutorial/starting-a-new-shell/) for details depending on your installation choice). Open each shell and go to the `examples/pony/alerts_local_aggregations` directory.

### Shell 1: Metrics

Start up the Metrics UI if you don't already have it running.

```bash
metrics_reporter_ui start
```

You can verify it started up correctly by visiting [http://localhost:4000](http://localhost:4000).

If you need to restart the UI, run the following.

```bash
metrics_reporter_ui restart
```

When it's time to stop the UI, run the following.

```bash
metrics_reporter_ui stop
```

If you need to start the UI after stopping it, run the following.

```bash
metrics_reporter_ui start
```

### Shell 2: Data Receiver

Run Data Receiver to listen for TCP output on `127.0.0.1` port `7002`:

```bash
data_receiver --ponythreads=1 --ponynoblock --listen 127.0.0.1:7002
```

### Shell 3: Alerts

Run the application:

```bash
alerts_local_aggregations --out 127.0.0.1:7002 \
  --metrics 127.0.0.1:5001 --control 127.0.0.1:6000 --data 127.0.0.1:6001 \
  --name worker-name --external 127.0.0.1:5050 --cluster-initializer \
  --ponynoblock
```

Because we're using a generator source, Wallaroo will start processing the input stream as soon as the application connects to the sink and finishes
initialization.

## Shell 4: Shutdown

You can shut down the cluster with this command at any time:

```bash
cluster_shutdown 127.0.0.1:5050
```

You can shut down Data Receiver by pressing `Ctrl-c` from its shell.

You can shut down the Metrics UI with the following command.

```bash
metrics_reporter_ui stop
```
