# Wallaroo Pulumi Orchestration

This module consists of the orchestration for Wallaroo using Pulumi.
So far we have only implemented Azure as the provider.

## Modules

The three modules are `azure-vnet`, `azure-cluster`, and `azure-k8s` .

### Azure-VNet

The VNet module handles creating the Virtual network along with the subnet, network security group, etc. The state for this is stored in Pulumi.

### Azure-Cluster

The Azure cluster module handles creating the actual Scale Set cluster of virtual machines in Azure and the related
Proximity Placement Group, etc. The state for this is stored in Pulumi.

The cluster module depends on the `azure-vnet` module and will fail if the `azure-vnet` module
hasn't been created yet.

### Azure-VM

The Azure VM module handles creating the single virtual machine in Azure and the related network components, etc. The state for this is stored in Pulumi. This module was designed for use in creating base images in Azure since this cannot be done via a VMSS.

### Azure-k8s

The k8s module handles creating the Azure AKS kubernetes along with the network policy, Service Principal, etc. The state for this is stored in Pulumi.

## Configuration

### General

Software needed:

* git
* make
* python
* pip
* sed
* awk
* tr
* grep
* egrep
* curl
* sort
* wc
* head
* tail
* jq
* nodejs
* npm
* azure-cli. Installation instructions can be found here: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest
* pulumi. Installation instructions can be found here: https://www.pulumi.com/docs/get-started/install/
* Installing ansible (need version `ansible-2.1.1.0`): `pip install 'ansible==2.1.1.0' --force-reinstall`
* Installing boto: `pip install boto`


Accounts needed:

* Azure Portal (ask Chuck)
* Pulumi

Configuration needed:

* Login to Azure cli using `az login` command.
* Running `az account list` should show you the `Internal Projects` Subscription
* Run `az account set --subscription "Internal Projects"` to set "internal Projects" as your default subscription
* Set up directory for ssh keys: `~/.ssh/azure/`
* Get private key:
```az keyvault secret download --name wallaroo-private-key --vault-name wallaroo-dev --file ~/.ssh/azure/wallaroo.pem```
* Get public key:
```az keyvault secret download --name wallaroo-public-key --vault-name wallaroo-dev --file ~/.ssh/azure/wallaroo.pem.pub```
* Change key permissions:
  ```sudo chmod 600 ~/.ssh/azure/wallaroo.pem ~/.ssh/azure/wallaroo.pem.pub```
* install Pulumi and Pulumi Azure Javascript packages:
  `cd azure-vnet && npm install` and `cd azure-cluster && npm install`

## Makefile

It is recommended that `make` be used to manage the Azure clusters (including
running Ansible) for a safe workflow.

NOTE: Command/options can be identified by running: `make help`

The `Makefile` enforces the following:

* Make sure Vnet is created (if required)
* Run pulumi stack/up/destroy command
* Run az ppg and vmss ceration/deletion commands (temporary until Pulumi supports vmss creation within a ppg)

### Azure Examples

**NOTE:** It is strongly recommended that a cluster be created with the `make cluster...` command and destroyed with the `make destroy...` command unless you are familiar with the intermediate steps that each command takes.

The following examples are to illustrate the features available and common use cases for the Azure provider:

* Detailed options/targets/help:
  `make help`
* Create and configure (with ansible) a cluster with name `sample`:
  `make cluster cluster_name=sample`
* Create and configure (with ansible) a cluster with name `sample` in location
  `eastus`:
  `make cluster cluster_name=sample location=eastus`
* Create and configure (with ansible) a cluster with name `sample` in location
  `eastus` and availabiilty zone `3`:
  `make cluster cluster_name=sample locatin=eastus availability_zone=3`
* Create and configure (with ansible) a cluster with name `sample` in location
  `eastus` and using VM Sku `Standard_F48s_v2`:
  `make cluster cluster_name=sample locatin=eastus vm_sku=Standard_F48s_v2`
* Destroy a cluster with name `sample`:
  `make destroy cluster_name=sample`
* Init a new cluster and vnet with name `sample` in `eastus`:
  `make init cluster_name=sample location=eastus`
* Create a new vnet with name `sample` in `eastus`:
  `make create-vnet cluster_name=sample location=eastus`
* Create a new ppg with name `sample` in `eastus`:
  `make create-ppg cluster_name=sample location=eastus`
* Create a new vmss cluster with name `sample` in `eastus`:
  `make create-vmss cluster_name=sample location=eastus`
* Import a created vmss cluster to Pulumi for state management with name `sample` in `eastus`:
  `make import-vmss cluster_name=sample location=eastus`
