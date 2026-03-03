# 🚀 Autobrr Manager

![Debian](https://img.shields.io/badge/Debian-11%2F12%2F13-red)
![License](https://img.shields.io/badge/License-MIT-green)
![Status](https://img.shields.io/badge/Status-Stable-brightgreen)

Production-ready autobrr installer for Debian VPS.

---

## ✨ Features

- Install / Update / Remove
- Multi-domain nginx detection
- Manual domain fallback
- Auto user detection
- Systemd per-user service
- Reverse proxy under `/autobrr/`
- Log file support with rotation
- Safe production behaviour

---

## 🧱 Requirements

- Debian 11 / 12 / 13
- nginx installed
- SSL configured (recommended)
- At least one Linux user in `/home`

---

## 📦 One-Line Install

```bash
bash <(curl -s https://raw.githubusercontent.com/race-in/autobrr-manager/main/autobrr.sh)
```

---

## 📦 Manual Usage

```bash
wget https://raw.githubusercontent.com/race-in/autobrr-manager/main/autobrr.sh
chmod +x autobrr.sh
sudo ./autobrr.sh
```

---

## 🖥 Menu

```
1) Install autobrr
2) Update autobrr
3) Remove autobrr
4) Exit
```

---

## 🌐 Access

```
https://your-domain/autobrr/
```

---

## 📜 Logs

```
/home/USER/.config/autobrr/logs/autobrr.log
```

Live view:

```bash
tail -f /home/USER/.config/autobrr/logs/autobrr.log
```

---

## 🔒 Safety

- Ignores `_`, `localhost`
- Won’t detect random `.pem` files
- Manual fallback if domain not found
- Per-user isolation

---

## 📄 License

MIT
