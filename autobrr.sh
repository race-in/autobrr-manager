#!/usr/bin/env bash
set -e

VERSION="2.0"

RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
YELLOW="\e[33m"
RESET="\e[0m"

info(){ echo -e "${BLUE}➜ $1${RESET}"; }
success(){ echo -e "${GREEN}✔ $1${RESET}"; }
warn(){ echo -e "${YELLOW}⚠ $1${RESET}"; }
error(){ echo -e "${RED}✖ $1${RESET}"; exit 1; }

[ "$EUID" -ne 0 ] && error "Run as root"

#################################
# Latest release
#################################

get_latest(){

LATEST_URL=$(curl -s https://api.github.com/repos/autobrr/autobrr/releases/latest \
| grep browser_download_url \
| grep linux_x86_64.tar.gz \
| cut -d '"' -f4)

LATEST_VERSION=$(basename "$LATEST_URL" | sed -E 's/autobrr_([0-9.]+)_linux.*/\1/')

}

#################################
# Detect user
#################################

detect_user(){

USERS=($(ls /home))

if [ "${#USERS[@]}" -eq 1 ]; then
AUTOBRR_USER="${USERS[0]}"
else

echo
info "Available users:"
select u in "${USERS[@]}" "Manual"; do

if [ "$u" = "Manual" ]; then
read -rp "Enter username: " AUTOBRR_USER
break
fi

[ -n "$u" ] && AUTOBRR_USER="$u" && break

done

fi

id "$AUTOBRR_USER" &>/dev/null || error "User does not exist"

}

#################################
# Domain detect
#################################

detect_domain(){

DOMAIN=$(hostname -f)

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

#################################
# Find nginx server config
#################################

detect_nginx_server(){

SERVER_FILE=$(grep -Rl "server_name" /etc/nginx/sites-enabled | head -n1)

[ -z "$SERVER_FILE" ] && error "Cannot detect nginx server config"

info "Using nginx config: $SERVER_FILE"

}

#################################
# Install autobrr
#################################

install_autobrr(){

detect_user
detect_domain
detect_nginx_server
get_latest

SESSION_SECRET=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c32)

info "Installing autobrr $LATEST_VERSION"

cd /root

wget -q "$LATEST_URL" -O autobrr.tar.gz
tar -xzf autobrr.tar.gz

chmod +x autobrr
mv autobrr /usr/local/bin/autobrr

CFG="/home/$AUTOBRR_USER/.config/autobrr"

mkdir -p "$CFG/logs"

cat >"$CFG/config.toml" <<EOF
host = "127.0.0.1"
port = 7474
baseUrl = "/autobrr/"
logLevel = "INFO"
logPath = "logs/autobrr.log"
sessionSecret = "$SESSION_SECRET"
EOF

chown -R "$AUTOBRR_USER:$AUTOBRR_USER" "$CFG"

#################################
# Systemd
#################################

cat >/etc/systemd/system/autobrr@.service <<EOF
[Unit]
Description=autobrr service for %i
After=network.target

[Service]
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

#################################
# nginx location file
#################################

mkdir -p /etc/nginx/apps

cat >/etc/nginx/apps/autobrr.conf <<'EOF'
location = /autobrr { return 301 /autobrr/; }

location /autobrr/ {

proxy_pass http://127.0.0.1:7474;

proxy_http_version 1.1;

proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

proxy_buffering off;

}
EOF

#################################
# Inject include safely
#################################

if ! grep -q "apps/\*.conf" "$SERVER_FILE"; then

info "Patching nginx server config"

sed -i '/server_name/a \ \n    include /etc/nginx/apps/*.conf;\n' "$SERVER_FILE"

fi

#################################
# Reload nginx
#################################

if nginx -t; then
systemctl reload nginx
else
error "nginx config failed"
fi

#################################
# Verify
#################################

sleep 2

if ss -tulpn | grep -q 7474; then
success "autobrr running"
else
warn "autobrr port not detected"
fi

echo
success "Installation complete"
echo
echo "Open:"
echo "https://$DOMAIN/autobrr/"
echo

}

#################################
# Remove
#################################

remove_autobrr(){

systemctl stop 'autobrr@*' 2>/dev/null || true
systemctl disable 'autobrr@*' 2>/dev/null || true

rm -f /etc/systemd/system/autobrr@.service
systemctl daemon-reload

rm -f /usr/local/bin/autobrr
rm -f /etc/nginx/apps/autobrr.conf

find /home -type d -path "*/.config/autobrr" -exec rm -rf {} +

nginx -t && systemctl reload nginx

success "Removed"

}

#################################
# Menu
#################################

clear

echo
echo "============================"
echo " AUTOBRR INSTALLER v$VERSION"
echo "============================"
echo
echo "1) Install"
echo "2) Remove"
echo "3) Exit"
echo

read -rp "Select: " CH

case "$CH" in

1) install_autobrr ;;
2) remove_autobrr ;;
3) exit ;;

*) error "Invalid option"

esac
