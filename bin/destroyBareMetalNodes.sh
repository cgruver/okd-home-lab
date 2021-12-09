#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CLUSTER_NAME="okd4"
RESET_LB=false
DELETE_BOOTSTRAP=false
DELETE_CLUSTER=false
DELETE_WORKER=false
DELETE_KVM_HOSTS=false
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift # past argument=value
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    -b|--bootstrap)
      DELETE_BOOTSTRAP=true
      shift
    ;;
    -w|--worker)
      DELETE_WORKER=true
      shift
    ;;
    -r|--reset)
      RESET_LB=true
      DELETE_CLUSTER=true
      DELETE_WORKER=true
      shift
    ;;
    -k|--kvm-hosts)
      DELETE_KVM_HOSTS=true
      shift
    ;;
    *)
      # put usage here:
    ;;
  esac
done

# Destroy the VM
function deleteNode() {
  
  local host_name=${1}
  local kvm_host=${2}

  var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
  NET_MAC=$(echo ${var} | cut -d" " -f5)

  deletePxeConfig ${NET_MAC}

  ${SSH} root@${kvm_host}.${DOMAIN} "virsh destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-destroy ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh pool-undefine ${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "rm -rf /VirtualMachines/${host_name}"
}

# Remove the iPXE boot files
function deletePxeConfig() {

  local mac_addr=${1}
  
  ${SSH} root@${ROUTER} "rm -f /data/tftpboot/ipxe/${mac_addr//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${mac_addr//:/-}.ign"
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

LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
CLUSTER_NAME=$(yq e ".cluster-name" ${CLUSTER_CONFIG})

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

if [[ ${DELETE_BOOTSTRAP} == "true" ]]
then
  #Delete Bootstrap
  if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    deletePxeConfig $(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
    kill $(ps -ef | grep qemu | grep bootstrap | awk '{print $2}')
    rm -rf ${OKD_LAB_PATH}/bootstrap
  else
    host_name="${CLUSTER_NAME}-bootstrap"
    kvm_host=$(yq e .bootstrap.kvm-host ${CLUSTER_CONFIG})

    deleteNode ${host_name} ${kvm_host}
  fi
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${CLUSTER_NAME}-${DOMAIN}-bs > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${CLUSTER_NAME}-${DOMAIN}-bs > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
  ${SSH} root@${ROUTER} "cp /etc/haproxy.no-bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy stop && /etc/init.d/haproxy start"
fi

if [[ ${DELETE_WORKER} == "true" ]]
then
  if [[ $(yq e ".compute-nodes.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    let NODE_COUNT=$(yq e .compute-nodes.okd-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
    let i=0
    boot_dev=$(yq e ".compute-nodes.okd-hosts.${i}.boot-dev" ${CLUSTER_CONFIG})
    while [[ i -lt ${NODE_COUNT} ]]
    do
      ${SSH} -o ConnectTimeout=5 core@okd4-worker-${i}.${SUB_DOMAIN}.${LAB_DOMAIN} "sudo dd if=/dev/zero of=/dev/${boot_dev} bs=512 count=1 && sudo poweroff"
      deletePxeConfig $(yq e ".compute-nodes.okd-hosts.${i}.mac-addr" ${CLUSTER_CONFIG})
      i=$(( ${i} + 1 ))
    done
  else
    let NODE_COUNT=$(yq e .compute-nodes.kvm-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
    let i=0
    while [[ i -lt ${NODE_COUNT} ]]
    do
      kvm_host=$(yq e .compute-nodes.kvm-hosts.${i} ${CLUSTER_CONFIG})
      deleteNode ${CLUSTER_NAME}-worker-${i} ${kvm_host}
      i=$(( ${i} + 1 ))
    done
  fi
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${CLUSTER_NAME}-${DOMAIN}-wk > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${CLUSTER_NAME}-${DOMAIN}-wk > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
fi

if [[ ${DELETE_CLUSTER} == "true" ]]
then
  #Delete Control Plane Nodes:
  if [[ $(yq e ".control-plane.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    boot_dev=$(yq e ".control-plane.okd-hosts.${i}.boot-dev" ${CLUSTER_CONFIG})
    for i in 0 1 2
    do
      deletePxeConfig $(yq e ".control-plane.okd-hosts.${i}.mac-addr" ${CLUSTER_CONFIG})
      ${SSH} -o ConnectTimeout=5 core@okd4-master-${i}.${SUB_DOMAIN}.${LAB_DOMAIN} "sudo dd if=/dev/zero of=/dev/${boot_dev} bs=512 count=1 && sudo poweroff"
    done
  else
    for i in 0 1 2
    do
      kvm_host=$(yq e .control-plane.kvm-hosts.${i} ${CLUSTER_CONFIG})
      deleteNode ${CLUSTER_NAME}-master-${i} ${kvm_host}
    done
  fi
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${CLUSTER_NAME}-${DOMAIN}-cp > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${CLUSTER_NAME}-${DOMAIN}-cp > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
fi

if [[ ${RESET_LB} == "true" ]]
then
  ${SSH} root@${ROUTER} "cp /etc/haproxy.bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy stop && /etc/init.d/haproxy start" 
fi

${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
