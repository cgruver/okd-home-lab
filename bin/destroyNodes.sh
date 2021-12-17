#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RESET_LB=false
DELETE_BOOTSTRAP=false
DELETE_CLUSTER=false
DELETE_WORKER=false
DELETE_KVM_HOSTS=false
W_HOST_INDEX=""
K_HOST_INDEX=""
M_HOST_INDEX=""
NODE_COUNT=0
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
      DELETE_BOOTSTRAP=true
      shift
    ;;
    -w=*|--worker=*)
      DELETE_WORKER=true
      W_HOST_INDEX="${i#*=}"
      shift
    ;;
    -r|--reset)
      RESET_LB=true
      DELETE_CLUSTER=true
      DELETE_WORKER=true
      shift
    ;;
    -k=*|--kvm-host=*)
      DELETE_KVM_HOST=true
      K_HOST_INDEX="${i#*=}"
      shift
    ;;
    -m=*|--master=*)
      M_HOST_INDEX="${i#*=}"
      shift
    ;;
    *)
      # put usage here:
    ;;
  esac
done

# Destroy the VM
function deleteNodeVm() {
  
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

# Destroy a physical host:
function destroyMetal() {
  local user=${1}
  local hostname=${2}
  local boot_dev=${3}

  ${SSH} -o ConnectTimeout=5 ${user}@${hostname}.${DOMAIN} "sudo wipefs -a /dev/${boot_dev} && sudo dd if=/dev/zero of=/dev/${boot_dev} bs=512 count=1 && sudo poweroff"
}

# Remove the iPXE boot files
function deletePxeConfig() {

  local mac_addr=${1}
  
  ${SSH} root@${ROUTER} "rm -f /data/tftpboot/ipxe/${mac_addr//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${mac_addr//:/-}.ign"
}

# Remove DNS Records
function deleteDns() {
  local key=${1}
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${DOMAIN} | grep -v ${key} > /tmp/db.${DOMAIN} && cp /tmp/db.${DOMAIN} /etc/bind/db.${DOMAIN}"
  ${SSH} root@${ROUTER} "cat /etc/bind/db.${NET_PREFIX_ARPA} | grep -v ${key} > /tmp/db.${NET_PREFIX_ARPA} && cp /tmp/db.${NET_PREFIX_ARPA} /etc/bind/db.${NET_PREFIX_ARPA}"
}

# Validate options and set vars
function validateAndSetVars() {
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

  if [[ $(yq e ".compute-nodes.metal" ${CLUSTER_CONFIG}) == "true" ]] # Bare Metal Nodes
  then
    let NODE_COUNT=$(yq e .compute-nodes.okd-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
  else
    let NODE_COUNT=$(yq e .compute-nodes.kvm-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
  fi

  if [[ ${DELETE_WORKER} == "true" ]] && [[ ${W_HOST_INDEX} != "-1" ]]
  then
    if ![[ ${W_HOST_INDEX} == ?(-)+([:digit:]) ]]
    then
      echo "option -w=<index>, index must be a positive integer indicating the node to delete, or -1 to delete all worker nodes."
      exit 1
    elif [[ ${W_HOST_INDEX} -ge ${NODE_COUNT} ]] || [[ ${W_HOST_INDEX} -lt 0 ]]
    then
      echo "option -w=<index>, index must be a positive integer indicating the node to delete, or -1 to delete all worker nodes."
      exit 1
    fi
  fi
}

validateAndSetVars

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
    deleteNodeVm ${host_name} ${kvm_host}
  fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-bs
  ${SSH} root@${ROUTER} "cp /etc/haproxy.no-bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy stop && /etc/init.d/haproxy start"
fi

if [[ ${DELETE_WORKER} == "true" ]]
then
  if [[ $(yq e ".compute-nodes.metal" ${CLUSTER_CONFIG}) == "true" ]] # Bare Metal Nodes
  then
    let NODE_COUNT=$(yq e .compute-nodes.okd-hosts ${CLUSTER_CONFIG} | yq e 'length' -)
    if [[ ${W_HOST_INDEX} == "-1" ]] # Delete all Nodes
    then
      let i=0
      let j=${NODE_COUNT}
    else # Just delete one node
      let i=${W_HOST_INDEX}
      NODE_COUNT=$(( ${i} + 1 ))
      if [[ i -lt ${NODE_COUNT} ]] && [[ i -ge 0 ]]
      then
        
      else
        echo "The worker node index must be between 0 and $(( ${NODE_COUNT} -1 ))"
        exit 1
      fi
    while [[ i -lt ${j} ]]
      do
        boot_dev=$(yq e ".compute-nodes.okd-hosts.${i}.boot-dev" ${CLUSTER_CONFIG})
        destroyMetal core ${CLUSTER_NAME}-worker-${i}.${DOMAIN} ${boot_dev}
        deleteDns ${CLUSTER_NAME}-worker-${i}-${DOMAIN}
        deletePxeConfig $(yq e ".compute-nodes.okd-hosts.${i}.mac-addr" ${CLUSTER_CONFIG})
        i=$(( ${i} + 1 ))
      done
    fi
  else # KVM Nodes
    
    if [[ ${W_HOST_INDEX} == "-1" ]]
    then
      let i=0
      while [[ i -lt ${NODE_COUNT} ]]
      do
        kvm_host=$(yq e .compute-nodes.kvm-hosts.${i} ${CLUSTER_CONFIG})
        deleteNodeVm ${CLUSTER_NAME}-worker-${i} ${kvm_host}
        deleteDns ${CLUSTER_NAME}-worker-${i}-${DOMAIN}
        i=$(( ${i} + 1 ))
      done
    else
      let i=${W_HOST_INDEX}
      if [[ i -lt ${NODE_COUNT} ]] && [[ i -ge 0 ]]
      then
        kvm_host=$(yq e .compute-nodes.kvm-hosts.${i} ${CLUSTER_CONFIG})
        deleteNodeVm ${CLUSTER_NAME}-worker-${i} ${kvm_host}
        deleteDns ${CLUSTER_NAME}-worker-${i}-${DOMAIN}
      else
        echo "The worker node index must be between 0 and $(( ${NODE_COUNT} -1 ))"
        exit 1
      fi
    fi
  fi
fi

if [[ ${DELETE_CLUSTER} == "true" ]]
then
  #Delete Control Plane Nodes:
  if [[ $(yq e ".control-plane.metal" ${CLUSTER_CONFIG}) == "true" ]]
  then
    boot_dev=$(yq e ".control-plane.okd-hosts.${i}.boot-dev" ${CLUSTER_CONFIG})
    for i in 0 1 2
    do
      destroyMetal core ${CLUSTER_NAME}-master-${i}.${DOMAIN} ${boot_dev}
      deletePxeConfig $(yq e ".control-plane.okd-hosts.${i}.mac-addr" ${CLUSTER_CONFIG})
    done
  else
    for i in 0 1 2
    do
      kvm_host=$(yq e .control-plane.kvm-hosts.${i} ${CLUSTER_CONFIG})
      deleteNodeVm ${CLUSTER_NAME}-master-${i} ${kvm_host}
    done
  fi
  deleteDns ${CLUSTER_NAME}-${DOMAIN}-cp
fi

if [[ ${RESET_LB} == "true" ]]
then
  ${SSH} root@${ROUTER} "cp /etc/haproxy.bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy stop && /etc/init.d/haproxy start" 
fi

if [[ ${DELETE_KVM_HOSTS} == "true" ]]
then

fi

${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
