#!/bin/bash
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

set -x

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
    *)
        # put usage here:
    ;;
  esac
done

CLUSTER_DOMAIN="dc${CLUSTER}.${LAB_DOMAIN}"
IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI

for VARS in $(cat ${INVENTORY} | grep -v "#")
do
  HOST_NODE=$(echo ${VARS} | cut -d',' -f1)
  HOSTNAME=$(echo ${VARS} | cut -d',' -f2)
  ROLE=$(echo ${VARS} | cut -d',' -f7)
  ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh start ${HOSTNAME}"
  sleep 10
done
