#!/bin/ash

WIFI_ENCRYPT="psk2"

rm -rf /root/.ssh
mkdir -p /root/.ssh
dropbearkey -t rsa -s 4096 -f /root/.ssh/id_dropbear

uci set dropbear.@dropbear[0].PasswordAuth="off"
uci set dropbear.@dropbear[0].RootPasswordAuth="off"
uci commit dropbear

uci set network.lan.ipaddr="${ROUTER}"
uci set network.lan.netmask=${NETMASK}
uci set network.lan.hostname=router.${DOMAIN}
uci delete network.guest
uci delete network.wan6
uci commit network

uci set dhcp.lan.leasetime="5m"
uci set dhcp.lan.start="11"
uci set dhcp.lan.limit="19"
uci add_list dhcp.lan.dhcp_option="6,${ROUTER}"
uci delete dhcp.guest

uci commit dhcp

uci delete wireless.guest2g
uci delete wireless.sta2

uci set wireless.radio2.disabled="0"
uci set wireless.radio2.repeater="1"
uci set wireless.radio2.legacy_rates="0"
uci set wireless.radio2.htmode="HT20"
uci set wireless.sta=wifi-iface
uci set wireless.sta.device="radio2"
uci set wireless.sta.ifname="wlan2"
uci set wireless.sta.mode="sta"
uci set wireless.sta.disabled="0"
uci set wireless.sta.network="wwan"
uci set wireless.sta.wds="0"
uci set wireless.sta.ssid="${WIFI_SSID}"  
uci set wireless.sta.encryption="${WIFI_ENCRYPT}"      
uci set wireless.sta.key="${WIFI_KEY}"    
uci commit wireless

uci set network.wwan=interface
uci set network.wwan.proto="dhcp"
uci set network.wwan.metric="20"
uci commit network

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
  uci add_list firewall.@zone[${i}].network="wwan"
  uci commit firewall
 else
   echo "FIREWALL ZONE NOT FOUND, CCONFIGURE MANUALLY WITH LUCI"
 fi

 uci set wireless.default_radio0=wifi-iface
uci set wireless.default_radio0.device="radio0"
uci set wireless.default_radio0.ifname="wlan0"
uci set wireless.default_radio0.network="lan"
uci set wireless.default_radio0.mode="ap"
uci set wireless.default_radio0.disabled="0"
uci set wireless.default_radio0.ssid="${LAB_WIFI_SSID}"
uci set wireless.default_radio0.key="${LAB_WIFI_KEY}"
uci set wireless.default_radio0.encryption="psk2"
uci set wireless.default_radio0.multi_ap="1"
uci set wireless.radio0.legacy_rates="0"
uci set wireless.radio0.htmode="HT20"
uci commit wireless
