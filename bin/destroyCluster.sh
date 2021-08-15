#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CLUSTER_NAME="okd4"

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

for VARS in $(cat ${INVENTORY} | grep -v "#")
do
  HOST_NODE=$(echo ${VARS} | cut -d',' -f1)
  HOSTNAME=$(echo ${VARS} | cut -d',' -f2)

  var=$(${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh -q domiflist ${HOSTNAME} | grep br0")
  NET_MAC=$(echo ${var} | cut -d" " -f5)

  # Remove the iPXE boot file
  ${SSH} root@${ROUTER} "rm -f /data/tftpboot/ipxe/${NET_MAC//:/-}.ipxe"
  ${SSH} root@${BASTION_HOST} "rm -f /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}/${NET_MAC//:/-}.ign"

  # Destroy the VM
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh destroy ${HOSTNAME}"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh undefine ${HOSTNAME}"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh pool-destroy ${HOSTNAME}"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh pool-undefine ${HOSTNAME}"
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "rm -rf /VirtualMachines/${HOSTNAME}"
done

${SSH} root@${ROUTER} "cp /etc/haproxy.bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy restart" 
