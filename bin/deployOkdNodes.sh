#!/bin/bash

set -x

# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://upstreamwithoutapaddle.com/home-lab/lab-intro/
CLUSTER_NAME="okd4"
INSTALL_URL="http://${BASTION_HOST}/install"
INVENTORY="${OKD_LAB_PATH}/inventory/okd4-lab"
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

CLUSTER_DOMAIN="dc${CLUSTER}.${LAB_DOMAIN}"
IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI
ROUTER=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1

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
  cat ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.yml | butane -d ${OKD_LAB_PATH}/ipxe-work-dir/ -o ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${NET_MAC//:/-}.ign

done

${SSH} root@${BASTION_HOST} "mkdir -p /www/install/fcos/ignition/${CLUSTER_NAME}"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/www/install/fcos/ignition/${CLUSTER_NAME}/
${SSH} root@${BASTION_HOST} "chmod 644 /www/install/fcos/ignition/${CLUSTER_NAME}/*"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/


