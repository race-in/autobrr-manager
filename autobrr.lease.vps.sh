#!/usr/bin/env bash
# Compatibility entry point for Leaseweb VPS users.
# Keep all lifecycle/security fixes in one maintained installer.
set -Eeuo pipefail
SCRIPT_URL="https://raw.githubusercontent.com/race-in/autobrr-manager/fix/installer-safety-and-lifecycle/autobrr.sh"
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_SCRIPT"' EXIT
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
curl --fail --silent --show-error --location --retry 3 "$SCRIPT_URL" -o "$TMP_SCRIPT"
bash "$TMP_SCRIPT"
