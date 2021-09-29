#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CLUSTER_NAME="okd4"
RESET_LB=false
DELETE_CLUSTER=false
DELETE_WORKER=false

for i in "$@"
do
case $i in
  -c=*|--config=*)
    CONFIG_FILE="${i#*=}"
    shift # past argument=value
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
  *)
    # put usage here:
  ;;
esac
done

function deleteNode() {
  
  local host_name=${1}
  local kvm_host=${2}

  var=$(${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
  NET_MAC=$(echo ${var} | cut -d" " -f5)

  # Remove the iPXE boot file
  ${SSH} root@${ROUTER} "rm -f /data/tftpboot/ipxe/${NET_MAC//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${NET_MAC//:/-}.ign"

  # Destroy the VM
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh destroy ${host_name}"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh undefine ${host_name}"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh pool-destroy ${host_name}"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh pool-undefine ${host_name}"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "rm -rf /VirtualMachines/${host_name}"
}

CLUSTER_NAME=$(yq e .cluster-name ${CONFIG_FILE})
SUB_DOMAIN=$(yq e .cluster-sub-domain ${CONFIG_FILE})
ROUTER=$(yq e .router ${CONFIG_FILE})
CLUSTER_DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
NETWORK=$(yq e .network ${CONFIG_FILE})
INSTALL_URL="http://${BASTION_HOST}/install"

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

if [[ ${DELETE_CLUSTER} == "true" ]]
then
  let KVM_NODES=$(yq e .control-plane.kvm-hosts ${CONFIG_FILE} | yq e 'length' -)
  if [[ KVM_NODES -eq 1 ]]
  then
    AZ=1
  elif [[ KVM_NODES -eq 3 ]]
    AZ=3
  fi
  #Delete Bootstrap
  host_name="$(yq e .cluster-name ${CONFIG_FILE})-bootstrap"
  kvm_host=$(yq e .bootstrap.kvm-host ${CONFIG_FILE})

  deleteNode ${host_name} ${kvm_host}

  #Delete Control Plane Nodes:
  if [[ ${AZ} == "1" ]]
  then
    kvm_host=$(yq e .master.control-plane.kvm-hosts.[0] ${CONFIG_FILE})
    deleteNode ${CLUSTER_NAME}-master-0 ${kvm_host}
    deleteNode ${CLUSTER_NAME}-master-1 ${kvm_host}
    deleteNode ${CLUSTER_NAME}-master-2 ${kvm_host}
  else
    for i in 0 1 2
    do
      kvm_host=$(yq e .master.control-plane.kvm-hosts.[${i}] ${CONFIG_FILE})
      deleteNode ${CLUSTER_NAME}-master-${i} ${kvm_host}
    done
  fi
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${CLUSTER_DOMAIN} | grep -v ${CLUSTER_NAME}-${CLUSTER_DOMAIN}-cp > /tmp/db.${CLUSTER_DOMAIN} && cp /tmp/db.${CLUSTER_DOMAIN} /etc/bind/db.${CLUSTER_DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${CLUSTER_NAME}-${CLUSTER_DOMAIN}-cp > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
fi

if [[ ${DELETE_WORKER} == "true" ]]
then
  let NODE_COUNT=$(yq e .compute-nodes.kvm-hosts ${CONFIG_FILE} | yq e 'length' -)
  let i=0
  while [[ i -lt ${NODE_COUNT} ]]
  do
    kvm_host=$(yq e .compute-nodes.kvm-hosts.[${i}] ${CONFIG_FILE})
    deleteNode ${CLUSTER_NAME}-worker-${i} ${kvm_host}
    i=$(( ${i} + 1 ))
  done
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${CLUSTER_DOMAIN} | grep -v ${CLUSTER_NAME}-${CLUSTER_DOMAIN}-wk > /tmp/db.${CLUSTER_DOMAIN} && cp /tmp/db.${CLUSTER_DOMAIN} /etc/bind/db.${CLUSTER_DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${CLUSTER_NAME}-${CLUSTER_DOMAIN}-wk > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
fi

if [[ ${RESET_LB} == "true" ]]
then
  ${SSH} root@${ROUTER} "cp /etc/haproxy.bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy restart" 
fi

${SSH} root@${ROUTER} "/etc/init.d/named restart"
