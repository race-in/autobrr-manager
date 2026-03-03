#!/usr/bin/env bash
set -e

############################
# COLORS
############################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

############################
# HELPERS
############################
info()    { echo -e "${BLUE}➜ $1${RESET}"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}"; }
error()   { echo -e "${RED}✖ $1${RESET}"; exit 1; }

progress() {
  for i in {1..20}; do
    echo -ne "${GREEN}#${RESET}"
    sleep 0.05
  done
  echo
}

############################
# ROOT CHECK
############################
[ "$EUID" -ne 0 ] && error "Run as root"

############################
# LATEST AUTOBRR
############################
get_latest() {
  LATEST_URL=$(curl -s https://api.github.com/repos/autobrr/autobrr/releases/latest \
    | grep browser_download_url \
    | grep linux_x86_64.tar.gz \
    | cut -d\" -f4)

  [ -z "$LATEST_URL" ] && error "Cannot detect latest autobrr"

  LATEST_VERSION=$(basename "$LATEST_URL" | sed -E 's/autobrr_([0-9.]+)_linux.*/\1/')
}

############################
# DOMAIN DETECT (FIXED)
############################
detect_domain() {

  # Try nginx server_name
  DOMAIN=$(grep -R "server_name" /etc/nginx/sites-enabled 2>/dev/null \
    | grep -v "_" \
    | grep -v "localhost" \
    | sed -E 's/.*server_name\s+([^;]+);/\1/' \
    | awk '{print $1}' \
    | head -n1)

  # Fallback: FQDN hostname (only if real domain)
  if [ -z "$DOMAIN" ]; then
    HOSTNAME_FQDN=$(hostname -f 2>/dev/null || true)
    if [[ "$HOSTNAME_FQDN" == *.* ]]; then
      DOMAIN="$HOSTNAME_FQDN"
    fi
  fi

  # Ask manually if still empty
  if [ -z "$DOMAIN" ]; then
    warn "Could not auto-detect domain."
    read -rp "👉 Enter your domain manually (example.com): " DOMAIN
  else
    info "Using domain: $DOMAIN"
  fi
}

############################
# USER DETECT
############################
detect_user() {
  USERS=($(ls /home 2>/dev/null || true))

  if [ "${#USERS[@]}" -eq 1 ]; then
    AUTOBRR_USER="${USERS[0]}"
    info "Detected user: $AUTOBRR_USER"
    return
  fi

  if [ "${#USERS[@]}" -gt 1 ]; then
    echo
    info "Available users:"
    select u in "${USERS[@]}" "Manual input"; do
      if [ "$u" = "Manual input" ]; then
        read -rp "Enter username: " AUTOBRR_USER
        break
      elif [ -n "$u" ]; then
        AUTOBRR_USER="$u"
        break
      fi
    done
    return
  fi

  warn "No users detected in /home"
  read -rp "Enter username manually: " AUTOBRR_USER
}

############################
# INSTALL
############################
install_autobrr() {
  detect_user
  id "$AUTOBRR_USER" &>/dev/null || error "User does not exist"

  detect_domain

  SESSION_SECRET=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c32)

  get_latest
  info "Installing autobrr v$LATEST_VERSION"
  progress

  cd /root
  wget -q "$LATEST_URL" -O autobrr.tar.gz
  tar -xzf autobrr.tar.gz
  chmod +x autobrr
  mv autobrr /usr/local/bin/autobrr

  CFG="/home/$AUTOBRR_USER/.config/autobrr"
  LOGDIR="$CFG/logs"
  mkdir -p "$LOGDIR"
  chown -R "$AUTOBRR_USER:$AUTOBRR_USER" "$CFG"

  cat >"$CFG/config.toml" <<EOF
host = "127.0.0.1"
port = 7474
baseUrl = "/autobrr/"
baseUrlModeLegacy = false
logLevel = "INFO"
logPath = "logs/autobrr.log"
logMaxSize = 50
logMaxBackups = 5
sessionSecret = "$SESSION_SECRET"
checkForUpdates = true
EOF

  chown "$AUTOBRR_USER:$AUTOBRR_USER" "$CFG/config.toml"

  cat >/etc/systemd/system/autobrr@.service <<'EOF'
[Unit]
Description=autobrr service for %i
After=network-online.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/home/%i/.config/autobrr
ExecStart=/usr/local/bin/autobrr --config=/home/%i/.config/autobrr/
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable autobrr@"$AUTOBRR_USER"
  systemctl restart autobrr@"$AUTOBRR_USER"

  cat >/etc/nginx/apps/autobrr.conf <<EOF
location = /autobrr { return 301 /autobrr/; }
location /autobrr/ {
  proxy_pass http://127.0.0.1:7474/autobrr/;
  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_redirect off;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF

  nginx -t && systemctl reload nginx

  success "Installed successfully"
  echo
  echo -e "${GREEN}🌐 https://$DOMAIN/autobrr/${RESET}"
  echo -e "${BLUE}📄 Logs: /home/$AUTOBRR_USER/.config/autobrr/logs/autobrr.log${RESET}"
}

############################
# UPDATE
############################
update_autobrr() {
  command -v autobrr >/dev/null || error "autobrr not installed"

  get_latest
  CUR=$(autobrr version | awk '/Version/{print $2}')

  [ "$CUR" = "$LATEST_VERSION" ] && success "Already up to date ($CUR)" && return

  info "Updating autobrr $CUR → $LATEST_VERSION"
  progress

  TMP=$(mktemp -d)
  cd "$TMP"
  wget -q "$LATEST_URL" -O autobrr.tar.gz
  tar -xzf autobrr.tar.gz
  chmod +x autobrr
  mv autobrr /usr/local/bin/autobrr

  systemctl restart autobrr@"$AUTOBRR_USER"
  rm -rf "$TMP"

  success "Update complete"
}

############################
# REMOVE
############################
remove_autobrr() {
  warn "Removing autobrr completely"
  progress

  systemctl stop 'autobrr@*' 2>/dev/null || true
  systemctl disable 'autobrr@*' 2>/dev/null || true
  rm -f /etc/systemd/system/autobrr@.service
  systemctl daemon-reload
  rm -f /usr/local/bin/autobrr
  rm -f /etc/nginx/apps/autobrr.conf
  find /home -type d -path "*/.config/autobrr" -exec rm -rf {} +

  nginx -t && systemctl reload nginx

  success "autobrr fully removed"
}

############################
# MENU
############################
clear
echo -e "${GREEN}"
echo "================================"
echo "   AUTOBRR MANAGEMENT TOOL"
echo "================================"
echo -e "${RESET}"
echo "1) Install autobrr"
echo "2) Update autobrr"
echo "3) Remove autobrr"
echo "4) Exit"
echo
read -rp "Select option [1-4]: " CH

case "$CH" in
  1) install_autobrr ;;
  2) update_autobrr ;;
  3) remove_autobrr ;;
  4) exit 0 ;;
  *) error "Invalid option" ;;

esac
