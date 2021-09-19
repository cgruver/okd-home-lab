#!/bin/bash

SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DISK_1=""
DISK_2=""
INSTALL_URL="http://${BASTION_HOST}/install"
LAB_NETMASK=${NETMASK}
CLUSTER=""

for i in "$@"
do
case $i in
    -h=*|--hostname=*)
    HOSTNAME="${i#*=}"
    shift
    ;;
    -m=*|--mac=*)
    NET_MAC="${i#*=}"
    shift
    ;;
    -d=*|--diskList=*)
    DISK="${i#*=}"
    shift
    ;;
    -c=*|--cluster=*)
    let CLUSTER="${i#*=}"
    shift
    ;;
    *)
          # Put usage here:
    ;;
esac
done

IFS=. read -r i1 i2 i3 i4 << EOI
${EDGE_NETWORK}
EOI

if [[ ${CLUSTER} == "" ]]
then
  DOMAIN=${LAB_DOMAIN}
  GATEWAY=${EDGE_ROUTER}
else
  DOMAIN=dc${CLUSTER}.${LAB_DOMAIN}
  GATEWAY=${i1}.${i2}.$(( ${i3} + ${CLUSTER} )).1
fi

DISK_1=$(echo ${DISK} | cut -d"," -f 1)
DISK_2=$(echo ${DISK} | cut -d"," -f 2)
if [[ ${DISK_1} == ${DISK_2} ]]
then
  DISK_2=""
fi

LAB_PWD=$(cat ${OKD_LAB_PATH}/lab_host_pw)

function createPartInfo() {

if [[ ${DISK_2} == "" ]]
then
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${DISK_1} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1
EOF
else
cat <<EOF
part pv.1 --fstype="lvmpv" --ondisk=${DISK_1} --size=1024 --grow --maxsize=2000000
part pv.2 --fstype="lvmpv" --ondisk=${DISK_2} --size=1024 --grow --maxsize=2000000
volgroup centos --pesize=4096 pv.1 pv.2
EOF
fi
}

# Create temporary work directory
mkdir -p ${OKD_LAB_PATH}/ipxe-work-dir

# Get IP address for nic0
IP=$(dig ${HOSTNAME}.${DOMAIN} +short)

# Create and deploy the iPXE boot file for this host
cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${NET_MAC//:/-}.ipxe
#!ipxe

kernel ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/vmlinuz net.ifnames=1 ifname=nic0:${NET_MAC} ip=${IP}::${GATEWAY}:${LAB_NETMASK}:${HOSTNAME}.${DOMAIN}:nic0:none nameserver=${GATEWAY} inst.ks=${INSTALL_URL}/kickstart/${NET_MAC//:/-}.ks inst.repo=${INSTALL_URL}/repos/BaseOS/x86_64/os initrd=initrd.img
initrd ${INSTALL_URL}/repos/BaseOS/x86_64/os/isolinux/initrd.img

boot
EOF

${SCP} ${OKD_LAB_PATH}/ipxe-work-dir/${NET_MAC//:/-}.ipxe root@${GATEWAY}:/data/tftpboot/ipxe/${NET_MAC//:/-}.ipxe

# Create the Kickstart file

PART_INFO=$(createPartInfo)

cat << EOF > ${OKD_LAB_PATH}/ipxe-work-dir/${NET_MAC//:/-}.ks
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
ignoredisk --only-use=${DISK}
bootloader --append=" crashkernel=auto" --location=mbr --boot-drive=${DISK_1}
clearpart --drives=${DISK} --all --initlabel
zerombr
part /boot --fstype="xfs" --ondisk=${DISK_1} --size=1024
part /boot/efi --fstype="efi" --ondisk=${DISK_1} --size=600 --fsoptions="umask=0077,shortname=winnt"
${PART_INFO}
logvol swap  --fstype="swap" --size=16064 --name=swap --vgname=centos
logvol /  --fstype="xfs" --grow --maxsize=2000000 --size=1024 --name=root --vgname=centos

# Network Config
network  --hostname=${HOSTNAME}
network  --device=nic0 --noipv4 --noipv6 --no-activate --onboot=no
network  --bootproto=static --device=br0 --bridgeslaves=nic0 --gateway=${GATEWAY} --ip=${IP} --nameserver=${GATEWAY} --netmask=${LAB_NETMASK} --noipv6 --activate --bridgeopts="stp=false" --onboot=yes

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

${SCP} ${OKD_LAB_PATH}/ipxe-work-dir/${NET_MAC//:/-}.ks root@${BASTION_HOST}:/usr/local/www/install/kickstart/${NET_MAC//:/-}.ks

# Clean up
rm -rf ${OKD_LAB_PATH}/ipxe-work-dir
