#!/bin/bash

set -x
INIT_CLUSTER=false
ADD_WORKER=false
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
      *)
            # put usage here:
      ;;
  esac
done

function createControlPlaneDNS() {
cat << EOF | ssh root@${ROUTER} "cat >> /etc/bind/db.${CLUSTER_DOMAIN}
${CLUSTER_NAME}-bootstrap.${CLUSTER_DOMAIN}.  IN      A      ${NET_PREFIX}.49
${CLUSTER_NAME}-lb01.${CLUSTER_DOMAIN}.       IN      A      ${NET_PREFIX}.2
*.apps.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.     IN      A      ${NET_PREFIX}.2
api.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.        IN      A      ${NET_PREFIX}.2
api-int.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.    IN      A      ${NET_PREFIX}.2
${CLUSTER_NAME}-master-0.${CLUSTER_DOMAIN}.   IN      A      ${NET_PREFIX}.60
etcd-0.${CLUSTER_DOMAIN}.          IN      A      ${NET_PREFIX}.60
${CLUSTER_NAME}-master-1.${CLUSTER_DOMAIN}.   IN      A      ${NET_PREFIX}.61
etcd-1.${CLUSTER_DOMAIN}.          IN      A      ${NET_PREFIX}.61
${CLUSTER_NAME}-master-2.${CLUSTER_DOMAIN}.   IN      A      ${NET_PREFIX}.62
etcd-2.${CLUSTER_DOMAIN}.          IN      A      ${NET_PREFIX}.62
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${CLUSTER_DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${CLUSTER_DOMAIN}    86400     IN    SRV     0    10    2380    etcd-1.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${CLUSTER_DOMAIN}    86400     IN    SRV     0    10    2380    etcd-2.${CLUSTER_NAME}.${CLUSTER_DOMAIN}.
EOF

cat << EOF | ssh root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}
2.${NET_PREFIX_ARPA}     IN      PTR     ${CLUSTER_NAME}-lb01.${CLUSTER_DOMAIN}.
49.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-bootstrap.${CLUSTER_DOMAIN}.  
60.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-0.${CLUSTER_DOMAIN}. 
61.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-1.${CLUSTER_DOMAIN}. 
62.${NET_PREFIX_ARPA}    IN      PTR     ${CLUSTER_NAME}-master-2.${CLUSTER_DOMAIN}. 
EOF

${SSH} root@${ROUTER} "/etc/init.d/named restart"

}

function createInstallConfig() {
cat << EOF > ${OKD_LAB_PATH}/install-config-upi.yaml
apiVersion: v1
baseDomain: ${CLUSTER_DOMAIN}
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
  - nexus.${LAB_DOMAIN}:5001/${OKD_RELEASE}
  source: quay.io/openshift/okd
- mirrors:
  - nexus.${LAB_DOMAIN}:5001/${OKD_RELEASE}
  source: quay.io/openshift/okd-content
EOF
}

function configOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${mac//:/-}.yml
variant: fcos
version: 1.2.0
ignition:
  config:
    merge:
      - local: ${role}.ign
storage:
  files:
    - path: /etc/zincati/config.d/90-disable-feature.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          enabled = false
    - path: /etc/systemd/network/25-nic0.link
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=${mac}
          [Link]
          Name=nic0
    - path: /etc/NetworkManager/system-connections/nic0.nmconnection
      mode: 0600
      overwrite: true
      contents:
        inline: |
          [connection]
          type=ethernet
          interface-name=nic0

          [ethernet]
          mac-address=${mac}

          [ipv4]
          method=manual
          addresses=${ip_addr}/255.255.255.0
          gateway=${ROUTER}
          dns=${ROUTER}
          dns-search=${CLUSTER_DOMAIN}
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          pool ${BASTION_HOST} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
EOF

cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/vmlinuz edd=off net.ifnames=1 rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=sda coreos.inst.ignition_url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}/${mac//:/-}.ign coreos.inst.platform_id=qemu console=ttyS0
initrd http://${BASTION_HOST}/install/fcos/initrd
initrd http://${BASTION_HOST}/install/fcos/rootfs.img

boot
EOF

}

function createOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local kvm_host=${3}
  local role=${4}
  local memory=${5}
  local cpu=${6}
  local root_vol=${7}
  local ceph_vol=${8}

  # Create the VM
  DISK_CONFIG="--disk size=${root_vol},path=/VirtualMachines/${host_name}/rootvol,bus=sata"
  if [ ${ceph_vol} != "0" ]
  then
    DISK_CONFIG="${DISK_CONFIG} --disk size=${ceph_vol},path=/VirtualMachines/${host_name}/datavol,bus=sata"
  fi
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "mkdir -p /VirtualMachines/${host_name}"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virt-install --print-xml 1 --name ${host_name} --memory ${memory} --vcpus ${cpu} --boot=hd,network,menu=on,useserial=on ${DISK_CONFIG} --network bridge=br0 --graphics none --noautoconsole --os-variant centos7.0 --cpu host-passthrough,match=exact > /VirtualMachines/${host_name}.xml"
  ${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh define /VirtualMachines/${host_name}.xml"

  # Get the MAC address for eth0 in the new VM  
  var=$(${SSH} root@${kvm_host}.${CLUSTER_DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
  NET_MAC=$(echo ${var} | cut -d" " -f5)

  # Create node specific files
  configOkdNode ${NODE_IP} ${host_name}.${CLUSTER_DOMAIN} ${NET_MAC} ${ROLE}
  cat ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.yml | butane -d ${OKD_LAB_PATH}/ipxe-work-dir/ -o ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.ign
}

CLUSTER_NAME=$(yq e .cluster-sub-domain ${CONFIG_FILE})
SUB_DOMAIN=$(yq e .cluster-name ${CONFIG_FILE})
ROUTER=$(yq e .router ${CONFIG_FILE})
CLUSTER_DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
NETWORK=$(yq e .network ${CONFIG_FILE})
INSTALL_URL="http://${BASTION_HOST}/install"

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

if [[ ${INIT_CLUSTER} == "true" ]]
then
  OKD_RELEASE=$(oc version --client=true | cut -d" " -f3)
  SSH_KEY=$(cat ${OKD_LAB_PATH}/id_rsa.pub)
  PULL_SECRET=$(cat ${OKD_LAB_PATH}/pull_secret.json)
  NEXUS_CERT=$(openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:5001 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  $line"; done)
  let KVM_NODES=$(yq e .control-plane.kvm-hosts ${CONFIG_FILE} | yq e 'length' -)
  if [[ KVM_NODES -eq 1 ]]
  then
    AZ=1
  elif [[ KVM_NODES -eq 3 ]]
    AZ=3
  else
    echo "This script only supports deploying the control-plane nodes on 1 or 3 KVM hosts"
    exit 1
  fi

  # Create and deploy ignition files
  rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
  rm -rf ${OKD_LAB_PATH}/okd-install-dir
  mkdir ${OKD_LAB_PATH}/okd-install-dir
  mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/ignition
  createInstallConfig
  cp ${OKD_LAB_PATH}/install-config-upi.yaml ${OKD_LAB_PATH}/okd-install-dir/install-config.yaml
  openshift-install --dir=${OKD_LAB_PATH}/okd-install-dir create ignition-configs
  cp ${OKD_LAB_PATH}/okd-install-dir/*.ign ${OKD_LAB_PATH}/ipxe-work-dir/

  # Create Bootstrap Node:
  host_name="$(yq e .cluster-name ${CONFIG_FILE})-bootstrap"
  kvm_host=$(yq e .bootstrap.kvm-host ${CONFIG_FILE})
  memory=$(yq e .bootstrap.memory ${CONFIG_FILE})
  cpu=$(yq e .bootstrap.cpu ${CONFIG_FILE})
  root_vol=$(yq e .bootstrap.root_vol ${CONFIG_FILE})
  createOkdNode ${NET_PREFIX}.49 ${host_name} ${kvm_host} bootstrap ${memory} ${cpu} ${root_vol} 0

  #Create Control Plane Nodes:
  memory=$(yq e .control-plane.memory ${CONFIG_FILE})
  cpu=$(yq e .control-plane.cpu ${CONFIG_FILE})
  root_vol=$(yq e .control-plane.root_vol ${CONFIG_FILE})
  if [[ ${AZ} == "1" ]]
  then
    kvm_host=$(yq e .master.control-plane.kvm-hosts.[0] ${CONFIG_FILE})
    createOkdNode ${NET_PREFIX}.60 ${CLUSTER_NAME}-master-0 ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
    createOkdNode ${NET_PREFIX}.61 ${CLUSTER_NAME}-master-1 ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
    createOkdNode ${NET_PREFIX}.62 ${CLUSTER_NAME}-master-2 ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
  else
    for i in 0 1 2
    do
      kvm_host=$(yq e .master.control-plane.kvm-hosts.[${i}] ${CONFIG_FILE})
      createOkdNode ${NET_PREFIX}.6${i} ${CLUSTER_NAME}-master-${i} ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
    done
  fi
  # Create DNS Records:
  createControlPlaneDNS
fi

if [[ ${ADD_WORKER} == "true" ]]
then

fi

${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/
${SSH} root@${BASTION_HOST} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/*"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/


