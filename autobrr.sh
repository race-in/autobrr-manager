#!/usr/bin/env bash
set -e

VERSION="1.3.0"

############################
# COLORS
############################

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

info(){ echo -e "${BLUE}➜ $1${RESET}"; }
success(){ echo -e "${GREEN}✔ $1${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $1${RESET}"; }
error(){ echo -e "${RED}✖ $1${RESET}"; exit 1; }

[ "$EUID" -ne 0 ] && error "Run as root"

############################
# FETCH LATEST AUTOBRR
############################

get_latest() {

LATEST_URL=$(curl -s https://api.github.com/repos/autobrr/autobrr/releases/latest \
| grep browser_download_url \
| grep linux_x86_64.tar.gz \
| cut -d\" -f4)

[ -z "$LATEST_URL" ] && error "Cannot detect autobrr release"

LATEST_VERSION=$(basename "$LATEST_URL" | sed -E 's/autobrr_([0-9.]+)_linux.*/\1/')
}

############################
# DOMAIN DETECT
############################

detect_domain(){

DOMAIN=$(hostname -f 2>/dev/null || true)

if [[ ! "$DOMAIN" =~ \. ]]; then
DOMAIN=$(grep -R "server_name" /etc/nginx/sites-enabled 2>/dev/null \
| grep -v "_" \
| grep -v localhost \
| sed -E 's/.*server_name\s+([^;]+);/\1/' \
| awk '{print $1}' \
| head -n1)
fi

[ -z "$DOMAIN" ] && read -rp "Enter domain: " DOMAIN

info "Using domain: $DOMAIN"
}

############################
# USER DETECT
############################

detect_user(){

USERS=($(ls /home))

if [ "${#USERS[@]}" -eq 1 ]; then
AUTOBRR_USER="${USERS[0]}"
info "Detected user: $AUTOBRR_USER"
return
fi

echo
info "Available users:"
select u in "${USERS[@]}" "Manual"; do

if [ "$u" = "Manual" ]; then
read -rp "Enter username: " AUTOBRR_USER
break
fi

[ -n "$u" ] && AUTOBRR_USER="$u" && break

done

}

############################
# NGINX INCLUDE CHECK
############################

fix_nginx_include(){

if ! grep -q "apps/\*.conf" /etc/nginx/nginx.conf; then

info "Enabling nginx apps include"

sed -i '/http {/a \    include /etc/nginx/apps/*.conf;' /etc/nginx/nginx.conf

fi

mkdir -p /etc/nginx/apps
}

############################
# INSTALL
############################

install_autobrr(){

detect_user
id "$AUTOBRR_USER" &>/dev/null || error "User does not exist"

detect_domain
get_latest
fix_nginx_include

SESSION_SECRET=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c32)

info "Installing autobrr $LATEST_VERSION"

cd /root

wget -q "$LATEST_URL" -O autobrr.tar.gz
tar -xzf autobrr.tar.gz

chmod +x autobrr
mv autobrr /usr/local/bin/autobrr

CFG="/home/$AUTOBRR_USER/.config/autobrr"
LOGDIR="$CFG/logs"

mkdir -p "$LOGDIR"

cat >"$CFG/config.toml" <<EOF
host = "127.0.0.1"
port = 7474
baseUrl = "/autobrr/"
baseUrlModeLegacy = false
logLevel = "INFO"
logPath = "logs/autobrr.log"
sessionSecret = "$SESSION_SECRET"
EOF

chown -R "$AUTOBRR_USER:$AUTOBRR_USER" "$CFG"

############################
# SYSTEMD SERVICE
############################

cat >/etc/systemd/system/autobrr@.service <<EOF
[Unit]
Description=autobrr service for %i
After=network-online.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/home/%i/.config/autobrr
ExecStart=/usr/local/bin/autobrr --config /home/%i/.config/autobrr/
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable autobrr@"$AUTOBRR_USER"
systemctl start autobrr@"$AUTOBRR_USER"

############################
# NGINX CONFIG
############################

cat >/etc/nginx/apps/autobrr.conf <<EOF
location = /autobrr { return 301 /autobrr/; }

location /autobrr/ {

proxy_pass http://127.0.0.1:7474;

proxy_http_version 1.1;

proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;

proxy_buffering off;

}
EOF

if nginx -t; then
systemctl reload nginx
else
error "nginx config failed"
fi

sleep 2

############################
# VERIFY
############################

if ss -tulpn | grep -q 7474; then
success "autobrr running"
else
warn "autobrr may not be running"
fi

echo
success "Installation complete"
echo
echo "URL:"
echo "https://$DOMAIN/autobrr/"
echo
}

############################
# UPDATE
############################

update_autobrr(){

detect_user
command -v autobrr >/dev/null || error "autobrr not installed"

get_latest

CUR=$(autobrr --version 2>/dev/null | awk '{print $2}')

if [ "$CUR" = "$LATEST_VERSION" ]; then
success "Already latest ($CUR)"
return
fi

info "Updating autobrr"

systemctl stop autobrr@"$AUTOBRR_USER"

TMP=$(mktemp -d)
cd "$TMP"

wget -q "$LATEST_URL" -O autobrr.tar.gz
tar -xzf autobrr.tar.gz

chmod +x autobrr
mv autobrr /usr/local/bin/autobrr

systemctl start autobrr@"$AUTOBRR_USER"

success "Update complete"
}

############################
# REMOVE
############################

remove_autobrr(){

warn "Removing autobrr"

systemctl stop 'autobrr@*' 2>/dev/null || true
systemctl disable 'autobrr@*' 2>/dev/null || true

rm -f /etc/systemd/system/autobrr@.service
systemctl daemon-reload

rm -f /usr/local/bin/autobrr
rm -f /etc/nginx/apps/autobrr.conf

find /home -type d -path "*/.config/autobrr" -exec rm -rf {} +

if nginx -t; then
systemctl reload nginx
fi

success "Removed completely"
}

############################
# MENU
############################

clear

echo
echo "=============================="
echo "   AUTOBRR MANAGEMENT TOOL"
echo "=============================="
echo
echo "1) Install"
echo "2) Update"
echo "3) Remove"
echo "4) Exit"
echo

read -rp "Select: " CH

case "$CH" in

1) install_autobrr ;;
2) update_autobrr ;;
3) remove_autobrr ;;
4) exit ;;

*) error "Invalid option"

esac
