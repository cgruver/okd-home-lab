#!/bin/bash

# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://upstreamwithoutapaddle.com/home-lab/lab-intro/

CLUSTER_NAME="okd4"
INSTALL_URL="http://${BASTION_HOST}/install"
INVENTORY="${OKD_LAB_PATH}/inventory/okd4-lab"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
      -cn=*|--name=*)
      CLUSTER_NAME="${i#*=}"
      shift
      ;;
      *)
            # put usage here:
      ;;
  esac
done

rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/ignition

oc extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${OKD_LAB_PATH}/ipxe-work-dir/worker.ign

${OKD_LAB_PATH}/bin/deployOkdNodes.sh -i=${INVENTORY} -c=${CLUSTER} -cn=${CLUSTER_NAME}
