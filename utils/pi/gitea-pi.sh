#!/bin/ash

GITEA_VERSION=${1}

opkg update && opkg install sqlite3-cli openssh-keygen

mkdir -p /usr/local/gitea
for i in bin etc custom data db git
do
  mkdir /usr/local/gitea/${i}
done
wget -O /usr/local/gitea/bin/gitea https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-arm64
chmod 750 /usr/local/gitea/bin/gitea

cd /usr/local/gitea/custom
/usr/local/gitea/bin/gitea cert --host gitea.${DOMAIN}
cd

INTERNAL_TOKEN=$(/usr/local/gitea/bin/gitea generate secret INTERNAL_TOKEN)
SECRET_KEY=$(/usr/local/gitea/bin/gitea generate secret SECRET_KEY)
JWT_SECRET=$(/usr/local/gitea/bin/gitea generate secret JWT_SECRET)

cat << EOF > /usr/local/gitea/etc/app.ini
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /usr/local/gitea/git
SCRIPT_TYPE = sh
DEFAULT_BRANCH = main
DEFAULT_PUSH_CREATE_PRIVATE = true
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[server]
PROTOCOL = https
ROOT_URL = https://gitea.${DOMAIN}:3000/
HTTP_PORT = 3000
CERT_FILE = cert.pem
KEY_FILE  = key.pem
STATIC_ROOT_PATH = /usr/local/gitea/web
APP_DATA_PATH    = /usr/local/gitea/data
LFS_START_SERVER = true

[service]
DISABLE_REGISTRATION = true

[database]
DB_TYPE = sqlite3
PATH = /usr/local/gitea/db/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[session]
PROVIDER = file

[log]
ROOT_PATH = /usr/local/gitea/log
MODE = file
LEVEL = Info
EOF

groupadd gitea
useradd -g gitea -d /usr/local/gitea gitea
chown -R gitea:gitea /usr/local/gitea

cat <<EOF > /etc/init.d/gitea
#!/bin/sh /etc/rc.common

START=99
STOP=80
SERVICE_USE_PID=0

start() {
   service_start /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/bin/nohup /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini web > /dev/null 2>&1 &'
}

restart() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager restart'
}

stop() {
   /usr/bin/su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager shutdown'
}
EOF

chmod 755 /etc/init.d/gitea

su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini migrate'
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --admin --username gitea --password password --email gitea@gitea.${DOMAIN} --must-change-password"
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --username devuser --password password --email devuser@gitea.${DOMAIN} --must-change-password"

/etc/init.d/gitea enable
/etc/init.d/gitea start

