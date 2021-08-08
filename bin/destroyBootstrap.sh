#!/bin/bash
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
ROUTER=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1

for VARS in $(cat ${INVENTORY} | grep -v "#")
do
  HOST_NODE=$(echo ${VARS} | cut -d',' -f1)
  HOSTNAME=$(echo ${VARS} | cut -d',' -f2)
  ROLE=$(echo ${VARS} | cut -d',' -f7)

  if [[ ${ROLE} == "bootstrap" ]]
  then
    ${SSH} root@${HOST_NODE}.${CLUSTER_DOMAIN} "virsh destroy ${HOSTNAME} && virsh undefine ${HOSTNAME} && virsh pool-destroy ${HOSTNAME} && virsh pool-undefine ${HOSTNAME} && rm -rf /VirtualMachines/${HOSTNAME}"
  fi
done

sleep 5

${SSH} root@${ROUTER} "cp /etc/haproxy.cfg /etc/haproxy.bootstrap && cat /etc/haproxy.cfg | grep -v bootstrap > /tmp/haproxy.no-bootstrap && mv /tmp/haproxy.no-bootstrap /etc/haproxy.cfg && /etc/init.d/haproxy restart"
