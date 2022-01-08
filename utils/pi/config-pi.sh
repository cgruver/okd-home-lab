#!/bin/ash

CENTOS_MIRROR=${1}
echo "export CENTOS_MIRROR=${CENTOS_MIRROR}" >> /root/.profile

passwd -l root

opkg update && opkg install ip-full uhttpd shadow bash wget git-http ca-bundle procps-ng-ps rsync curl libstdcpp6 libjpeg libnss lftp block-mount

opkg list | grep "^coreutils-" | while read i
do
    opkg install $(echo ${i} | cut -d" " -f1)
done

rm -rf /root/.ssh
mkdir -p /root/.ssh
dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear

let RC=0
while [[ ${RC} -eq 0 ]]
do
  uci delete fstab.@mount[-1]
  let RC=$?
done
PART_UUID=$(block info /dev/mmcblk0p3 | cut -d\" -f2)
MOUNT=$(uci add fstab mount)
uci batch << EOI
set fstab.${MOUNT}.target=/usr/local
set fstab.${MOUNT}.uuid=${PART_UUID}
set fstab.${MOUNT}.enabled=1
EOI
uci commit fstab
block mount

mkdir -p /usr/local/www/install/kickstart
mkdir /usr/local/www/install/postinstall
mkdir /usr/local/www/install/fcos

mkdir -p /root/bin

cat << EOF > /root/bin/MirrorSync.sh
#!/bin/bash

for i in BaseOS AppStream PowerTools extras
do 
  rsync  -avSHP --delete \${CENTOS_MIRROR}8-stream/\${i}/x86_64/os/ /usr/local/www/install/repos/\${i}/x86_64/os/ > /tmp/repo-mirror.\${i}.out 2>&1
done
EOF

chmod 750 /root/bin/MirrorSync.sh

for i in BaseOS AppStream PowerTools extras
do 
  mkdir -p /usr/local/www/install/repos/${i}/x86_64/os/
done

nohup /root/bin/MirrorSync.sh &

cat << EOF > /usr/local/www/install/postinstall/local-repos.repo
[local-appstream]
name=AppStream
baseurl=http://${BASTION_HOST}/install/repos/AppStream/x86_64/os/
gpgcheck=0
enabled=1

[local-extras]
name=extras
baseurl=http://${BASTION_HOST}/install/repos/extras/x86_64/os/
gpgcheck=0
enabled=1

[local-baseos]
name=BaseOS
baseurl=http://${BASTION_HOST}/install/repos/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

[local-powertools]
name=PowerTools
baseurl=http://${BASTION_HOST}/install/repos/PowerTools/x86_64/os/
gpgcheck=0
enabled=1
EOF

uci del_list uhttpd.main.listen_http="[::]:80"
uci del_list uhttpd.main.listen_http="0.0.0.0:80"
uci del_list uhttpd.main.listen_https="[::]:443"
uci del_list uhttpd.main.listen_https="0.0.0.0:443"
uci del uhttpd.defaults
uci del uhttpd.main.cert
uci del uhttpd.main.key
uci del uhttpd.main.cgi_prefix
uci del uhttpd.main.lua_prefix
uci add_list uhttpd.main.listen_http="${BASTION_HOST}:80"
uci add_list uhttpd.main.listen_http="127.0.0.1:80"
uci set uhttpd.main.home='/usr/local/www'
uci commit uhttpd
/etc/init.d/uhttpd restart

uci set system.ntp.enable_server="1"
uci commit system
/etc/init.d/sysntpd restart

cat << EOF > /usr/local/www/install/postinstall/chrony.conf
server ${BASTION_HOST} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

dropbearkey -y -f /root/.ssh/id_dropbear | grep "ssh-" > /usr/local/www/install/postinstall/authorized_keys


