#!/bin/bash

set -x
INIT_CLUSTER=false
ADD_WORKER=false
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONFIG_FILE=${LAB_CONFIG_FILE}

# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://upstreamwithoutapaddle.com/home-lab/lab-intro/

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift # past argument=value
    ;;
    -i|--init)
      INIT_CLUSTER=true
      shift
    ;;
    -w|--worker)
      ADD_WORKER=true
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
      *)
            # put usage here:
      ;;
  esac
done

function createControlPlaneDNS() {
cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/forward.zone
${CLUSTER_NAME}-bootstrap.${DOMAIN}.  IN      A      ${NET_PREFIX}.49 ; ${CLUSTER_NAME}-${DOMAIN}-bs
${CLUSTER_NAME}-lb01.${DOMAIN}.       IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-0.${DOMAIN}.   IN      A      ${NET_PREFIX}.60 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-0.${DOMAIN}.          IN      A      ${NET_PREFIX}.60 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-1.${DOMAIN}.   IN      A      ${NET_PREFIX}.61 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-1.${DOMAIN}.          IN      A      ${NET_PREFIX}.61 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-2.${DOMAIN}.   IN      A      ${NET_PREFIX}.62 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-2.${DOMAIN}.          IN      A      ${NET_PREFIX}.62 ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-1.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-2.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/reverse.zone
2.${NET_PREFIX_ARPA}     IN      PTR     ${CLUSTER_NAME}-lb01.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
49.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-bootstrap.${DOMAIN}.   ; ${CLUSTER_NAME}-${DOMAIN}-bs
60.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-0.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
61.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-1.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
62.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-2.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

}

function createInstallConfig() {
cat << EOF > ${OKD_LAB_PATH}/install-config-upi.yaml
apiVersion: v1
baseDomain: ${DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OpenShiftSDN
  clusterNetwork:
  - cidr: 10.100.0.0/14 
    hostPrefix: 23 
  serviceNetwork: 
  - 172.30.0.0/16
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 3
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: ${SSH_KEY}
additionalTrustBundle: |
${NEXUS_CERT}
imageContentSources:
- mirrors:
  - ${REGISTRY}/${OKD_RELEASE}
  source: quay.io/openshift/okd
- mirrors:
  - ${REGISTRY}/${OKD_RELEASE}
  source: quay.io/openshift/okd-content
EOF
}

function configOkdBaremetalNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

envsubst

envsubst < ${OKD_LAB_PATH}/okd-home-lab/okd-node-configs/node.ipxe > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe

}

function createOkdBaremetalNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac_addr=${3}
  local role=${4}

  # Create node specific files
  envsubst < ${OKD_LAB_PATH}/okd-home-lab/okd-node-configs/node.ipxe > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe
  
  configOkdBaremetalNode ${ip_addr} ${host_name}.${DOMAIN} ${NET_MAC} ${role}
  cat ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.yml | butane -d ${OKD_LAB_PATH}/ipxe-work-dir/ -o ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.ign
}

