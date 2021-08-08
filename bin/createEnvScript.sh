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

mkdir -p ${OKD_LAB_PATH}/work-dir

IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI

if [[ ${EDGE} == true ]]
then

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router
export NETWORK=${EDGE_NETWORK}
export DOMAIN=${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=$(echo "${i1}.${i2}.${i3}.1")
export NETMASK=255.255.255.0
export FCOS_VER=34.20210711.3.0
export FCOS_STREAM=stable
EOF

else
cat << EOF > ${OKD_LAB_PATH}/work-dir/internal-router
export EDGE_NETWORK=${EDGE_NETWORK}
export NETWORK=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).0
export NETMASK=255.255.255.0
export DOMAIN=dc${CLUSTER}.${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export EDGE_ROUTER=$(echo "${i1}.${i2}.${i3}.1")
export EDGE_IP=$(echo "${i1}.${i2}.${i3}.$(( 1 + ${CLUSTER} ))")
export ROUTER=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1
export LB_IP=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).2
EOF

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router
export DC${CLUSTER}_ROUTER=$(echo "${i1}.${i2}.${i3}.$(( 1 + ${CLUSTER} ))")
export DC${CLUSTER}_NETWORK=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).0
EOF

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-zone
zone "dc${CLUSTER}.${LAB_DOMAIN}" {
    type stub;
    masters { ${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1; };
    file "stub.dc${CLUSTER}.${LAB_DOMAIN}";
};

EOF

fi
