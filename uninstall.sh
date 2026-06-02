#!/usr/bin/env bash
# uninstall.sh — remove the netscan node installed by install.sh.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

SVC=netscan
echo "[*] Stopping and disabling units…"
systemctl disable --now "${SVC}.timer"   2>/dev/null || true
systemctl disable --now "${SVC}.service" 2>/dev/null || true
rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${SVC}.timer"
systemctl daemon-reload 2>/dev/null || true

echo "[*] Removing files…"
rm -rf /opt/netscan /etc/netscan /root/.netscan-info
read -rp "Also delete scan data + intel clone in /var/lib/netscan? [y/N] " yn
[[ "${yn:-}" =~ ^[Yy] ]] && rm -rf /var/lib/netscan || echo "  kept /var/lib/netscan"

echo "[*] Removing service account…"
id netscan &>/dev/null && userdel netscan 2>/dev/null || true
getent group netscan >/dev/null && groupdel netscan 2>/dev/null || true

echo "[+] netscan removed. (Install logs in /var/log/netscan-install-*.log were left in place.)"
