#!/bin/bash

CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      HOST_CONFIG=${CONFIG_FILE}
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    *)
          # Put usage here:
    ;;
esac
done

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
SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
LOCAL_REGISTRY=$(yq e ".local-registry" ${CLUSTER_CONFIG})
OKD_REGISTRY=$(yq e ".remote-registry" ${CLUSTER_CONFIG})
PULL_SECRET=$(yq e ".secret-file" ${CLUSTER_CONFIG})
OKD_RELEASE=$(yq e ".okd-version" ${CLUSTER_CONFIG})

oc adm -a ${PULL_SECRET} release mirror --from=${OKD_REGISTRY}:${OKD_RELEASE} --to=${LOCAL_REGISTRY}/${OKD_RELEASE} --to-release-image=${LOCAL_REGISTRY}/${OKD_RELEASE}:${OKD_RELEASE}
