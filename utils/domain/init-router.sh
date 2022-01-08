#!/bin/ash

rm -rf /root/.ssh
rm -rf /data/*

mkdir -p /root/.ssh
dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear

uci set dropbear.@dropbear[0].PasswordAuth='off'
uci set dropbear.@dropbear[0].RootPasswordAuth='off'
uci commit dropbear

uci set network.wan.proto='static'
uci set network.wan.ipaddr=${EDGE_IP}
uci set network.wan.netmask=${NETMASK}
uci set network.wan.gateway=${EDGE_ROUTER}
uci set network.wan.hostname=router.${DOMAIN}
uci set network.wan.dns=${EDGE_ROUTER}
uci set network.lan.ipaddr=${ROUTER}
uci set network.lan.netmask=${NETMASK}
uci set network.lan.hostname=router.${DOMAIN}
uci delete network.guest
uci delete network.wan6
uci commit network

uci set system.@system[0].hostname=router.${DOMAIN}
uci commit system

unset zone
let i=0
let j=1
while [[ ${j} -eq 1 ]]
do
  zone=$(uci get firewall.@zone[${i}].name)
  let rc=${?}
  if [[ ${rc} -ne 0 ]]
  then
    let j=2
   elif [[ ${zone} == "wan" ]]
   then
     let j=0
   else
     let i=${i}+1
   fi
done
if [[ ${j} -eq 0 ]]
then
  uci set firewall.@zone[${i}].input='ACCEPT'
  uci set firewall.@zone[${i}].output='ACCEPT'
  uci set firewall.@zone[${i}].forward='ACCEPT'
  uci set firewall.@zone[${i}].masq='0'
  uci commit firewall
else
  echo "FIREWALL ZONE NOT FOUND, CCONFIGURE MANUALLY WITH LUCI"
fi

unset ENTRY
ENTRY=$(uci add firewall forwarding)
uci set firewall.${ENTRY}.src=wan
uci set firewall.${ENTRY}.dest=lan
uci commit firewall
