#!/bin/ash

opkg update && opkg install ip-full procps-ng-ps bind-server bind-tools wget sfdisk rsync resize2fs

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
bastion.${DOMAIN}.         IN      A      ${BASTION_HOST}
nexus.${DOMAIN}.           IN      A      ${BASTION_HOST}
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
10    IN      PTR     bastion.${DOMAIN}.
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

/etc/init.d/dnsmasq restart
/etc/init.d/named enable
/etc/init.d/named start

passwd -l root
