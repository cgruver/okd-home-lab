#!/bin/bash

EDGE=false

for i in "$@"
do
  case ${i} in
    -e|--edge)
      EDGE=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: createEnvScript -e | -c=path/to/config/file"
    ;;
  esac
done

mkdir -p ${OKD_LAB_PATH}/work-dir

if [[ ${EDGE} == true ]]
then

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router
export NETWORK=${EDGE_NETWORK}
export DOMAIN=${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=${EDGE_ROUTER}
export NETMASK=255.255.255.0
export FCOS_VER=34.20210711.3.0
export FCOS_STREAM=stable
EOF

else
CLUSTER_NAME=$(yq e .cluster-name ${CONFIG_FILE})
SUB_DOMAIN=$(yq e .cluster-sub-domain ${CONFIG_FILE})
ROUTER=$(yq e .router ${CONFIG_FILE})
CLUSTER_DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
NETWORK=$(yq e .network ${CONFIG_FILE})
EDGE_IP=$(yq e .edge-ip ${CONFIG_FILE})
LB_IP=$(yq e .lb-ip ${CONFIG_FILE})

IFS=. read -r i1 i2 i3 i4 << EOI
${NETWORK}
EOI

cat << EOF > ${OKD_LAB_PATH}/work-dir/internal-router
export EDGE_NETWORK=${EDGE_NETWORK}
export NETWORK=${NETWORK}
export NETMASK=255.255.255.0
export DOMAIN=${SUB_DOMAIN}.${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export EDGE_ROUTER=${EDGE_ROUTER}
export EDGE_IP=${EDGE_IP}
export ROUTER=${ROUTER}
export LB_IP=${LB_IP}
EOF

A=$( echo ${SUB_DOMAIN} | tr "[:lower:]" "[:upper:]" )
cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-router
export ${A}_ROUTER=${EDGE_IP}
export ${A}_NETWORK=${NETWORK}
EOF

cat << EOF > ${OKD_LAB_PATH}/work-dir/edge-zone
zone "${SUB_DOMAIN}.${LAB_DOMAIN}" {
    type stub;
    masters { ${ROUTER}; };
    file "stub.${SUB_DOMAIN}.${LAB_DOMAIN}";
};

EOF

fi