* Generate inventory for a created vmss cluster with name `sample` in `eastus`:
  `make generate-inventory cluster_name=sample location=eastus`
* Configure (with ansible) a cluster with name `sample` in location `eastus`:
  `make configure cluster_name=sample location=eastus`
* Configure (with ansible) a cluster with name `sample` using a custom pem file:
  `make configure cluster_name=sample cluster_pem=/path/to/custom/pem/file`
* Check ptpd offset for all followers in a cluster with name `sample`:
  `make check-ptpd-offsets cluster_name=sample`
* Run a custom ansible playbook in a cluster with name `sample` in location `eastus`:
  `make ansible-custom-playbook cluster_name=sample location=eastus ansible_playbook_path="../custom/path/to/playbook" extra_ansible_vars="custom_var=test" ansible_user=wallaroo`

### Azure VM Examples

Examples for orchestrating an Azure VM. This should primarily be used for OS image creations and single machine clusters.

* Create and configure (with ansible) a VM with name `sample` in location
  `eastus` and using VM Sku `Standard_F48s_v2`:
  `make vm cluster_name=sample location=eastus vm_sku=Standard_F48s_v2`
* Configure (with ansible) a VM with name `sample` in location
  `eastus` and using VM Sku `Standard_F48s_v2`:
  `make configure cluster_name=sample location=eastus vm_sku=Standard_F48s_v2`
* Destroy a VM with name `sample` in location
  `eastus` and using VM Sku `Standard_F48s_v2`:
  `make destroy-vm cluster_name=sample location=eastus vm_sku=Standard_F48s_v2`
* Initialize Pulumi stack for a VM with name `sample` in location
  `eastus` and using VM Sku `Standard_F48s_v2`:
  `make init-vm cluster_name=sample location=eastus vm_sku=Standard_F48s_v2`
* Generate inventory file for an exisiting VM with name `sample` in location
  `eastus`:
  `make generate-vm-inventory cluster_name=sample location=eastus`

#### k8s Examples

Currently, there is minimal configuration provided for spinning up an Azure AKS cluster. Below are the steps one can take to spin up and tear down a cluster.

* Spin up a Kubernetes cluster with the `cluster_name` of `testkube` in the default location: `make cluster-k8s cluster_name=testkube num_followers=0 vm_sku=Standard_F48s_v2 cluster_project_name=dev`
    * `cluster-k8s` does the following:
      - initializes the Pulumi state for the Kubernetes Cluster
      - creates the Kubernetes cluster in Azure
      - enables the HTTP routing addon
      - enables the Kubernetes Dashboard addon
      - sets the current Kubernetes context to the context for the newly created cluster

* Destroy the k8s/AKS cluster `testkube`: `make destroy-k8s cluster_name=testkube cluster_project_name=dev`
    * `destroy-k8s` does the following:
      - destroys the AKS cluster
      - destroys the associated Pulumi state

* Display the HTTP Routing Zone for an existing `kubetest` cluster: `make display-k8s-http-routing-zone-name cluster_name=kubetest cluster_project_name=dev`

* Manually set the current Kubernetes context to the context for an existing k8s cluster with the cluster name `kubetest`: `make set-k8s-context cluster_name=kubetest num_followers=0 vm_sku=Standard_F48s_v2 cluster_project_name=dev`

* Configure and display a public IP for ssh use into the AKS Node for an existing `kubetest` cluster: `make k8s-ssh-config cluster_name=kubetest`

## Debugging Ansible for Azure

Test ansible communication with the all cluster nodes:

`make test-ansible-connection cluster_name=sample`

## Manually cleaning up Azure resources

If for some reason the `make destroy` command isn't working correctly and deleting the Azure resources previously created, you can manually clean things up instead.
NOTE: You shouldn't have to do this unless `make destroy` repeatedly fails as it is safe to run multiple times until it succeeds.

Go into `Azure Portal -> All Resources` and find/delete the entries related to your cluster (the cluster_name is at the beginning of the resource name).

Go into `Azure Portal -> Resource Groups` and find/delete the entry related to your cluster (the cluster_name is at the beginning of the resource group name).

## Major recovery

If `make destroy` and `make cluster` are both failing for a cluster and it's in some sort of invalid state where pulumi state file doesn't match up with Azure reality any more.

Run the following to completely remove the pulumi state:

`make destroy-cluster-state destroy-vnet-state`

**WARNING:** It is very important to run this command passing in the cluster name and location arguments you would normally pass when creating a cluster as those arguments are used to determine which state file needs to be deleted.

**NOTE:** You will have to manually clean up any lingering resources after this but it should resolve the issues with the make command not working.
