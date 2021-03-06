#!/bin/bash

INIT_CLUSTER=false
ADD_WORKER=false
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
CONFIG_FILE=${LAB_CONFIG_FILE}
CP_REPLICAS="3"
SNO_BIP=""
SNO="false"
BIP="false"
# This script will set up the infrastructure to deploy an OKD 4.X cluster
# Follow the documentation at https://upstreamwithoutapaddle.com/home-lab/lab-intro/

for i in "$@"
do
  case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift # past argument=value
    ;;
    -i|--init)
      INIT_CLUSTER=true
      shift
    ;;
    -w|--worker)
      ADD_WORKER=true
      shift
    ;;
    -d=*|--domain=*)
      SUB_DOMAIN="${i#*=}"
      shift
    ;;
      *)
            # put usage here:
      ;;
  esac
done

function createControlPlaneDNS() {
cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/forward.zone
${CLUSTER_NAME}-bootstrap.${DOMAIN}.  IN      A      ${NET_PREFIX}.49 ; ${CLUSTER_NAME}-${DOMAIN}-bs
${CLUSTER_NAME}-lb01.${DOMAIN}.       IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${NET_PREFIX}.2 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-0.${DOMAIN}.   IN      A      ${NET_PREFIX}.60 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-0.${DOMAIN}.          IN      A      ${NET_PREFIX}.60 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-1.${DOMAIN}.   IN      A      ${NET_PREFIX}.61 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-1.${DOMAIN}.          IN      A      ${NET_PREFIX}.61 ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-master-2.${DOMAIN}.   IN      A      ${NET_PREFIX}.62 ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-2.${DOMAIN}.          IN      A      ${NET_PREFIX}.62 ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-1.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-2.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/reverse.zone
2     IN      PTR     ${CLUSTER_NAME}-lb01.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
49    IN      PTR     ${CLUSTER_NAME}-bootstrap.${DOMAIN}.   ; ${CLUSTER_NAME}-${DOMAIN}-bs
60    IN      PTR     ${CLUSTER_NAME}-master-0.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
61    IN      PTR     ${CLUSTER_NAME}-master-1.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
62    IN      PTR     ${CLUSTER_NAME}-master-2.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

}

