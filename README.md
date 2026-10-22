# 🚀 Autobrr Manager

A Bash-based installer and lifecycle manager for Autobrr on Debian VPS.

![Debian](https://img.shields.io/badge/Debian-11%2F12%2F13-red)
![License](https://img.shields.io/badge/License-MIT-green)

> **Status:** improved safety checks are in the fix/installer-safety-and-lifecycle branch. Test on a staging VPS before production use.

## Features
- Install, update, and remove manager-owned components
- Detect eligible Linux users and support manual selection
- Systemd service template per user
- SHA-256 verification against the official release checksum file
- Preserve existing Autobrr config/database during update and removal
- Back up replaced binaries and configuration snippets
- Nginx reverse-proxy snippet for /autobrr/
- Verify service health after installation

## Requirements
- Debian 11 / 12 / 13 (other distributions are not guaranteed)
- Root access
- curl, wget, tar, sha256sum, systemd, and Nginx
- Linux x86_64 / amd64
- A login user with an existing home directory under /home
- Nginx must already include /etc/nginx/apps/*.conf in the intended HTTPS server block

## Install
Review the script before running it as root.

```bash
wget https://raw.githubusercontent.com/race-in/autobrr-manager/fix/installer-safety-and-lifecycle/autobrr.sh
less autobrr.sh
sudo bash autobrr.sh
```

The installer verifies the downloaded binary checksum. It does not create TLS certificates or guess which Nginx virtual host should be modified.

## Lease VPS entry point
The Lease VPS script delegates to the shared installer so the two entry points do not drift apart.

```bash
wget https://raw.githubusercontent.com/race-in/autobrr-manager/fix/installer-safety-and-lifecycle/autobrr.lease.vps.sh
less autobrr.lease.vps.sh
sudo bash autobrr.lease.vps.sh
```

## Menu
1. Install Autobrr
2. Update Autobrr
3. Remove manager-owned components
4. Exit

## Access
After configuring DNS and TLS on your own domain:

```text
https://your-domain/autobrr/
```

For this proxy path, verify the active config uses host = "127.0.0.1", port = 7474, and baseUrl = "/autobrr/". Existing configs are deliberately preserved.

## Service and logs
```bash
systemctl status autobrr@YOUR_USER.service
journalctl -u autobrr@YOUR_USER.service -f
tail -f /home/YOUR_USER/.config/autobrr/logs/autobrr.log
```

## Safety notes
- Update restarts discovered active autobrr@USER.service instances.
- Removal asks for confirmation and preserves user configuration/database data.
- Replaced binary/config files are backed up.
- Nginx configuration is validated before reload.
- Checksum verification does not replace reviewing the installer source.
- Always test on a staging VPS before production.

## Validation
```bash
bash -n autobrr.sh
bash -n autobrr.lease.vps.sh
shellcheck autobrr.sh autobrr.lease.vps.sh
```

## License
MIT
