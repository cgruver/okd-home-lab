#!/bin/bash
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
BOOTSTRAP=false
MASTER=false
WORKER=false

set -x

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -b|--bootstrap)
      BOOTSTRAP=true
      shift
    ;;
    -m|--master)
      MASTER=true
      shift
    ;;
    -w|--worker)
      WORKER=true
      shift
    ;;
    *)
        # put usage here:
    ;;
  esac
done

function startNode() {
  local kvm_host=${1}
  local host_name=${2}
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh start ${host_name}"
}

CLUSTER_NAME=$(yq e .cluster-name ${CONFIG_FILE})
SUB_DOMAIN=$(yq e .cluster-sub-domain ${CONFIG_FILE})
CLUSTER_DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"

if [[ ${BOOTSTRAP} == "true" ]]
then
  host_name="$(yq e .cluster-name ${CONFIG_FILE})-bootstrap"
  kvm_host=$(yq e .bootstrap.kvm-host ${CONFIG_FILE})
  startNode ${kvm_host} ${host_name}
fi

if [[ ${MASTER} == "true" ]]
then
  for i in 0 1 2
  do
    kvm_host=$(yq e .control-plane.kvm-hosts.${i} ${CONFIG_FILE})
    startNode ${kvm_host} ${CLUSTER_NAME}-master-${i}
    echo "Pause for 15 seconds to stagger node start up."
    sleep 15
  done
fi

if [[ ${WORKER} == "true" ]]
then
  let NODE_COUNT=$(yq e .compute-nodes.kvm-hosts ${CONFIG_FILE} | yq e 'length' -)
  let i=0
  while [[ i -lt ${NODE_COUNT} ]]
  do
    kvm_host=$(yq e .compute-nodes.kvm-hosts.${i} ${CONFIG_FILE})
    startNode ${kvm_host} ${CLUSTER_NAME}-worker-${i}
    echo "Pause for 15 seconds to stagger node start up."
    sleep 15
  done
fi
