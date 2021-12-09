#!/bin/bash

CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
    -m|--mac)
      OS_VER=mac
      shift
    ;;
    -l|--linux)
      OS_VER=linux
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

CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
OKD_VERSION=$(yq e ".okd-version" ${CLUSTER_CONFIG})
BUTANE_VERSION=$(yq e ".butane-version" ${CLUSTER_CONFIG})

mkdir -p ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}
mkdir -p ${OKD_LAB_PATH}/tmp

wget -O ${OKD_LAB_PATH}/tmp/oc.tar.gz https://github.com/openshift/okd/releases/download/${OKD_VERSION}/openshift-client-${OS_VER}-${OKD_VERSION}.tar.gz
wget -O ${OKD_LAB_PATH}/tmp/oc-install.tar.gz https://github.com/openshift/okd/releases/download/${OKD_VERSION}/openshift-install-${OS_VER}-${OKD_VERSION}.tar.gz
wget -O ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}/butane https://github.com/coreos/butane/releases/download/v0.12.1/butane-x86_64-apple-darwin

tar -xzf ${OKD_LAB_PATH}/tmp/oc.tar.gz -C ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}
tar -xzf ${OKD_LAB_PATH}/tmp/oc-install.tar.gz -C ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}

chmod 700 ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}/*

rm -rf ${OKD_LAB_PATH}/tmp
