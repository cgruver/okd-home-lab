#!/bin/bash

set -x

# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://github.com/cgruver/okd4-UPI-Lab-Setup
CLUSTER_NAME="okd4"
INSTALL_URL="http://${BASTION_HOST}/install"
INVENTORY="${OKD_LAB_PATH}/inventory/okd4-lab"
LAB_PWD=$(cat ${OKD_LAB_PATH}/lab_guest_pw)
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

for i in "$@"
do
  case $i in
      -i=*|--inventory=*)
      INVENTORY="${i#*=}"
      shift # past argument=value
      ;;
      -c=*|--cluster=*)
      let CLUSTER=${i#*=}
      shift
      ;;
      -cn=*|--name=*)
      CLUSTER_NAME="${i#*=}"
      shift
      ;;
      *)
            # put usage here:
      ;;
  esac
done

CLUSTER_DOMAIN="dc${CLUSTER}.${LAB_DOMAIN}"
IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI
ROUTER=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1

function createInstallConfig() {

  SSH_KEY=$(cat ${OKD_LAB_PATH}/id_rsa.pub)
  PULL_SECRET=$(cat ${OKD_LAB_PATH}/pull_secret.json)
  NEXUS_CERT=$(openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:5001 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  $line"; done)

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
  - nexus.${LAB_DOMAIN}:5001/origin
  source: quay.io/openshift/okd
- mirrors:
  - nexus.${LAB_DOMAIN}:5001/origin
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
          addresses=${ip_addr}/${LAB_NETMASK}
          gateway=${ROUTER}
          dns=${ROUTER}
          dns-search=${CLUSTER_DOMAIN}
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
EOF

cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/vmlinuz edd=off net.ifnames=1 rd.neednet=1 coreos.inst=yes coreos.inst.install_dev=sda coreos.inst.ignition_url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}/${mac//:/-}.ign coreos.inst.platform_id=qemu console=ttyS0
initrd http://${BASTION_HOST}/install/fcos/initrd
initrd http://${BASTION_HOST}/install/fcos/rootfs.img

boot
EOF

}

# Create and deploy ignition files
rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
rm -rf ${OKD_LAB_PATH}/okd-install-dir
mkdir ${OKD_LAB_PATH}/okd-install-dir
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/ignition
createInstallConfig
cp ${OKD_LAB_PATH}/install-config-upi.yaml ${OKD_LAB_PATH}/okd-install-dir/install-config.yaml
openshift-install --dir=${OKD_LAB_PATH}/okd-install-dir create ignition-configs

# Create Virtual Machines from the inventory file
for VARS in $(cat ${INVENTORY} | grep -v "#")
do
  HOST_NODE=$(echo ${VARS} | cut -d',' -f1)
  HOSTNAME=$(echo ${VARS} | cut -d',' -f2)
  MEMORY=$(echo ${VARS} | cut -d',' -f3)
  CPU=$(echo ${VARS} | cut -d',' -f4)
  ROOT_VOL=$(echo ${VARS} | cut -d',' -f5)
  DATA_VOL=$(echo ${VARS} | cut -d',' -f6)
  ROLE=$(echo ${VARS} | cut -d',' -f7)

  DISK_LIST="--disk size=${ROOT_VOL},path=/VirtualMachines/${HOSTNAME}/rootvol,bus=sata"
  if [ ${DATA_VOL} != "0" ]
  then
    DISK_LIST="${DISK_LIST} --disk size=${DATA_VOL},path=/VirtualMachines/${HOSTNAME}/datavol,bus=sata"
  fi
  ARGS="--cpu host-passthrough,match=exact"

  # Get IP address for eth0
  NODE_IP=$(dig ${HOSTNAME}.${CLUSTER_DOMAIN} +short)
  NET_DEVICE="--network bridge=br0"

  # Create the VM
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "mkdir -p /VirtualMachines/${HOSTNAME}"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virt-install --print-xml 1 --name ${HOSTNAME} --memory ${MEMORY} --vcpus ${CPU} --boot=hd,network,menu=on,useserial=on ${DISK_LIST} ${NET_DEVICE} --graphics none --noautoconsole --os-variant centos7.0 ${ARGS} > /VirtualMachines/${HOSTNAME}.xml"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh define /VirtualMachines/${HOSTNAME}.xml"

  # Get the MAC address for eth0 in the new VM  
  var=$(${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh -q domiflist ${HOSTNAME} | grep br0")
  NET_MAC=$(echo ${var} | cut -d" " -f5)

  # Create node specific files
  configOkdNode ${NODE_IP} ${HOSTNAME}.${CLUSTER_DOMAIN} ${NET_MAC} ${ROLE}
  cat ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.yml | butane -d ${OKD_LAB_PATH}/okd-install-dir/ -o ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.ign

done

${SSH} root@${BASTION_HOST} "mkdir -p /www/install/fcos/ignition/${CLUSTER_NAME}"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/www/install/fcos/ignition/${CLUSTER_NAME}/
${SSH} root@${BASTION_HOST} "chmod 644 /www/install/fcos/ignition/${CLUSTER_NAME}/*"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/


