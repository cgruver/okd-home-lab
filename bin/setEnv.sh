#!/bin/bash

SUB_DOMAIN=""
INDEX=""
CONFIG_FILE=${LAB_CONFIG_FILE}

for i in "$@"
do
  case ${i} in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          echo "USAGE: setEnv.sh -c=path/to/config/file -d=sub-domain-name"
    ;;
  esac
done

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

export SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
export DOMAIN_ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
export DOMAIN_NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})

unset array_index