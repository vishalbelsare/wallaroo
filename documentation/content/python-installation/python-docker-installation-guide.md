---
title: "Installing with Docker"
menu:
  hidden:
    parent: "pyinstallation"
    weight: 2
toc: false
---
To get you up and running quickly with Wallaroo, we have provided a Docker image which includes Wallaroo and related tools needed to run and modify a few example applications. We should warn that this Docker image was created with the intent of getting users started quickly with Wallaroo and is not intended to be a fully customizable development environment or suitable for production.

## Installing Docker

### MacOS

There are [instructions](https://docs.docker.com/docker-for-mac/) for getting Docker up and running on MacOS on the Docker website.  We recommend the 'Standard' version of the 'Docker for Mac' package.

Installing Docker will result in it running on your machine. After you reboot your machine, that will no longer be the case. In the future, you'll need to have Docker running in order to use a variety of commands in this book. We suggest that you [set up Docker to boot automatically](https://docs.docker.com/docker-for-mac/#general).

### Windows

There are [instructions](https://docs.docker.com/docker-for-windows/) for getting Docker up and running on Windows on the Docker website. We recommend installing the latest stable release, as there are breaking changes to our commands on edge releases. Installing Docker will result in it running on your machine. After you reboot your machine, that will no longer be the case. In the future, you'll need to have Docker running in order to use a variety of commands in this book. We suggest that you [set up Docker to boot automatically](https://docs.docker.com/docker-for-windows/#general).

Currently, development is only supported for Linux containers within Docker.

### Linux Ubuntu

There are [instructions](https://docs.docker.com/engine/installation/linux/ubuntu/) for getting Docker up and running on Ubuntu on the Docker website.

Installing Docker will result in it running on your machine. After you reboot your machine, that will no longer be the case. In the future, you'll need to have Docker running in order to use a variety of commands in this book. We suggest that you [set up Docker to boot automatically](https://docs.docker.com/engine/installation/linux/linux-postinstall/#configure-docker-to-start-on-boot).

All of the Docker commands throughout the rest of this manual assume that you have permission to run Docker commands as a non-root user. Follow the [Manage Docker as a non-root user](https://docs.docker.com/engine/installation/linux/linux-postinstall/#manage-docker-as-a-non-root-user) instructions to set that up. If you don't want to allow a non-root user to run Docker commands, you'll need to run `sudo docker` anywhere you see `docker` for a command.

## Wallaroo Docker Install

### Get the official Wallaroo image

```bash
docker pull wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}}
```

### What's Included in the Wallaroo Docker image

* **Machida**: runs Wallaroo Python applications for Python 2.7.

* **Machida3**: runs Wallaroo Python applications for Python 3.5+.

* **Giles Sender**: supplies data to Wallaroo applications over TCP.

* **Data Receiver**: receives data from Wallaroo over TCP.

* **Cluster Shutdown tool**: notifies the cluster to shut down cleanly.

* **Metrics UI**: receives and displays metrics for running Wallaroo applications.

* **Wallaroo Source Code**: full Wallaroo source code is provided, including Python example applications.

* **Machida with Resilience**: runs Wallaroo Python 2.7 applications and writes state to disk for recovery. This version of Machida can be used via the `machida-resilience` and `machida3-resilience` binaries. See the [Interworker Serialization and Resilience](/python-tutorial/interworker-serialization-and-resilience/) documentation for general information and the [Resilience](/operators-manual/command-line-options/#resilience) section of our [Command Line Options](/operators-manual/command-line-options/) documentation for information on its usage.

* **Machida3 with Resilience**: similar to Machida with Resilience, but for Python 3.5+.

### Additional Windows Setup

There are a few extra recommended steps that Windows users should make before continuing on to starting the Wallaroo Docker image. These steps are needed in order to persist the Wallaroo source code and Python virtual environment using [virtualenv](https://virtualenv.pypa.io/en/stable/) onto your local machine from within the Wallaroo Docker container. This will allow code changes and installed Python modules to persist beyond the lifecycle of a Docker container.

These steps are optional, but will require the removal of the `-v` options when starting the Wallaroo Docker image if you choose to opt out.

### Sharing your drive with Docker

You can find instructions for setting up a shared drive with Docker on Windows [here](https://docs.docker.com/docker-for-windows/#shared-drives).

The remainder of this tutorial assumes you shared the `C` drive, modify the commands as needed if sharing a different drive.

### Creating the Wallaroo and Python Virtualenv directories

We'll need to create two directories, one for the Wallaroo source code and one for the Python virtual environment.

To create the Wallaroo source code directory run the following command in Powershell or Command Prompt:

```bash
mkdir c:\wallaroo-docker\wallaroo-{{% wallaroo-version %}}\wallaroo-src
```
To create the Wallaroo Python virtual environment directory run the following command in Powershell or Command Prompt:

```bash
mkdir c:\wallaroo-docker\wallaroo-{{% wallaroo-version %}}\python-virtualenv
```

Your Windows machine is now all set to continue!

Awesome! All set. Time to try running your first Wallaroo application in Docker.

## Validate your installation

In this section, we're going to run an example Wallaroo application in Docker. By the time you are finished, you'll have validated that your Docker environment is set up and working correctly.

There are a few Wallaroo support applications that you'll be interacting with for the first time:

- Our Metrics UI allows you to monitor the performance and health of your applications.
- Data receiver is designed to capture TCP output from Wallaroo applications.
- Machida or Machida3, our program for running Wallaroo Python applications, for Python 2.7 and 3.5+ respectively..

You're going to set up our "Alerts" example application. We will use an internal generator source to generate simulated inputs into the system. Data receiver will receive the output, and our Metrics UI will be running so you can observe the overall performance.

The Metrics UI process will be run in the background. The other two processes (data_receiver and Wallaroo) will run in the foreground. We recommend that you run each process in a separate terminal.

{{% note %}}
If you haven't set up Docker to run without root, you will need to use `sudo` with your Docker commands.
{{% /note %}}

Let's get started!

Since Wallaroo is a distributed application, its components need to run separately, and concurrently, so that they may connect to one another to form the application cluster. For this example, you will need 5 separate terminal shells to start the docker container, run the metrics UI, run a sink, run the Alerts application, and eventually, to send a cluster shutdown command.

### Shell 1: Start the Wallaroo Docker container for Machida

{{< tabs >}}
{{< tab name="Unix" codelang="bash" >}}
docker run --rm -it --privileged -p 4000:4000 \
-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo \
-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida:/src/python-virtualenv \
--name wally \
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}}
{{< /tab >}}
{{< tab name="Powershell" codelang="bash" >}}
docker run --rm -it --privileged -p 4000:4000 `
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo `
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida:/src/python-virtualenv `
--name wally `
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}}
{{< /tab >}}
{{< tab name="Windows Command Prompt" codelang="bash" >}}
docker run --rm -it --privileged -p 4000:4000 ^
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo ^
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida:/src/python-virtualenv ^
--name wally ^
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}}
{{< /tab >}}
{{< /tabs >}}

### Shell 1: Start the Wallaroo Docker container for Machida3

{{< tabs >}}
{{< tab name="Unix" codelang="bash" >}}
docker run --rm -it --privileged -p 4000:4000 \
-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo \
-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida3:/src/python-virtualenv \
--name wally \
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}} -p python3
{{< /tab >}}
{{< tab name="Powershell" codelang="bash" >}}docker run --rm -it --privileged -p 4000:4000 `
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo `
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida3:/src/python-virtualenv `
--name wally `
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}} -p python3
{{< /tab >}}
{{< tab name="Windows Command Prompt" codelang="bash" >}}docker run --rm -it --privileged -p 4000:4000 ^
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo ^
-v c:/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida3:/src/python-virtualenv ^
--name wally ^
wallaroo-labs-docker-wallaroolabs.bintray.io/{{% docker-version-url %}} -p python3
{{< /tab >}}
{{< /tabs >}}

