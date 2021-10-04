#!/bin/bash

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
INSTALL_URL="http://${BASTION_HOST}/install"
CREATE_DNS="false"

for i in "$@"
do
case $i in
    -c=*|--config=*)
      CONFIG_FILE="${i#*=}"
      shift
    ;;
    *)
          # Put usage here:
    ;;
esac
done

function createPartInfo() {

local disk1=${1}
local disk2=${2}

if [[ ${disk2} == "NA" ]]
then
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${disk1} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1
EOF
else
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${disk1} --size=1024 --grow --maxsize=2000000
part pv.2 --fstype="lvmpv" --ondisk=${disk2} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1 pv.2
EOF
fi
}

function createBootFile() {

local hostname=${1}
local mac_addr=${2}
local ip_addr=${3}

cat << EOF > ${OKD_LAB_PATH}/boot-work-dir/${mac_addr//:/-}.ipxe
#!ipxe

kernel ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/vmlinuz net.ifnames=1 ifname=nic0:${mac_addr} ip=${ip_addr}::${ROUTER}:${NETMASK}:${hostname}.${DOMAIN}:nic0:none nameserver=${ROUTER} inst.ks=${INSTALL_URL}/kickstart/${mac_addr//:/-}.ks inst.repo=${INSTALL_URL}/repos/BaseOS/x86_64/os initrd=initrd.img
initrd ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/initrd.img

boot
EOF
}

function createKickStartFile() {

local hostname=${1}
local mac_addr=${2}
local ip_addr=${3}
local disk1=${4}
local disk2=${5}

PART_INFO=$(createPartInfo ${disk1} ${disk2} )
DISK_LIST=${disk1}
if [[ ${disk2} != "NA" ]]
then
  DISK_LIST="${disk1},${disk2}"
fi

cat << EOF > ${OKD_LAB_PATH}/boot-work-dir/${mac_addr//:/-}.ks
#version=RHEL8
cmdline
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
repo --name="install" --baseurl=${INSTALL_URL}/repos/BaseOS/x86_64/os/
url --url="${INSTALL_URL}/repos/BaseOS/x86_64/os"
rootpw --iscrypted ${LAB_PWD}
firstboot --disable
skipx
services --enabled="chronyd"
timezone America/New_York --isUtc

# Disk partitioning information
ignoredisk --only-use=${DISK_LIST}
bootloader --append=" crashkernel=auto" --location=mbr --boot-drive=${disk1}
clearpart --drives=${DISK_LIST} --all --initlabel
zerombr
part /boot --fstype="xfs" --ondisk=${disk1} --size=1024
part /boot/efi --fstype="efi" --ondisk=${disk1} --size=600 --fsoptions="umask=0077,shortname=winnt"
${PART_INFO}
logvol swap  --fstype="swap" --size=16064 --name=swap --vgname=centos
logvol /  --fstype="xfs" --grow --maxsize=2000000 --size=1024 --name=root --vgname=centos

# Network Config
network  --hostname=${hostname}
network  --device=nic0 --noipv4 --noipv6 --no-activate --onboot=no
network  --bootproto=static --device=br0 --bridgeslaves=nic0 --gateway=${ROUTER} --ip=${ip_addr} --nameserver=${ROUTER} --netmask=${NETMASK} --noipv6 --activate --bridgeopts="stp=false" --onboot=yes

eula --agreed

%packages
@^minimal-environment
kexec-tools
%end

%addon com_redhat_kdump --enable --reserve-mb='auto'

%end

%anaconda
pwpolicy root --minlen=6 --minquality=1 --notstrict --nochanges --notempty
pwpolicy user --minlen=6 --minquality=1 --notstrict --nochanges --emptyok
pwpolicy luks --minlen=6 --minquality=1 --notstrict --nochanges --notempty
%end

%post
dnf config-manager --add-repo ${INSTALL_URL}/postinstall/local-repos.repo
dnf config-manager  --disable appstream
dnf config-manager  --disable baseos
dnf config-manager  --disable extras

mkdir -p /root/.ssh
chmod 700 /root/.ssh
curl -o /root/.ssh/authorized_keys ${INSTALL_URL}/postinstall/authorized_keys
chmod 600 /root/.ssh/authorized_keys
dnf -y module install virt
dnf -y install wget git net-tools bind-utils bash-completion nfs-utils rsync libguestfs-tools virt-install iscsi-initiator-utils
dnf -y update
echo "InitiatorName=iqn.$(hostname)" > /etc/iscsi/initiatorname.iscsi
echo "options kvm_intel nested=1" >> /etc/modprobe.d/kvm.conf
systemctl enable libvirtd
mkdir /VirtualMachines
mkdir -p /root/bin
curl -o /root/bin/rebuildhost.sh ${INSTALL_URL}/postinstall/rebuildhost.sh
chmod 700 /root/bin/rebuildhost.sh
curl -o /etc/chrony.conf ${INSTALL_URL}/postinstall/chrony.conf
echo '@reboot root nmcli con mod "br0 slave 1" ethtool.feature-tso off' >> /etc/crontab
%end

reboot

EOF

}

function createDnsRecords() {

  local hostname=${1}
  local ip_octet=${2}

  echo "${hostname}.${DOMAIN}.   IN      A      ${NET_PREFIX}.${ip_octet} ; ${hostname}-${DOMAIN}-kvm" >> ${OKD_LAB_PATH}/boot-work-dir/forward.zone
  echo "${ip_octet}.${NET_PREFIX_ARPA}    IN      PTR     ${hostname}.${DOMAIN}. ; ${hostname}-${DOMAIN}-kvm" >> ${OKD_LAB_PATH}/boot-work-dir/reverse.zone
}

SUB_DOMAIN=$(yq e .cluster-sub-domain ${CONFIG_FILE})
DOMAIN="${SUB_DOMAIN}.${LAB_DOMAIN}"
ROUTER=$(yq e .router ${CONFIG_FILE})
NETWORK=$(yq e .network ${CONFIG_FILE})
NETMASK=$(yq e .netmask ${CONFIG_FILE})
LAB_PWD=$(cat ${OKD_LAB_PATH}/lab_host_pw)
IFS=. read -r i1 i2 i3 i4 << EOF
${NETWORK}
EOF
NET_PREFIX=${i1}.${i2}.${i3}
NET_PREFIX_ARPA=${i3}.${i2}.${i1}

# Create temporary work directory
mkdir -p ${OKD_LAB_PATH}/boot-work-dir

HOST_COUNT=$(yq e .kvm-hosts ${CONFIG_FILE} | yq e 'length' -)

let i=0
while [[ i -lt ${HOST_COUNT} ]]
do
  hostname=$(yq e .kvm-hosts.[${i}].host-name ${CONFIG_FILE})
  mac_addr=$(yq e .kvm-hosts.[${i}].mac-addr ${CONFIG_FILE})
  ip_octet=$(yq e .kvm-hosts.[${i}].ip-octet ${CONFIG_FILE})
  ip_addr=${NET_PREFIX}.${ip_octet}
  disk1=$(yq e .kvm-hosts.[${i}].disks.disk1 ${CONFIG_FILE})
  disk2=$(yq e .kvm-hosts.[${i}].disks.disk2 ${CONFIG_FILE})

  TEST=$(dig ${hostname}.${DOMAIN} +short)
  if [[ ${TEST} == "${ip_addr}" ]]
  then
    echo "DNS Record exists, skipping DNS record creation"
  else
    createDnsRecords ${hostname} ${ip_octet}
    CREATE_DNS="true"
  fi
  createBootFile ${hostname} ${mac_addr} ${ip_addr}
  createKickStartFile ${hostname} ${mac_addr} ${ip_addr} ${disk1} ${disk2}

  i=$(( ${i} + 1 ))
done

${SCP} -r ${OKD_LAB_PATH}/boot-work-dir/*.ks root@${BASTION_HOST}:/usr/local/www/install/kickstart
${SCP} -r ${OKD_LAB_PATH}/boot-work-dir/*.ipxe root@${ROUTER}:/data/tftpboot/ipxe
if [[ ${CREATE_DNS} == "true" ]]
then
  cat ${OKD_LAB_PATH}/boot-work-dir/forward.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${DOMAIN}"
  cat ${OKD_LAB_PATH}/boot-work-dir/reverse.zone | ${SSH} root@${ROUTER} "cat >> /etc/bind/db.${NET_PREFIX_ARPA}"
  ${SSH} root@${ROUTER} "/etc/init.d/named restart"
fi

rm -rf ${OKD_LAB_PATH}/boot-work-dir
