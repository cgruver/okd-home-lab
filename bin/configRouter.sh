#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EDGE=false
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case ${i} in
    -e|--edge)
      EDGE=true
      shift
    ;;
    -i|--init)
      INIT=true
      shift
    ;;
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    -d=*|--domain=*)
      sub_domain="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: configRouter.sh -e -i -c=path/to/config/file -d=sub-domain-name"
    ;;
  esac
done

function createEdgeFiles() {
cat << EOF > ${OKD_LAB_PATH}/work-dir-router/edge-router
export NETWORK=${EDGE_NETWORK}
export DOMAIN=${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=${EDGE_ROUTER}
export NETMASK=${EDGE_NETMASK}
EOF
}

function createDomainFiles() {
IFS=. read -r i1 i2 i3 i4 << EOI
${ROUTER}
EOI
LB_IP=${i1}.${i2}.${i3}.$(( ${i4} + 1 ))

cat << EOF > ${OKD_LAB_PATH}/work-dir-router/internal-router
export EDGE_NETWORK=${EDGE_NETWORK}
export NETWORK=${NETWORK}
export NETMASK=${NETMASK}
export DOMAIN=${SUB_DOMAIN}.${LAB_DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export EDGE_ROUTER=${EDGE_ROUTER}
export EDGE_IP=${EDGE_IP}
export ROUTER=${ROUTER}
export LB_IP=${LB_IP}
EOF

cat << EOF > ${OKD_LAB_PATH}/work-dir-router/edge-zone
zone "${SUB_DOMAIN}.${LAB_DOMAIN}" {
    type stub;
    masters { ${ROUTER}; };
    file "stub.${SUB_DOMAIN}.${LAB_DOMAIN}";
};

EOF
}

function validateVars() {

  if [[ ${CONFIG_FILE} == "" ]]
  then
    echo "You must specify a lab configuration YAML file."
    exit 1
  fi

  if [[ ${sub_domain} != "" ]]
  then
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
    SUB_DOMAIN=${sub_domain}
  fi
  if [[ ${SUB_DOMAIN} == "" ]]
  then
    . labctx.sh
  fi
}

validateVars

EDGE_NETWORK=$(yq e ".network" ${CONFIG_FILE})
LAB_DOMAIN=$(yq e ".domain" ${CONFIG_FILE})
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
EDGE_ROUTER=$(yq e ".router" ${CONFIG_FILE})
EDGE_NETMASK=$(yq e ".netmask" ${CONFIG_FILE})

rm -rf ${OKD_LAB_PATH}/work-dir-router
mkdir -p ${OKD_LAB_PATH}/work-dir-router

if [[ ${INIT} == "true" ]]
then
  if [[ ${EDGE} == "true" ]]
  then
    createEdgeFiles
    cat ${OKD_LAB_PATH}/work-dir-router/edge-router | ssh root@192.168.8.1 "cat >> /root/.profile"
    utilDir=edge
  else
    SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
    ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
    NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
    EDGE_IP=$(yq e ".sub-domain-configs.[${INDEX}].router-edge-ip" ${CONFIG_FILE})
    NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
    createDomainFiles
    cat ${OKD_LAB_PATH}/work-dir-router/internal-router | ${SSH} root@192.168.8.1 "cat >> /root/.profile"
    utilDir=domain
  fi
  cat ~/.ssh/id_rsa.pub | ${SSH} root@192.168.8.1 "cat >> /etc/dropbear/authorized_keys"
  ${SSH} root@192.168.8.1 "passwd -l root"
  ${SCP} ${OKD_LAB_PATH}/utils/${utilDir}/init-router.sh root@192.168.8.1:/tmp
  ${SSH} root@192.168.8.1 "chmod 700 /tmp/init-router.sh && . ~/.profile ; /tmp/init-router.sh"
  ${SSH} root@192.168.8.1 "poweroff"
else
  if [[ ${EDGE} == "true" ]]
  then
    utilDir=edge
  else
    utilDir=domain
  fi
  ${SCP} ${OKD_LAB_PATH}/utils/${utilDir}/config-router.sh root@${DOMAIN_ROUTER}:/tmp
  ${SSH} root@${DOMAIN_ROUTER} "chmod 700 /tmp/config-router.sh && . ~/.profile ; /tmp/config-router.sh"
  ${SSH} root@${DOMAIN_ROUTER} "reboot"
fi
