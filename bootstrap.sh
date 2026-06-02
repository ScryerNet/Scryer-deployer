#!/usr/bin/env bash
# bootstrap.sh — fetch the deployer repo and install the scanner toolchain ON a VM.
#
# Run this directly on each Debian VM:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<deployer-repo>/main/bootstrap.sh | bash
#
# Or pin the repo explicitly:
#   DEPLOYER_REPO=https://github.com/<you>/<deployer-repo>.git \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/<deployer-repo>/main/bootstrap.sh)"
set -euo pipefail

DEPLOYER_REPO="${DEPLOYER_REPO:-https://github.com/ScryerNet/Scryer-deployer.git}"
DEST="${DEST:-$HOME/scanner-repo}"

echo "[*] Installing git..."
sudo apt-get update -y && sudo apt-get install -y git

if [ -d "${DEST}/.git" ]; then
    echo "[*] Updating existing checkout in ${DEST}..."
    git -C "${DEST}" pull --ff-only
else
    echo "[*] Cloning ${DEPLOYER_REPO} -> ${DEST}..."
    git clone "${DEPLOYER_REPO}" "${DEST}"
fi

echo "[*] Running toolchain install (masscan, zgrab2, jarm, zdns)..."
bash "${DEST}/deployer/setup-vm.sh"

cat <<EOF

[+] Scanner installed on this VM.

Launch this VM's shard (it will push results to your INTEL repo):

  cd ${DEST} \\
    && SHARD_INDEX=0 SHARD_TOTAL=3 \\
       GIT_REPO_URL=https://github.com/<you>/<intel-repo>.git \\
       GITHUB_TOKEN=github_pat_xxx \\
       nohup bash scanner/scan.sh > ~/scan.log 2>&1 &

Use SHARD_INDEX=0 / 1 / 2 on your three VMs respectively.
Or drive all three from your laptop with deployer/deploy.sh.
EOF
