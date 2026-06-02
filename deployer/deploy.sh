#!/usr/bin/env bash
# deploy.sh — orchestrate provisioning and scanning across the VM fleet from your laptop.
#
#   ./deploy.sh provision        # install toolchain on every VM
#   ./deploy.sh scan             # launch the sharded scan on every VM
#   ./deploy.sh status           # check scan progress
#   ./deploy.sh collect          # pull summaries back and git-commit them
#
# VMs and their shard index come from inventory.yaml.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
INVENTORY="${INVENTORY:-$HERE/inventory.yaml}"

if [ ! -f "$INVENTORY" ]; then
    echo "No inventory. Copy inventory.example.yaml to inventory.yaml and edit it." >&2
    exit 1
fi

# Minimal YAML reader (expects the simple structure in inventory.example.yaml).
# Emits lines: index<TAB>user<TAB>host
parse_inventory() {
    python3 - "$INVENTORY" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1]))
for i, vm in enumerate(inv["vms"]):
    print(f'{i}\t{vm["user"]}\t{vm["host"]}')
PY
}

TOTAL_SHARDS=$(parse_inventory | wc -l | tr -d ' ')

remote() { # remote <user> <host> <command...>
    local user="$1" host="$2"; shift 2
    ssh -o StrictHostKeyChecking=accept-new "${user}@${host}" "$@"
}

cmd_provision() {
    while IFS=$'\t' read -r idx user host; do
        echo "=== [VM$idx] provisioning $user@$host ==="
        rsync -az --delete \
            --exclude '.git' --exclude 'results' --exclude 'raw' \
            "$REPO_ROOT/" "${user}@${host}:~/scanner-repo/"
        remote "$user" "$host" "bash ~/scanner-repo/deployer/setup-vm.sh"
    done < <(parse_inventory)
}

cmd_scan() {
    : "${GITHUB_TOKEN:?export GITHUB_TOKEN (fine-grained PAT, Contents:write) first}"
    : "${GIT_REPO_URL:?export GIT_REPO_URL=https://github.com/<you>/<repo>.git first}"
    while IFS=$'\t' read -r idx user host; do
        echo "=== [VM$idx] launching shard ${idx}/${TOTAL_SHARDS} on $user@$host ==="
        rsync -az --exclude '.git' --exclude 'results' --exclude 'raw' \
            "$REPO_ROOT/" "${user}@${host}:~/scanner-repo/"
        # Detached run; logs to scan.log. Each VM pushes its own results to GitHub.
        remote "$user" "$host" \
            "cd ~/scanner-repo && \
             SHARD_INDEX=$idx SHARD_TOTAL=$TOTAL_SHARDS \
             GIT_REPO_URL='$GIT_REPO_URL' GITHUB_TOKEN='$GITHUB_TOKEN' \
             nohup bash scanner/scan.sh > ~/scan.log 2>&1 & echo started pid \$!"
    done < <(parse_inventory)
    echo "All shards launched. They push to GitHub themselves; './deploy.sh status' to monitor."
}

cmd_status() {
    while IFS=$'\t' read -r idx user host; do
        echo "=== [VM$idx] $user@$host ==="
        remote "$user" "$host" "tail -n 5 ~/scan.log 2>/dev/null || echo 'no log yet'"
    done < <(parse_inventory)
}

cmd_reassemble() {
    # Raw is stored as .gz.partNNN chunks under results/vm*/raw/. Rebuild the
    # original .gz files locally after pulling the repo.
    echo "Reassembling chunked raw files in $REPO_ROOT/results ..."
    find "$REPO_ROOT/results" -name '*.gz.part000' | while read -r first; do
        out="${first%.part000}"
        cat "${out}.part"* > "$out" && rm -f "${out}.part"*
        echo "  -> $out"
    done
    echo "Done. gunzip the .gz files to read NDJSON."
}

case "${1:-}" in
    provision)  cmd_provision ;;
    scan)       cmd_scan ;;
    status)     cmd_status ;;
    reassemble) cmd_reassemble ;;
    *) echo "usage: $0 {provision|scan|status|reassemble}"; exit 1 ;;
esac