createOkdBootstrapNode() {

  local ip_addr=${1}
  local host_name=${2}
  local mac_addr=${3}
  local role=${4}
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
NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
REGISTRY=$(yq e ".local-registry" ${CLUSTER_CONFIG})
CLUSTER_NAME=$(yq e ".cluster-name" ${CLUSTER_CONFIG})
PULL_SECRET=$(yq e ".secret-file" ${CLUSTER_CONFIG})
INSTALL_URL="http://${BASTION_HOST}/install"

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
rm -rf ${OKD_LAB_PATH}/dns-work-dir
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/ignition
mkdir -p ${OKD_LAB_PATH}/dns-work-dir

if [[ ${INIT_CLUSTER} == "true" ]]
then
  OKD_RELEASE=$(oc version --client=true | cut -d" " -f3)
  SSH_KEY=$(cat ${OKD_LAB_PATH}/id_rsa.pub)
  PULL_SECRET=$(cat ${OKD_LAB_PATH}/pull_secret.json)
  NEXUS_CERT=$(openssl s_client -showcerts -connect ${REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  $line"; done)
  KVM_NODES=$(yq e ".control-plane.kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${KVM_NODES} != "3" ]]
  then
    echo "There must be 3 KVM host entries for the control plane."
    exit 1
  fi

  # Create and deploy ignition files
  rm -rf ${OKD_LAB_PATH}/okd-install-dir
  mkdir ${OKD_LAB_PATH}/okd-install-dir
  createInstallConfig
  cp ${OKD_LAB_PATH}/install-config-upi.yaml ${OKD_LAB_PATH}/okd-install-dir/install-config.yaml
  openshift-install --dir=${OKD_LAB_PATH}/okd-install-dir create ignition-configs
  cp ${OKD_LAB_PATH}/okd-install-dir/*.ign ${OKD_LAB_PATH}/ipxe-work-dir/

  # Create Bootstrap Node:
  host_name="$(yq e ".cluster-name" ${CLUSTER_CONFIG})-bootstrap"
  kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
  memory=$(yq e ".bootstrap.memory" ${CLUSTER_CONFIG})
  cpu=$(yq e ".bootstrap.cpu" ${CLUSTER_CONFIG})
  root_vol=$(yq e ".bootstrap.root_vol" ${CLUSTER_CONFIG})
  createOkdBaremetalNode ${NET_PREFIX}.49 ${host_name} ${kvm_host} bootstrap ${memory} ${cpu} ${root_vol} 0

  #Create Control Plane Nodes:
  memory=$(yq e ".control-plane.memory" ${CLUSTER_CONFIG})
  cpu=$(yq e ".control-plane.cpu" ${CLUSTER_CONFIG})
  root_vol=$(yq e ".control-plane.root_vol" ${CLUSTER_CONFIG})
  for i in 0 1 2
  do
    kvm_host=$(yq e ".control-plane.kvm-hosts.${i}" ${CLUSTER_CONFIG})
    createOkdBaremetalNode ${NET_PREFIX}.6${i} ${CLUSTER_NAME}-master-${i} ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
  done
  # Create DNS Records:
  createControlPlaneDNS
fi

if [[ ${ADD_WORKER} == "true" ]]
then
  let NODE_COUNT=$(yq e ".compute-nodes.kvm-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${INIT_CLUSTER} != "true" ]]
  then
    oc extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${OKD_LAB_PATH}/ipxe-work-dir/worker.ign
  fi
  
  memory=$(yq e ".compute-nodes.memory" ${CLUSTER_CONFIG})
  cpu=$(yq e ".compute-nodes.cpu" ${CLUSTER_CONFIG})
  root_vol=$(yq e ".compute-nodes.root_vol" ${CLUSTER_CONFIG})
  ceph_vol=$(yq e ".compute-nodes.ceph_vol" ${CLUSTER_CONFIG})
  
  let i=0
  let j=70
  while [[ i -lt ${NODE_COUNT} ]]
  do
    kvm_host=$(yq e ".compute-nodes.kvm-hosts.${i}" ${CLUSTER_CONFIG})
    echo "${CLUSTER_NAME}-worker-${i}.${DOMAIN}.   IN      A      ${NET_PREFIX}.${j} ; ${CLUSTER_NAME}-${DOMAIN}-wk" >> ${OKD_LAB_PATH}/dns-work-dir/forward.zone
    echo "${j}.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-worker-${i}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-wk" >> ${OKD_LAB_PATH}/dns-work-dir/reverse.zone
    createOkdBaremetalNode ${NET_PREFIX}.${j} ${CLUSTER_NAME}-worker-${i} ${kvm_host} worker ${memory} ${cpu} ${root_vol} ${ceph_vol}
    i=$(( ${i} + 1 ))
    j=$(( ${j} + 1 ))
  done
fi

cat ${OKD_LAB_PATH}/dns-work-dir/forward.zone | ssh root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
cat ${OKD_LAB_PATH}/dns-work-dir/reverse.zone | ssh root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
${SSH} root@${ROUTER} "/etc/init.d/named restart"
${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/
${SSH} root@${BASTION_HOST} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/*"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/
