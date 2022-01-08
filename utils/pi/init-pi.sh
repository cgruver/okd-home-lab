#!/bin/ash

wget https://downloads.openwrt.org/releases/21.02.1/targets/bcm27xx/bcm2711/openwrt-21.02.1-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz
gunzip openwrt-21.02.1-bcm27xx-bcm2711-rpi-4-ext4-factory.img.gz

umount /dev/mmcblk1p1
dd if=openwrt-21.02.1-bcm27xx-bcm2711-rpi-4-ext4-factory.img of=/dev/mmcblk1 bs=4M conv=fsync
rm openwrt-21.02.1-bcm27xx-bcm2711-rpi-4-ext4-factory.img

PART_INFO=$(sfdisk -l /dev/mmcblk1 | grep mmcblk1p2)
let ROOT_SIZE=41943040
let P2_START=$(echo ${PART_INFO} | cut -d" " -f2)
let P3_START=$(( ${P2_START}+${ROOT_SIZE}+8192 ))
sfdisk --delete /dev/mmcblk1 2
sfdisk -d /dev/mmcblk1 > /tmp/part.info
echo "/dev/mmcblk1p2 : start= ${P2_START}, size= ${ROOT_SIZE}, type=83" >> /tmp/part.info
echo "/dev/mmcblk1p3 : start= ${P3_START}, type=83" >> /tmp/part.info
umount /dev/mmcblk1p1
sfdisk /dev/mmcblk1 < /tmp/part.info

e2fsck -f /dev/mmcblk1p2
resize2fs /dev/mmcblk1p2
mkfs.ext4 /dev/mmcblk1p3

mkdir /tmp/pi
mount -t ext4 /dev/mmcblk1p2 /tmp/pi/

cat << EOF >> /tmp/pi/root/.profile
export NETWORK=${NETWORK}
export DOMAIN=${DOMAIN}
export BASTION_HOST=${BASTION_HOST}
export ROUTER=${ROUTER}
export NETMASK=${NETMASK}
EOF

read -r -d '' FILE << EOF
config interface 'loopback'\n
\toption device 'lo'\n
\toption proto 'static'\n
\toption ipaddr '127.0.0.1'\n
\toption netmask '255.0.0.0'\n
\n
config device\n
\toption name 'br-lan'\n
\toption type 'bridge'\n
\tlist ports 'eth0'\n
\n
config interface 'lan'\n
\toption device 'br-lan'\n
\toption proto 'static'\n
\toption ipaddr '${BASTION_HOST}'\n
\toption netmask '${NETMASK}'\n
\toption gateway '${ROUTER}'\n
\toption dns '${ROUTER}'\n
EOF

echo -e ${FILE} > /tmp/pi/etc/config/network

read -r -d '' FILE << EOF
config dropbear\n
\toption PasswordAuth 'off'\n
\toption RootPasswordAuth 'off'\n
\toption Port '22'\n
EOF

echo -e ${FILE} > /tmp/pi/etc/config/dropbear

read -r -d '' FILE << EOF
config system\n
\toption timezone 'UTC'\n
\toption ttylogin '0'\n
\toption log_size '64'\n
\toption urandom_seed '0'\n
\toption hostname 'bastion.${DOMAIN}'\n
\n
config timeserver 'ntp'\n
\toption enabled '1'\n
\toption enable_server '0'\n
\tlist server '0.openwrt.pool.ntp.org'\n
\tlist server '1.openwrt.pool.ntp.org'\n
\tlist server '2.openwrt.pool.ntp.org'\n
\tlist server '3.openwrt.pool.ntp.org'\n
EOF

echo -e ${FILE} > /tmp/pi/etc/config/system

cat /etc/dropbear/authorized_keys >> /tmp/pi/etc/dropbear/authorized_keys
dropbearkey -y -f /root/.ssh/id_dropbear | grep "^ssh-" >> /tmp/pi/etc/dropbear/authorized_keys

rm -f /tmp/pi/etc/rc.d/*dnsmasq*

umount /dev/mmcblk1p1
umount /dev/mmcblk1p2
umount /dev/mmcblk1p3