### Breaking down the Docker command

* `docker run`: The Docker command to start a new container.

* `--rm`: Automatically clean up the container and remove the file system on exit.

* `-it`: Allows us to work with interactive processes by allocating a tty for the container.

* `--privileged`: Gives the container access to the hosts' devices. This allows certain system calls to be used by Wallaroo, specifically `mbind` and `set_mempolicy`. This setting is optional, but by excluding it there will be a performance degradation in Wallaroo's processing capabilities.

* `-p 4000:4000`: Maps the default port for HTTP requests for the Metrics UI from the container to the host. This makes it possible to call up the Metrics UI from a browser on the host.

* `-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/wallaroo-src:/src/wallaroo`: Mounts a host directory as a data volume within the container. The first time you run this, an empty directory needs to be used in order for the Docker container to copy the Wallaroo source code to your host. If an empty directory is not used, we are assuming it is prepopulated with the Wallaroo source code from this point forward. This allows you to open and modify the Wallaroo source code with the editor of your choice on your host. The Wallaroo source code will persist on your machine after the container is stopped or deleted. This setting is optional, but without it you would need to use an editor within the container to view or modify the Wallaroo source code.

* `-v /tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida(machida3):/src/python-virtualenv`: Mounts a host directory as a data volume within the container. The first time this is run for the provided directory, this command will setup a persistent Python virtual environment using [virtualenv](https://virtualenv.pypa.io/en/stable/) for the container on your host. Thus, if you need to install any python modules using `pip` or `easy_install` they will persist after the container is stopped or deleted. This setting is optional, but without it, you will not have a persistent `virtualenv` for the container. We ask you to mount to `/tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida` when using `machida` and `/tmp/wallaroo-docker/wallaroo-{{% wallaroo-version %}}/python-virtualenv-machida3` when using `machida3` to avoid having conflicting `virtualenv` environments.

* `--name wally`: The name for the container. This setting is optional but makes it easier to reference the container in later commands.

* `-p python3`: This is a required argument if you will be running `machida3`. This argument allows us to set the python interpreter for the `virtualenv` environment to `python3` instead of the default `python2`. If you plan to run `machida`, this argument is not needed.

### Starting new shells

For each Shell you're expected to setup, you'd have to run the following to enter the Wallaroo Docker container:

Enter the Wallaroo Docker container:

{{< tabs >}}
{{< tab name="Machida" codelang="bash" >}}
docker exec -it wally env-setup
{{< /tab >}}
{{< tab name="Machida3" codelang="bash" >}}
docker exec -it wally env-setup -p python3
{{< /tab >}}
{{< /tabs >}}

This command will start a new Bash shell within the container, which will run the `env-setup` script to ensure our persistent Python `virtualenv` is set up.

### Shell 2: Start the Metrics UI

To start the Metrics UI run:

```bash
metrics_reporter_ui start
```

You can verify it started up correctly by visiting [http://localhost:4000](http://localhost:4000).

If you need to restart the UI, run:

```bash
metrics_reporter_ui restart
```

When it's time to stop the UI, run:

```bash
metrics_reporter_ui stop
```

If you need to start the UI after stopping it, run:

```bash
metrics_reporter_ui start
```

### Shell 3: Run Data Receiver

We'll use Data Receiver to listen for data from our Wallaroo application.

```bash
data_receiver --listen 127.0.0.1:5555 --no-write --ponythreads=1 --ponynoblock
```

Data Receiver will start up and receive data without creating any output. By default, it prints received data to standard out, but we are giving it the `--no-write` flag which results in no output.

### Shell 4: Run the "Alerts" Application

First, we'll need to get to the python Alerts example directory with the following command:

```bash
cd /src/wallaroo/examples/python/alerts_stateful
```

Now that we are in the proper directory, and the Metrics UI and Data receiver are up and running, we can run the application itself by executing the following command (remember to use the `machida3` executable instead of `machida` if you are using Python 3.X):

```bash
machida --application-module alerts \
  --out 127.0.0.1:5555 --metrics 127.0.0.1:5001 --control 127.0.0.1:6000 \
  --data 127.0.0.1:6001 --name worker-name --external 127.0.0.1:5050 \
  --cluster-initializer --ponythreads=1 --ponynoblock
```

This tells the "Alerts" application that it should write outgoing data to port `5555`, and send metrics data to port `5001`.

### Check Out Some Metrics

Once the application has successfully initialized, the internal test generator source will begin simulating inputs into the system. If you [visit the Metrics UI](http://localhost:4000), the landing page should show you that the "Alerts" application has successfully connected.

![Landing Page](/images/metrics/landing-page.png)

If your landing page resembles the one above, the "Alerts" application has successfully connected to the Metrics UI.

Now, let's have a look at some metrics. By clicking on the "Alerts" link, you'll be taken to the "Application Dashboard" page. On this page you should see metric stats for the following:

- a single pipeline: `Alerts`
- a single worker: `Initializer`
- a single computation: `check transaction total`

![Application Dashboard Page](/images/metrics/application-dashboard-page.png)

You'll see the metric stats update as data continues to be processed in our application.

You can then click into one of the elements within a category to get to a detailed metrics page for that element. If we were to click into the `check transaction total` computation, we'll be taken to this page:

![Computation Detailed Metrics page](/images/metrics/computation-detailed-metrics-page.png)

Feel free to click around and get a feel for how the Metrics UI is set up and how it is used to monitor a running Wallaroo application. If you'd like a deeper dive into the Metrics UI, have a look at our [Monitoring Metrics with the Monitoring Hub](/operators-manual/metrics-ui/) section.

### Shell 5: Cluster Shutdown

You can shut down the cluster with this command at any time:

```bash
cluster_shutdown 127.0.0.1:5050
```

You can shut down Data Receiver by pressing Ctrl-c from its shell.

You can shut down the Metrics UI with the following command:

```bash
metrics_reporter_ui stop
```

### Wallaroo Container

To shut down the Wallaroo container, use the `docker stop` command in a shell on your host:

```bash
docker stop wally
```

This command will also terminate any active sessions you may have left open to the docker container.

For tips on editing existing Wallaroo example code or installing Python modules within Docker, have a look at our [Tips for using Wallaroo in Docker](/appendix/wallaroo-docker-tips/) section.
