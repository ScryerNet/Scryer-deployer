#!/usr/bin/env bash
# setup-vm.sh — provision a Debian VM with the scanner toolchain.
# Runs ON the VM (deploy.sh pushes and executes it). Idempotent.
set -euo pipefail

echo "[*] Updating apt and installing base deps..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
    git curl wget build-essential ca-certificates \
    libpcap-dev clang gcc make \
    python3 python3-pip \
    masscan jq

# --- Go (needed to build zgrab2 / zdns / jarm-go) ---
GO_VERSION="1.22.5"
if ! command -v go >/dev/null 2>&1; then
    echo "[*] Installing Go ${GO_VERSION}..."
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
grep -q '/usr/local/go/bin' "$HOME/.bashrc" || \
    echo 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"' >> "$HOME/.bashrc"

# --- zgrab2 (TLS/SSH/HTTP banner + fingerprint grabber) ---
if [ ! -x "$HOME/go/bin/zgrab2" ]; then
    echo "[*] Building zgrab2..."
    go install github.com/zmap/zgrab2/cmd/zgrab2@latest
fi

# --- zdns (fast DNS) ---
if [ ! -x "$HOME/go/bin/zdns" ]; then
    echo "[*] Building zdns..."
    go install github.com/zmap/zdns/v2@latest
fi

# --- JARM (active TLS server fingerprint) ---
if [ ! -x "$HOME/go/bin/jarm" ]; then
    echo "[*] Building jarm-go..."
    go install github.com/RumbleDiscovery/jarm-go/cmd/jarm@latest 2>/dev/null || {
        echo "[!] jarm-go install failed; falling back to python jarm"
        pip3 install --break-system-packages jarm || true
    }
fi

# --- Kernel / network prep for masscan ---
# masscan uses its own TCP/IP stack. The Linux kernel will see the SYN-ACK replies,
# find no matching socket, and emit RST packets. masscan still captures the SYN-ACK
# first so scanning works, but dropping our own RSTs keeps things clean and avoids
# confusing target hosts. We pin masscan's source ports to 40000-41000 (see config)
# and drop outbound RSTs from that range.
echo "[*] Installing iptables RST-drop rule for masscan source ports..."
sudo apt-get install -y iptables
if ! sudo iptables -C OUTPUT -p tcp --tcp-flags RST RST --sport 40000:41000 -j DROP 2>/dev/null; then
    sudo iptables -A OUTPUT -p tcp --tcp-flags RST RST --sport 40000:41000 -j DROP
fi
# Persist (best-effort)
sudo bash -c 'iptables-save > /etc/iptables.scanner.rules' 2>/dev/null || true

# Raise file-descriptor limits for high-rate scanning
sudo bash -c 'cat > /etc/security/limits.d/99-scanner.conf' <<'EOF'
*    soft    nofile    1048576
*    hard    nofile    1048576
EOF

echo "[*] Versions:"
masscan --version | head -1 || true
"$HOME/go/bin/zgrab2" --help >/dev/null 2>&1 && echo "zgrab2 OK"
"$HOME/go/bin/zdns" --version 2>/dev/null || echo "zdns installed"
echo "[+] VM provisioning complete."
