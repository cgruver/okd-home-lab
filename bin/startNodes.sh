#!/bin/bash
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
BOOTSTRAP=false
MASTER=false
WORKER=false
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
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
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh start ${host_name}"
}

DONE=false
DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
let i=0
while [[ i -lt ${DOMAIN_COUNT} ]]
do
  domain_name=$(yq e ".sub-domain-configs.[${i}].name" ${CONFIG_FILE})
  if [[ ${domain_name} == ${SUB_DOMAIN} ]]
  then
    INDEX=${i}
    DONE=true
    break
  fi
  i=$(( ${i} + 1 ))
done
if [[ ${DONE} == "false" ]]
then
  echo "Domain Entry Not Found In Config File."
  exit 1
fi

SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
CLUSTER_NAME=$(yq e ".cluster-name" ${CLUSTER_CONFIG})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"

if [[ ${BOOTSTRAP} == "true" ]]
then
  host_name="$(yq e .cluster-name ${CLUSTER_CONFIG})-bootstrap"
  kvm_host=$(yq e .bootstrap.kvm-host ${CLUSTER_CONFIG})
  startNode ${kvm_host} ${host_name}
fi

if [[ ${MASTER} == "true" ]]
then
  for i in 0 1 2
  do
    kvm_host=$(yq e .control-plane.kvm-hosts.${i} ${CLUSTER_CONFIG})
    startNode ${kvm_host} ${CLUSTER_NAME}-master-${i}
    echo "Pause for 15 seconds to stagger node start up."
    sleep 15
  done
fi

if [[ ${WORKER} == "true" ]]
then
  let NODE_COUNT=$(yq e .compute-nodes.kvm-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
  let i=0
  while [[ i -lt ${NODE_COUNT} ]]
  do
    kvm_host=$(yq e .compute-nodes.kvm-hosts.${i} ${CLUSTER_CONFIG})
    startNode ${kvm_host} ${CLUSTER_NAME}-worker-${i}
    echo "Pause for 15 seconds to stagger node start up."
    sleep 15
    i=$(( ${i} + 1 ))
  done
fi
