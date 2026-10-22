#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.3.0"
API_URL="https://api.github.com/repos/autobrr/autobrr/releases/latest"
BIN="/usr/local/bin/autobrr"
SERVICE_TEMPLATE="/etc/systemd/system/autobrr@.service"
NGINX_SNIPPET="/etc/nginx/apps/autobrr.conf"
PORT="7474"
BASE_URL="/autobrr/"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
info(){ printf '%s➜ %s%s\n' "$BLUE" "$*" "$RESET"; }
success(){ printf '%s✔ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn(){ printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$RESET"; }
die(){ printf '%s✖ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
backup_file(){ local f="$1"; if [[ -e "$f" ]]; then cp -a -- "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"; fi; }
trap 'rc=$?; if (( rc != 0 )); then echo "✖ Failed (exit $rc). Check the message above; existing config backups were retained." >&2; fi' EXIT

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
for cmd in curl wget tar sha256sum systemctl nginx getent awk grep sed; do need "$cmd"; done
[[ -r /etc/os-release ]] || die "Cannot identify operating system"
. /etc/os-release
[[ "${ID:-}" == debian ]] || warn "This installer is designed for Debian; detected ${PRETTY_NAME:-unknown}."
[[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]] || die "Only Linux x86_64 is currently supported by this script."
[[ -x "$(command -v nginx || true)" ]] || die "Nginx must be installed first."

get_latest(){
  local release
  release="$(curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 "$API_URL")" || die "Could not query Autobrr releases."
  LATEST_VERSION="$(printf '%s' "$release" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[0-9.]+"' | head -n1 | sed -E 's/.*"v?([0-9.]+)"/\1/')"
  LATEST_URL="$(printf '%s' "$release" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4 | grep -E '/autobrr_[0-9.]+_linux_x86_64\.tar\.gz$' | head -n1)"
  CHECKSUM_URL="$(printf '%s' "$release" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4 | grep -E '/autobrr_[0-9.]+_checksums\.txt$' | head -n1)"
  [[ -n "$LATEST_VERSION" && -n "$LATEST_URL" && -n "$CHECKSUM_URL" ]] || die "Could not find release archive/checksum for Linux x86_64."
}

list_users(){
  getent passwd | awk -F: '$6 ~ /^\/home\// && $7 !~ /(nologin|false)$/ {print $1}' | sort -u
}
choose_user(){
  local -a users=()
  mapfile -t users < <(list_users)
  (("${#users[@]}" > 0)) || die "No eligible login users with home directories under /home found."
  if (("${#users[@]}" == 1)); then AUTOBRR_USER="${users[0]}"; info "Using user: $AUTOBRR_USER"; return; fi
  echo "Select the Linux user that owns the Autobrr instance:"
  select u in "${users[@]}" "Manual input"; do
    [[ -n "${u:-}" ]] || { echo "Choose a listed option."; continue; }
    if [[ "$u" == "Manual input" ]]; then read -r -p "Username: " AUTOBRR_USER; else AUTOBRR_USER="$u"; fi
    break
  done
  [[ "$AUTOBRR_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || die "Invalid username."
  getent passwd "$AUTOBRR_USER" >/dev/null || die "User does not exist: $AUTOBRR_USER"
  USER_HOME="$(getent passwd "$AUTOBRR_USER" | cut -d: -f6)"
  [[ "$USER_HOME" == /home/* && -d "$USER_HOME" ]] || die "Selected user's home must be an existing directory under /home."
}
get_user_home(){ USER_HOME="$(getent passwd "$AUTOBRR_USER" | cut -d: -f6)"; [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "Cannot determine home for $AUTOBRR_USER"; }

install_binary(){
  local tmp checksum expected actual
  tmp="$(mktemp -d)"
  trap 'rc=$?; rm -rf -- "${tmp:-}"; if (( rc != 0 )); then echo "✖ Operation failed; backups retained." >&2; fi' RETURN
  curl --fail --silent --show-error --location --retry 3 "$LATEST_URL" -o "$tmp/autobrr.tar.gz"
  curl --fail --silent --show-error --location --retry 3 "$CHECKSUM_URL" -o "$tmp/checksums.txt"
  checksum="$(grep -E "[[:space:]*]?autobrr_${LATEST_VERSION}_linux_x86_64\.tar\.gz$" "$tmp/checksums.txt" | head -n1 | awk '{print $1}')"
  [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || die "Could not find a valid SHA-256 checksum in the official checksum file."
  actual="$(sha256sum "$tmp/autobrr.tar.gz" | awk '{print $1}')"
  [[ "${actual,,}" == "${checksum,,}" ]] || die "Checksum mismatch. Refusing to install the downloaded archive."
  tar -tzf "$tmp/autobrr.tar.gz" | grep -qx 'autobrr' || die "Archive does not contain the expected autobrr binary."
  tar -xzf "$tmp/autobrr.tar.gz" -C "$tmp" autobrr
  [[ -x "$tmp/autobrr" || -f "$tmp/autobrr" ]] || die "Binary missing from archive."
  chmod 0755 "$tmp/autobrr"
  if [[ -e "$BIN" ]]; then cp -a "$BIN" "${BIN}.bak.$(date +%Y%m%d%H%M%S)"; fi
  install -o root -g root -m 0755 "$tmp/autobrr" "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  rm -rf -- "$tmp"
  trap - RETURN
}
write_service(){
  backup_file "$SERVICE_TEMPLATE"
  cat >"$SERVICE_TEMPLATE" <<'EOF'
[Unit]
Description=autobrr service for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=%h/.config/autobrr
ExecStart=/usr/local/bin/autobrr --config=%h/.config/autobrr/
Restart=on-failure
RestartSec=5
UMask=0027
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_TEMPLATE"
  systemctl daemon-reload
}
write_nginx(){
  mkdir -p /etc/nginx/apps
  if ! nginx -T 2>/dev/null | grep -Fq 'include /etc/nginx/apps/*.conf'; then
    die "Nginx does not include /etc/nginx/apps/*.conf. Add that include inside the intended HTTPS server block, then rerun. No active Nginx config was changed."
  fi
  backup_file "$NGINX_SNIPPET"
  cat >"$NGINX_SNIPPET" <<EOF
location = /autobrr { return 301 /autobrr/; }
location /autobrr/ {
  proxy_pass http://127.0.0.1:$PORT/autobrr/;
  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_redirect off;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
  if nginx -t; then systemctl reload nginx; else
    rm -f "$NGINX_SNIPPET"
    die "Nginx validation failed; the new snippet was removed. Review the backup if one was created."
  fi
}
install_autobrr(){
  choose_user
  get_user_home
  get_latest
  local cfg secret
  cfg="$USER_HOME/.config/autobrr"
  mkdir -p "$cfg/logs"
  if [[ -e "$cfg/config.toml" ]]; then
    backup_file "$cfg/config.toml"
    warn "Existing config backed up. Existing database and other user data will be preserved."
  fi
  secret="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  install_binary
  if [[ ! -e "$cfg/config.toml" ]]; then
    cat >"$cfg/config.toml" <<EOF
host = "127.0.0.1"
port = $PORT
baseUrl = "$BASE_URL"
baseUrlModeLegacy = false
logLevel = "INFO"
logPath = "logs/autobrr.log"
logMaxSize = 50
logMaxBackups = 5
sessionSecret = "$secret"
checkForUpdates = true
EOF
  else
    info "Preserving existing config.toml; verify host, port and baseUrl manually if this is a new reverse proxy setup."
  fi
  chown -R "$AUTOBRR_USER":"$(id -gn "$AUTOBRR_USER")" "$cfg"
  chmod 0750 "$cfg"
  write_service
  write_nginx
  systemctl enable --now "autobrr@$AUTOBRR_USER.service"
  sleep 2
  systemctl is-active --quiet "autobrr@$AUTOBRR_USER.service" || { systemctl status "autobrr@$AUTOBRR_USER.service" --no-pager || true; die "Autobrr service did not become active."; }
  success "Autobrr $LATEST_VERSION installed for $AUTOBRR_USER."
  echo "Open: https://YOUR-DOMAIN/autobrr/"
  echo "Logs: $cfg/logs/autobrr.log"
}
update_autobrr(){
  local -a units=()
  mapfile -t units < <(systemctl list-units --all --type=service --no-legend 'autobrr@*.service' | awk '{print $1}' | grep -E '^autobrr@.+\.service$' || true)
  (("${#units[@]}" > 0)) || die "No autobrr@USER.service instance found; nothing to update."
  get_latest
  if [[ -x "$BIN" ]]; then
    local cur
    cur="$("$BIN" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [[ -n "$cur" && "$cur" == "$LATEST_VERSION" ]]; then success "Already up to date ($cur)"; return; fi
  fi
  local -a active=()
  for unit in "${units[@]}"; do if systemctl is-active --quiet "$unit"; then active+=("$unit"); fi; done
  for unit in "${active[@]}"; do systemctl stop "$unit"; done
  install_binary
  local failed=0
  for unit in "${active[@]}"; do systemctl start "$unit" || failed=1; done
  if (( failed )); then die "Updated binary, but one or more services failed to restart. Check: journalctl -u 'autobrr@*.service'"; fi
  success "Autobrr updated to $LATEST_VERSION; restarted ${#active[@]} previously active service(s)."
}
remove_autobrr(){
  warn "This removes the Autobrr binary, service template, and manager-owned Nginx snippet. User configs/database will be preserved."
  read -r -p "Continue? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
  local -a units=()
  mapfile -t units < <(systemctl list-units --all --type=service --no-legend 'autobrr@*.service' | awk '{print $1}' | grep -E '^autobrr@.+\.service$' || true)
  local -a enabled=()
  mapfile -t enabled < <(systemctl list-unit-files --type=service --no-legend 'autobrr@*.service' | awk '$2=="enabled" {print $1}' | grep -E '^autobrr@.+\.service$' || true)
  for unit in "${units[@]}"; do systemctl stop "$unit" || warn "Could not stop $unit"; done
  for unit in "${enabled[@]}"; do systemctl disable "$unit" || warn "Could not disable $unit"; done
  rm -f "$SERVICE_TEMPLATE"
  systemctl daemon-reload
  if [[ -e "$NGINX_SNIPPET" ]]; then backup_file "$NGINX_SNIPPET"; rm -f "$NGINX_SNIPPET"; fi
  if nginx -t; then systemctl reload nginx; else warn "Nginx validation failed after snippet removal; inspect Nginx configuration before reloading."; fi
  if [[ -e "$BIN" ]]; then backup_file "$BIN"; rm -f "$BIN"; fi
  success "Autobrr manager components removed. User configs/data were preserved."
}
menu(){
  clear 2>/dev/null || true
  printf '%s\n' '================================' '      AUTOBRR MANAGER' '================================' "Version: $VERSION" '' '1) Install autobrr' '2) Update autobrr' '3) Remove autobrr components' '4) Exit' ''
  read -r -p "Select option [1-4]: " choice
  case "$choice" in
    1) install_autobrr ;;
    2) update_autobrr ;;
    3) remove_autobrr ;;
    4) exit 0 ;;
    *) die "Invalid option." ;;
  esac
}
menu
