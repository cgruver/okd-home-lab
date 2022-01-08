#!/bin/ash

rm -rf /data/*

opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools wget haproxy bash shadow uhttpd

uci add_list dhcp.lan.dhcp_option="6,${ROUTER}"
uci set dhcp.lan.leasetime="5m"
uci set dhcp.@dnsmasq[0].enable_tftp=1
uci set dhcp.@dnsmasq[0].tftp_root=/data/tftpboot
uci set dhcp.efi64_boot_1=match
uci set dhcp.efi64_boot_1.networkid='set:efi64'
uci set dhcp.efi64_boot_1.match='60,PXEClient:Arch:00007'
uci set dhcp.efi64_boot_2=match
uci set dhcp.efi64_boot_2.networkid='set:efi64'
uci set dhcp.efi64_boot_2.match='60,PXEClient:Arch:00009'
uci set dhcp.ipxe_boot=userclass
uci set dhcp.ipxe_boot.networkid='set:ipxe'
uci set dhcp.ipxe_boot.userclass='iPXE'
uci set dhcp.uefi=boot
uci set dhcp.uefi.filename='tag:efi64,tag:!ipxe,ipxe.efi'
uci set dhcp.uefi.serveraddress="${ROUTER}"
uci set dhcp.uefi.servername='pxe'
uci set dhcp.uefi.force='1'
uci set dhcp.ipxe=boot
uci set dhcp.ipxe.filename='tag:ipxe,boot.ipxe'
uci set dhcp.ipxe.serveraddress="${ROUTER}"
uci set dhcp.ipxe.servername='pxe'
uci set dhcp.ipxe.force='1'
uci commit dhcp

mkdir -p /data/tftpboot/ipxe
mkdir /data/tftpboot/networkboot
wget http://boot.ipxe.org/ipxe.efi -O /data/tftpboot/ipxe.efi

cat << EOF > /data/tftpboot/boot.ipxe
#!ipxe
   
echo ========================================================
echo UUID: \${uuid}
echo Manufacturer: \${manufacturer}
echo Product name: \${product}
echo Hostname: \${hostname}
echo
echo MAC address: \${net0/mac}
echo IP address: \${net0/ip}
echo IPv6 address: \${net0.ndp.0/ip6:ipv6}
echo Netmask: \${net0/netmask}
echo
echo Gateway: \${gateway}
echo DNS: \${dns}
echo IPv6 DNS: \${dns6}
echo Domain: \${domain}
echo ========================================================
   
chain --replace --autofree ipxe/\${mac:hexhyp}.ipxe
EOF

wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/vmlinuz -O /data/tftpboot/networkboot/vmlinuz
wget http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/isolinux/initrd.img -O /data/tftpboot/networkboot/initrd.img

mv /etc/bind/named.conf /etc/bind/named.conf.orig

CIDR=$(ip -br addr show dev br-lan label br-lan | cut -d" " -f1 | cut -d"/" -f2)
IFS=. read -r i1 i2 i3 i4 << EOF
${ROUTER}
EOF

net_addr=$(( ((1<<32)-1) & (((1<<32)-1) << (32 - ${CIDR})) ))
o1=$(( ${i1} & (${net_addr}>>24) ))
o2=$(( ${i2} & (${net_addr}>>16) ))
o3=$(( ${i3} & (${net_addr}>>8) ))
o4=$(( ${i4} & ${net_addr} ))
NET_PREFIX=${o1}.${o2}.${o3}
NET_PREFIX_ARPA=${o3}.${o2}.${o1}

cat << EOF > /etc/bind/named.conf
acl "trusted" {
 ${NETWORK}/${CIDR};
 ${EDGE_NETWORK}/${CIDR};
 127.0.0.1;
};

options {
 listen-on port 53 { 127.0.0.1; ${ROUTER}; };
 
 directory  "/data/var/named";
 dump-file  "/data/var/named/data/cache_dump.db";
 statistics-file "/data/var/named/data/named_stats.txt";
 memstatistics-file "/data/var/named/data/named_mem_stats.txt";
 allow-query     { trusted; };

 recursion yes;

 forwarders { ${EDGE_ROUTER}; };

 dnssec-validation yes;

 /* Path to ISC DLV key */
 bindkeys-file "/etc/bind/bind.keys";

 managed-keys-directory "/data/var/named/dynamic";

 pid-file "/var/run/named/named.pid";
 session-keyfile "/var/run/named/session.key";

};

logging {
        channel default_debug {
                file "data/named.run";
                severity dynamic;
        };
};

zone "." IN {
 type hint;
 file "/etc/bind/db.root";
};

zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.${DOMAIN}"; # zone file path
};

zone "${NET_PREFIX_ARPA}.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${NET_PREFIX_ARPA}";
};

