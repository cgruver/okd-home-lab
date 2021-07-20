#!/bin/bash

EDGE=false

for i in "$@"
do
  case ${i} in
    -e|--edge)
    EDGE=true
    shift
    ;;
    -c=*|--cluster=*)
    let CLUSTER="${i#*=}"
    shift
    ;;
    *)
          echo "USAGE: createEnvScript -e | -c=<cluster number - 1,2,3,...>"
    ;;
  esac
done

IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI

if [[ ${EDGE} == true ]]
then

cat << EOF
export NETWORK=${EDGE_NETWORK}
export DOMAIN=${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=$(echo "${i1}.${i2}.${i3}.1")
export NETMASK=255.255.255.0
EOF

else
cat << EOF
export NETWORK=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1
export NETMASK=255.255.255.0
export DOMAIN=dc${CLUSTER}.${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1
export LB_IP=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).2
EOF

fi