function createSnoDNS() {
cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/forward.zone
*.apps.${CLUSTER_NAME}.${DOMAIN}.     IN      A      ${NET_PREFIX}.${NODE_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api.${CLUSTER_NAME}.${DOMAIN}.        IN      A      ${NET_PREFIX}.${NODE_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp
api-int.${CLUSTER_NAME}.${DOMAIN}.    IN      A      ${NET_PREFIX}.${NODE_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp
${CLUSTER_NAME}-sno-0.${DOMAIN}.   IN      A      ${NET_PREFIX}.${NODE_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp
etcd-0.${DOMAIN}.          IN      A      ${NET_PREFIX}.${NODE_IP} ; ${CLUSTER_NAME}-${DOMAIN}-cp
_etcd-server-ssl._tcp.${CLUSTER_NAME}.${DOMAIN}    86400     IN    SRV     0    10    2380    etcd-0.${CLUSTER_NAME}.${DOMAIN}. ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

cat << EOF > ${OKD_LAB_PATH}/dns-work-dir/reverse.zone
${NODE_IP}    IN      PTR     ${CLUSTER_NAME}-sno-0.${DOMAIN}.  ; ${CLUSTER_NAME}-${DOMAIN}-cp
EOF

}

function createInstallConfig() {

  local install_dev=${1}

if [[ ${SNO} == "true" ]]
then
read -r -d '' SNO_BIP << EOF
BootstrapInPlace:
  InstallationDisk: /dev/${install_dev}
EOF
CP_REPLICAS="1"
fi

cat << EOF > ${OKD_LAB_PATH}/install-config-upi.yaml
apiVersion: v1
baseDomain: ${DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.100.0.0/14 
    hostPrefix: 23 
  serviceNetwork: 
  - 172.30.0.0/16
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: ${CP_REPLICAS}
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: ${SSH_KEY}
additionalTrustBundle: |
${NEXUS_CERT}
imageContentSources:
- mirrors:
  - ${REGISTRY}/okd
  source: quay.io/openshift/okd
- mirrors:
  - ${REGISTRY}/okd
  source: quay.io/openshift/okd-content
${SNO_BIP}
EOF
}

function configOkdNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local mac=${3}
  local role=${4}

cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${mac//:/-}.yml
variant: fcos
version: ${BUTANE_SPEC_VERSION}
ignition:
  config:
    merge:
      - local: ${role}.ign
kernel_arguments:
  should_exist:
    - mitigations=auto
  should_not_exist:
    - mitigations=auto,nosmt
  should_not_exist:
    - mitigations=off
storage:
  files:
    - path: /etc/zincati/config.d/90-disable-feature.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          enabled = false
    - path: /etc/systemd/network/25-nic0.link
      mode: 0644
      contents:
        inline: |
          [Match]
          MACAddress=${mac}
          [Link]
          Name=nic0
    - path: /etc/NetworkManager/system-connections/nic0.nmconnection
      mode: 0600
      overwrite: true
      contents:
        inline: |
          [connection]
          type=ethernet
          interface-name=nic0

          [ethernet]
          mac-address=${mac}

          [ipv4]
          method=manual
          addresses=${ip_addr}/${NETMASK}
          gateway=${ROUTER}
          dns=${ROUTER}
          dns-search=${DOMAIN}
    - path: /etc/hostname
      mode: 0420
      overwrite: true
      contents:
        inline: |
          ${host_name}
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          pool ${BASTION_HOST} iburst 
          driftfile /var/lib/chrony/drift
          makestep 1.0 3
          rtcsync
          logdir /var/log/chrony
EOF

cat ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${mac//:/-}.yml | butane -d ${OKD_LAB_PATH}/ipxe-work-dir/ -o ${OKD_LAB_PATH}/ipxe-work-dir/ignition/${mac//:/-}.ign

}

function createPxeFile() {
  local mac=${1}
  local platform=${2}
  local boot_dev=${3}

if [[ ${platform} == "qemu" ]]
then
  CONSOLE_OPT="console=ttyS0"
fi

if [[ ${BIP} == "true" ]]
then
cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 ignition.firstboot ignition.config.url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign ignition.platform.id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
initrd http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/initrd
initrd http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/rootfs.img

boot
EOF
else
cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${mac//:/-}.ipxe
#!ipxe

kernel http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/vmlinuz edd=off net.ifnames=1 rd.neednet=1 coreos.inst.install_dev=/dev/${boot_dev} coreos.inst.ignition_url=http://${BASTION_HOST}/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/${mac//:/-}.ign coreos.inst.platform_id=${platform} initrd=initrd initrd=rootfs.img ${CONSOLE_OPT}
initrd http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/initrd
initrd http://${BASTION_HOST}/install/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/rootfs.img

boot
EOF
fi

}


function createOkdVmNode() {
    
  local ip_addr=${1}
  local host_name=${2}
  local kvm_host=${3}
  local role=${4}
  local memory=${5}
  local cpu=${6}
  local root_vol=${7}
  local ceph_vol=${8}

  # Create the VM
  DISK_CONFIG="--disk size=${root_vol},path=/VirtualMachines/${host_name}/rootvol,bus=sata"
  if [ ${ceph_vol} != "0" ]
  then
    DISK_CONFIG="${DISK_CONFIG} --disk size=${ceph_vol},path=/VirtualMachines/${host_name}/datavol,bus=sata"
  fi
  ${SSH} root@${kvm_host}.${DOMAIN} "mkdir -p /VirtualMachines/${host_name}"
  ${SSH} root@${kvm_host}.${DOMAIN} "virt-install --print-xml 1 --name ${host_name} --memory ${memory} --vcpus ${cpu} --boot=hd,network,menu=on,useserial=on ${DISK_CONFIG} --network bridge=br0 --graphics none --noautoconsole --os-variant centos7.0 --cpu host-passthrough,match=exact > /VirtualMachines/${host_name}.xml"
  ${SSH} root@${kvm_host}.${DOMAIN} "virsh define /VirtualMachines/${host_name}.xml"
}

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
BASTION_HOST=$(yq e ".bastion-ip" ${CONFIG_FILE})
SUB_DOMAIN=$(yq e ".sub-domain-configs.[${INDEX}].name" ${CONFIG_FILE})
ROUTER=$(yq e ".sub-domain-configs.[${INDEX}].router-ip" ${CONFIG_FILE})
NETWORK=$(yq e ".sub-domain-configs.[${INDEX}].network" ${CONFIG_FILE})
NETMASK=$(yq e ".sub-domain-configs.[${INDEX}].netmask" ${CONFIG_FILE})
CLUSTER_CONFIG=$(yq e ".sub-domain-configs.[${INDEX}].cluster-config-file" ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
REGISTRY=$(yq e ".proxy-registry" ${CLUSTER_CONFIG})
CLUSTER_NAME=$(yq e ".cluster-name" ${CLUSTER_CONFIG})
PULL_SECRET=$(yq e ".secret-file" ${CLUSTER_CONFIG})
BUTANE_SPEC_VERSION=$(yq e ".butane-spec-version" ${CLUSTER_CONFIG})
INSTALL_URL="http://${BASTION_HOST}/install"

IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
rm -rf ${OKD_LAB_PATH}/dns-work-dir
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/ignition
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}
mkdir -p ${OKD_LAB_PATH}/dns-work-dir

if [[ ${INIT_CLUSTER} == "true" ]]
then
  SSH_KEY=$(cat ${OKD_LAB_PATH}/id_rsa.pub)
  PULL_SECRET=$(cat ${OKD_LAB_PATH}/pull_secret.json)
  NEXUS_CERT=$(openssl s_client -showcerts -connect ${REGISTRY} </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "  ${line}"; done)
  CP_COUNT=$(yq e ".control-plane.okd-hosts" ${CLUSTER_CONFIG} | yq e 'length' -)
  if [[ ${CP_COUNT} == "1" ]]
  then
    SNO="true"
  elif [[ ${CP_COUNT} != "3" ]]
  then
    echo "There must be 3 host entries for the control plane for a full cluster, or 1 entry for a Single Node cluster."
    exit 1
  fi

  # Create and deploy ignition files single-node-ignition-config
  rm -rf ${OKD_LAB_PATH}/okd-install-dir
  mkdir ${OKD_LAB_PATH}/okd-install-dir

  if [[ ${SNO} == "false" ]] # Create Bootstrap Node
  then
    # Create ignition files
    createInstallConfig "null"
    cp ${OKD_LAB_PATH}/install-config-upi.yaml ${OKD_LAB_PATH}/okd-install-dir/install-config.yaml
    openshift-install --dir=${OKD_LAB_PATH}/okd-install-dir create ignition-configs
    cp ${OKD_LAB_PATH}/okd-install-dir/*.ign ${OKD_LAB_PATH}/ipxe-work-dir/
    # Create Bootstrap Node:
    host_name=${CLUSTER_NAME}-bootstrap
    ip_addr=${NET_PREFIX}.49
    boot_dev=sda
    platform=qemu
    if [[ $(yq e ".bootstrap.metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      mac_addr=$(yq e ".bootstrap.mac-addr" ${CLUSTER_CONFIG})
      mkdir -p ${OKD_LAB_PATH}/bootstrap
      qemu-img create -f qcow2 ${OKD_LAB_PATH}/bootstrap/bootstrap-node.qcow2 50G
    else
      kvm_host=$(yq e ".bootstrap.kvm-host" ${CLUSTER_CONFIG})
      memory=$(yq e ".bootstrap.node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".bootstrap.node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".bootstrap.node-spec.root_vol" ${CLUSTER_CONFIG})
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} bootstrap ${memory} ${cpu} ${root_vol} 0
      # Get the MAC address for eth0 in the new VM  
      var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
      mac_addr=$(echo ${var} | cut -d" " -f5)
      yq e ".bootstrap.mac-addr = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
    fi
    # Create the ignition and iPXE boot files
    configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} bootstrap
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
  fi

  #Create Control Plane Nodes:
  metal=$(yq e ".control-plane.metal" ${CLUSTER_CONFIG})
  if [[ ${metal} == "true" ]]
  then
    platform=metal
  else
    platform=qemu
  fi

  if [[ ${SNO} == "true" ]]
  then
    NODE_IP=$(yq e ".control-plane.okd-hosts.[0].ip-octet" ${CLUSTER_CONFIG})
    ip_addr=${NET_PREFIX}.${NODE_IP}
    host_name=${CLUSTER_NAME}-sno-0
    if [[ ${metal} == "true" ]]
    then
      mac_addr=$(yq e ".control-plane.okd-hosts.[0].mac-addr" ${CLUSTER_CONFIG})
    else
      memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".control-plane.node-spec.root_vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".control-plane.okd-hosts.[0].kvm-host" ${CLUSTER_CONFIG})
      # Create the VM
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} sno ${memory} ${cpu} ${root_vol} 0
      # Get the MAC address for eth0 in the new VM  
      var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
      mac_addr=$(echo ${var} | cut -d" " -f5)
      yq e ".control-plane.okd-hosts.[0].mac-addr = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
    fi
    # Create the ignition and iPXE boot files
    install_dev=$(yq e ".control-plane.okd-hosts.[0].sno-install-dev" ${CLUSTER_CONFIG})
    boot_dev=$(yq e ".control-plane.okd-hosts.[0].boot-dev" ${CLUSTER_CONFIG})
    if [[ "${install_dev}" == "${boot_dev}" ]]
    then
      BIP="true"
    fi
    createInstallConfig ${install_dev}
    cp ${OKD_LAB_PATH}/install-config-upi.yaml ${OKD_LAB_PATH}/okd-install-dir/install-config.yaml
    openshift-install --dir=${OKD_LAB_PATH}/okd-install-dir create single-node-ignition-config
    cp ${OKD_LAB_PATH}/okd-install-dir/bootstrap-in-place-for-live-iso.ign ${OKD_LAB_PATH}/ipxe-work-dir/sno.ign
    configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} sno
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
    # Set the node values in the lab domain configuration file
    yq e ".control-plane.okd-hosts.[0].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    yq e ".control-plane.okd-hosts.[0].ip-addr = \"${ip_addr}\"" -i ${CLUSTER_CONFIG}
    createSnoDNS
  else  
    for i in 0 1 2
    do
      ip_addr=${NET_PREFIX}.6${i}
      host_name=${CLUSTER_NAME}-master-${i}
      if [[ ${metal} == "true" ]]
      then
        mac_addr=$(yq e ".control-plane.okd-hosts.[${i}].mac-addr" ${CLUSTER_CONFIG})
        boot_dev=$(yq e ".control-plane.okd-hosts.[${i}].boot-dev" ${CLUSTER_CONFIG})
      else
        memory=$(yq e ".control-plane.node-spec.memory" ${CLUSTER_CONFIG})
        cpu=$(yq e ".control-plane.node-spec.cpu" ${CLUSTER_CONFIG})
        root_vol=$(yq e ".control-plane.node-spec.root_vol" ${CLUSTER_CONFIG})
        kvm_host=$(yq e ".control-plane.okd-hosts.[${i}].kvm-host" ${CLUSTER_CONFIG})
        boot_dev="sda"
        # Create the VM
        createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} master ${memory} ${cpu} ${root_vol} 0
        # Get the MAC address for eth0 in the new VM  
        var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
        mac_addr=$(echo ${var} | cut -d" " -f5)
        yq e ".control-plane.okd-hosts.[${i}].mac-addr = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
      fi
      # Create the ignition and iPXE boot files
      configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} master
      createPxeFile ${mac_addr} ${platform} ${boot_dev}
      # Set the node values in the lab domain configuration file
      yq e ".control-plane.okd-hosts.[${i}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
      yq e ".control-plane.okd-hosts.[${i}].ip-addr = \"${ip_addr}\"" -i ${CLUSTER_CONFIG}
    done
    # Create DNS Records:
    createControlPlaneDNS
  fi

  KERNEL_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location')
  INITRD_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location')
  ROOTFS_URL=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

  curl -o ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/vmlinuz ${KERNEL_URL}
  curl -o ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/initrd ${INITRD_URL}
  curl -o ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN}/rootfs.img ${ROOTFS_URL}

  ${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/fcos/${CLUSTER_NAME}-${SUB_DOMAIN} root@${BASTION_HOST}:/usr/local/www/install/fcos/
fi

if [[ ${ADD_WORKER} == "true" ]]
then
  if [[ ${INIT_CLUSTER} != "true" ]]
  then
    export KUBECONFIG="${OKD_LAB_PATH}/lab-config/${CLUSTER_NAME}.${DOMAIN}/kubeconfig"
    ID=$(oc whoami)
    if [[ ${ID} != "system:admin" ]]
    then
      echo "ERROR: Invalid kube_config: ${KUBECONFIG}"
      exit 1
    fi
    oc extract -n openshift-machine-api secret/worker-user-data --keys=userData --to=- > ${OKD_LAB_PATH}/ipxe-work-dir/worker.ign
  fi
  let NODE_COUNT=$(yq e ".compute-nodes" ${CLUSTER_CONFIG} | yq e 'length' -)
  let i=0
  let j=70
  while [[ i -lt ${NODE_COUNT} ]]
  do
    host_name=${CLUSTER_NAME}-worker-${i}
    ip_addr=${NET_PREFIX}.${j}
    if [[ $(yq e ".compute-nodes.[${i}].metal" ${CLUSTER_CONFIG}) == "true" ]]
    then
      platform=metal
      mac_addr=$(yq e ".compute-nodes.[${i}].mac-addr" ${CLUSTER_CONFIG})
      boot_dev=$(yq e ".compute-nodes.[${i}].boot-dev" ${CLUSTER_CONFIG})
    else
      platform=qemu
      boot_dev="sda"
      memory=$(yq e ".compute-nodes.[${i}].node-spec.memory" ${CLUSTER_CONFIG})
      cpu=$(yq e ".compute-nodes.[${i}].node-spec.cpu" ${CLUSTER_CONFIG})
      root_vol=$(yq e ".compute-nodes.[${i}].node-spec.root_vol" ${CLUSTER_CONFIG})
      ceph_vol=$(yq e ".compute-nodes.[${i}].node-spec.ceph_vol" ${CLUSTER_CONFIG})
      kvm_host=$(yq e ".compute-nodes.[${i}].kvm-host" ${CLUSTER_CONFIG})
      # Create the VM
      createOkdVmNode ${ip_addr} ${host_name} ${kvm_host} worker ${memory} ${cpu} ${root_vol} ${ceph_vol}
      # Get the MAC address for eth0 in the new VM  
      var=$(${SSH} root@${kvm_host}.${DOMAIN} "virsh -q domiflist ${host_name} | grep br0")
      mac_addr=$(echo ${var} | cut -d" " -f5)
      yq e ".compute-nodes.[${i}].mac-addr = \"${mac_addr}\"" -i ${CLUSTER_CONFIG}
    fi
    # Create the ignition and iPXE boot files
    configOkdNode ${ip_addr} ${host_name}.${DOMAIN} ${mac_addr} worker
    createPxeFile ${mac_addr} ${platform} ${boot_dev}
    # Set the node values in the lab domain configuration file
    yq e ".compute-nodes.[${i}].name = \"${host_name}\"" -i ${CLUSTER_CONFIG}
    yq e ".compute-nodes.[${i}].ip-addr = \"${ip_addr}\"" -i ${CLUSTER_CONFIG}
    # Create DNS entries
    echo "${host_name}.${DOMAIN}.   IN      A      ${NET_PREFIX}.${j} ; ${host_name}-${DOMAIN}-wk" >> ${OKD_LAB_PATH}/dns-work-dir/forward.zone
    echo "${j}    IN      PTR     ${host_name}.${DOMAIN}. ; ${host_name}-${DOMAIN}-wk" >> ${OKD_LAB_PATH}/dns-work-dir/reverse.zone

    i=$(( ${i} + 1 ))
    j=$(( ${j} + 1 ))
  done
fi

cat ${OKD_LAB_PATH}/dns-work-dir/forward.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
cat ${OKD_LAB_PATH}/dns-work-dir/reverse.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
${SSH} root@${ROUTER} "/etc/init.d/named stop && /etc/init.d/named start"
${SSH} root@${BASTION_HOST} "mkdir -p /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/ignition/*.ign root@${BASTION_HOST}:/usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/
${SSH} root@${BASTION_HOST} "chmod 644 /usr/local/www/install/fcos/ignition/${CLUSTER_NAME}-${SUB_DOMAIN}/*"
${SCP} -r ${OKD_LAB_PATH}/ipxe-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe/