zone "localhost" {
    type master;
    file "/etc/bind/db.local";
};

zone "127.in-addr.arpa" {
    type master;
    file "/etc/bind/db.127";
};

zone "0.in-addr.arpa" {
    type master;
    file "/etc/bind/db.0";
};

zone "255.in-addr.arpa" {
    type master;
    file "/etc/bind/db.255";
};

EOF

cat << EOF > /etc/bind/db.${DOMAIN}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
             3          ; Serial
             604800     ; Refresh
              86400     ; Retry
            2419200     ; Expire
             604800 )   ; Negative Cache TTL
;
; name servers - NS records
    IN      NS     router.${DOMAIN}.

; name servers - A records
router.${DOMAIN}.         IN      A      ${ROUTER}

; ${NETWORK}/${CIDR} - A records
EOF

cat << EOF > /etc/bind/db.${NET_PREFIX_ARPA}
@       IN      SOA     router.${DOMAIN}. admin.${DOMAIN}. (
                            3         ; Serial
                        604800         ; Refresh
                        86400         ; Retry
                        2419200         ; Expire
                        604800 )       ; Negative Cache TTL

; name servers - NS records
    IN      NS      router.${DOMAIN}.

; PTR Records
1    IN      PTR     router.${DOMAIN}.
EOF

mkdir -p /data/var/named/dynamic
mkdir /data/var/named/data
chown -R bind:bind /data/var/named
chown -R bind:bind /etc/bind

uci set dhcp.@dnsmasq[0].domain=${DOMAIN}
uci set dhcp.@dnsmasq[0].localuse=0
uci set dhcp.@dnsmasq[0].cachelocal=0
uci set dhcp.@dnsmasq[0].port=0
uci commit dhcp

uci set network.wan.dns=${ROUTER}
uci commit network

mv /etc/haproxy.cfg /etc/haproxy.cfg.orig

/etc/init.d/lighttpd disable
/etc/init.d/lighttpd stop

uci del_list uhttpd.main.listen_http="[::]:80"
uci del_list uhttpd.main.listen_http="0.0.0.0:80"
uci del_list uhttpd.main.listen_https="[::]:443"
uci del_list uhttpd.main.listen_https="0.0.0.0:443"
uci add_list uhttpd.main.listen_http="${ROUTER}:80"
uci add_list uhttpd.main.listen_https="${ROUTER}:443"
uci add_list uhttpd.main.listen_http="127.0.0.1:80"
uci add_list uhttpd.main.listen_https="127.0.0.1:443"
uci commit uhttpd


uci set network.lan_lb01=interface
uci set network.lan_lb01.ifname="@lan"
uci set network.lan_lb01.proto="static"
uci set network.lan_lb01.hostname="okd4-lb01.${DOMAIN}"
uci set network.lan_lb01.ipaddr="${LB_IP}/${NETMASK}"
uci commit network

groupadd haproxy
useradd -d /data/haproxy -g haproxy haproxy
mkdir -p /data/haproxy
chown -R haproxy:haproxy /data/haproxy

cat << EOF > /etc/haproxy.cfg
global

    log         127.0.0.1 local2

    chroot      /data/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     50000
    user        haproxy
    group       haproxy
    daemon

    stats socket /data/haproxy/stats

defaults
    mode                    http
    log                     global
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          10m
    timeout server          10m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 50000

listen okd4-api 
    bind ${LB_IP}:6443
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-bootstrap ${NET_PREFIX}.49:6443 check weight 1
    server okd4-master-0 ${NET_PREFIX}.60:6443 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:6443 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:6443 check weight 1

listen okd4-mc 
    bind ${LB_IP}:22623
    balance roundrobin
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-bootstrap ${NET_PREFIX}.49:22623 check weight 1
    server okd4-master-0 ${NET_PREFIX}.60:22623 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:22623 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:22623 check weight 1

listen okd4-apps 
    bind ${LB_IP}:80
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    server okd4-master-0 ${NET_PREFIX}.60:80 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:80 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:80 check weight 1

listen okd4-apps-ssl 
    bind ${LB_IP}:443
    balance source
    option                  tcplog
    mode tcp
    option tcpka
    option tcp-check
    server okd4-master-0 ${NET_PREFIX}.60:443 check weight 1
    server okd4-master-1 ${NET_PREFIX}.61:443 check weight 1
    server okd4-master-2 ${NET_PREFIX}.62:443 check weight 1
EOF

cp /etc/haproxy.cfg /etc/haproxy.bootstrap && cat /etc/haproxy.cfg | grep -v bootstrap > /etc/haproxy.no-bootstrap

/etc/init.d/named enable
/etc/init.d/uhttpd enable
/etc/init.d/haproxy enable

