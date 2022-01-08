function labctx() {

  local config_file=${1}
  # local sub_domain=
  SUB_DOMAIN=""
  INDEX=""

  for i in "$@"
  do
    case $i in
      -c=*|--config=*)
        CONFIG_FILE="${i#*=}"
        shift
      ;;
      -h=*|--host=*)
        HOST_NAME="${i#*=}"
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

  if [[ ${config_file} == "" ]]
  then
    CONFIG_FILE=${LAB_CONFIG_FILE}
  else
    CONFIG_FILE=${config_file}
  fi

  DONE=false
  DOMAIN_COUNT=$(yq e ".sub-domain-configs" ${CONFIG_FILE} | yq e 'length' -)
  let array_index=0
  while [[ array_index -lt ${DOMAIN_COUNT} ]]
  do
    domain_name=$(yq e ".sub-domain-configs.[${array_index}].name" ${CONFIG_FILE})
    echo "$(( ${array_index} + 1 )) - ${domain_name}"
    array_index=$(( ${array_index} + 1 ))
  done
  echo "Enter the index of the domain that you want to work with:"
  read ENTRY
  INDEX=$(( ${ENTRY} - 1 ))

  export LAB_DOMAIN=$(yq e ".domain" ${LAB_CONFIG_FILE})
  export EDGE_ROUTER=$(yq e ".router" ${LAB_CONFIG_FILE})
  export CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
  export SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
  export DOMAIN_ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
  export DOMAIN_ROUTER_EDGE=$(yq e ".sub-domain-configs.[${INDEX}].router-edge-ip" ${CONFIG_FILE})
  export DOMAIN_NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
  export DOMAIN_NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
  export LOCAL_REGISTRY=$(yq e ".local-registry" ${OKD_LAB_PATH}/lab-config/${SUB_DOMAIN}-cluster.yaml)
  OKD_VERSION=$(yq e ".okd-version" ${CLUSTER_CONFIG})
  for i in $(ls ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION})
  do
    rm -f ${OKD_LAB_PATH}/bin/${i}
    ln -s ${OKD_LAB_PATH}/okd-cmds/${OKD_VERSION}/${i} ${OKD_LAB_PATH}/bin/${i}
  done

  unset array_index
}
