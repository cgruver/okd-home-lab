#!/bin/ash

mkdir /tmp/work-dir
cd /tmp/work-dir

PKG="openjdk8-8 openjdk8-jre-8 openjdk8-jre-lib-8 openjdk8-jre-base-8 java-cacerts"

for package in ${PKG}; do
   FILE=$(lftp -e "cls -1 alpine/edge/community/aarch64/${package}*; quit" http://dl-cdn.alpinelinux.org)
   curl -LO http://dl-cdn.alpinelinux.org/${FILE}
done

for i in $(ls)
do
   tar xzf ${i}
done

mv ./usr/lib/jvm/java-1.8-openjdk /usr/local/java-1.8-openjdk

export PATH=${PATH}:/root/bin:/usr/local/java-1.8-openjdk/bin
echo "export PATH=\$PATH:/root/bin:/usr/local/java-1.8-openjdk/bin" >> /root/.profile

opkg update
opkg install ca-certificates
      
rm -f /usr/local/java-1.8-openjdk/jre/lib/security/cacerts
keytool -noprompt -importcert -file /etc/ssl/certs/ca-certificates.crt -keystore /usr/local/java-1.8-openjdk/jre/lib/security/cacerts -keypass changeit -storepass changeit


for i in $(find /etc/ssl/certs -type f)
do
  ALIAS=$(echo ${i} | cut -d"/" -f5)
  keytool -noprompt -importcert -file ${i} -alias ${ALIAS}  -keystore /usr/local/java-1.8-openjdk/jre/lib/security/cacerts -keypass changeit -storepass changeit
done

cd
rm -rf /tmp/work-dir

mkdir -p /usr/local/nexus/home
cd /usr/local/nexus
wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz -O latest-unix.tar.gz
tar -xzf latest-unix.tar.gz
NEXUS=$(ls -d nexus-*)
ln -s ${NEXUS} nexus-3
rm -f latest-unix.tar.gz

groupadd nexus
useradd -g nexus -d /usr/local/nexus/home nexus
chown -R nexus:nexus /usr/local/nexus

sed -i "s|#run_as_user=\"\"|run_as_user=\"nexus\"|g" /usr/local/nexus/nexus-3/bin/nexus.rc

cat <<EOF > /etc/init.d/nexus
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   ulimit -Hn 65536
   ulimit -Sn 65536
    service_start /usr/local/nexus/nexus-3/bin/nexus start
}

stop() {
    service_stop /usr/local/nexus/nexus-3/bin/nexus stop
}
EOF

chmod 755 /etc/init.d/nexus

sed -i "s|# INSTALL4J_JAVA_HOME_OVERRIDE=|INSTALL4J_JAVA_HOME_OVERRIDE=/usr/local/java-1.8-openjdk|g" /usr/local/nexus/nexus-3/bin/nexus

keytool -genkeypair -keystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname "CN=nexus.${DOMAIN}, OU=okd4-lab, O=okd4-lab, L=City, ST=State, C=US" -ext "SAN=DNS:nexus.${DOMAIN},IP:${BASTION_HOST}" -ext "BC=ca:true"
keytool -importkeystore -srckeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -destkeystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -srcstorepass password
rm -f /usr/local/nexus/nexus-3/etc/ssl/keystore.jks.old

chown nexus:nexus /usr/local/nexus/nexus-3/etc/ssl/keystore.jks

mkdir /usr/local/nexus/sonatype-work/nexus3/etc
cat <<EOF >> /usr/local/nexus/sonatype-work/nexus3/etc/nexus.properties
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-https.xml,\${jetty.etc}/jetty-requestlog.xml
application-port-ssl=8443
EOF
chown -R nexus:nexus /usr/local/nexus/sonatype-work/nexus3/etc

/etc/init.d/nexus enable
/etc/init.d/nexus start
