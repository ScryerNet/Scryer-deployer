#!/usr/bin/env bash
# scan.sh — per-VM pipeline. Runs ON each VM. Discovers + fingerprints this VM's
# shard, then pushes its results into a clone of the INTEL repo (GitHub only).
# Shard index/total + GIT_REPO_URL + GITHUB_TOKEN come from env (set by deploy.sh
# or the bootstrap launch line). All tuning lives in config.env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scanner/config.env
export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"

SHARD_INDEX="${SHARD_INDEX:?set by deployer}"
SHARD_TOTAL="${SHARD_TOTAL:?set by deployer}"
: "${GIT_REPO_URL:?export GIT_REPO_URL = the INTEL repo}"
: "${GITHUB_TOKEN:?export GITHUB_TOKEN = fine-grained PAT, Contents:write}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Scratch dir is overridable so systemd can point it at a writable ReadWritePath
# while keeping /opt/netscan read-only. Defaults to the repo root for manual runs.
WORK_DIR="${WORK_DIR:-$PWD}"
RAW="${WORK_DIR}/raw/${STAMP}"
mkdir -p "$RAW"
# Under systemd we grant CAP_NET_RAW to the service, so masscan needs no sudo.
# Manual runs default to sudo. Override with MASSCAN_CMD=masscan.
MASSCAN_CMD="${MASSCAN_CMD:-sudo masscan}"
log() { echo "[$(date -u +%T)] $*"; }

# ---------------------------------------------------------------------------
# Prepare a local clone of the INTEL repo to push results into.
# ---------------------------------------------------------------------------
AUTH_URL="$(echo "${GIT_REPO_URL}" | sed -E "s#https://#https://x-access-token:${GITHUB_TOKEN}@#")"
SYNC_DIR="${SYNC_DIR:-$HOME/intel-sync}"
if [ ! -d "${SYNC_DIR}/.git" ]; then
    log "Cloning intel repo into ${SYNC_DIR}..."
    git clone --depth 1 --branch "${GIT_BRANCH}" "${AUTH_URL}" "${SYNC_DIR}" 2>/dev/null \
        || { mkdir -p "${SYNC_DIR}"; git -C "${SYNC_DIR}" init -q; \
             git -C "${SYNC_DIR}" remote add origin "${AUTH_URL}"; \
             git -C "${SYNC_DIR}" checkout -q -B "${GIT_BRANCH}"; }
fi
git -C "${SYNC_DIR}" config user.name  "${GIT_AUTHOR_NAME}"
git -C "${SYNC_DIR}" config user.email "${GIT_AUTHOR_EMAIL}"
git -C "${SYNC_DIR}" remote set-url origin "${AUTH_URL}" 2>/dev/null || true
DEST="${SYNC_DIR}/results/vm${SHARD_INDEX}"
mkdir -p "${DEST}/raw/${STAMP}"

# ---------------------------------------------------------------------------
# STAGE 1: masscan port discovery for this shard (--shards i/n = disjoint 1/n).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Auto-detect the public egress interface + next-hop MAC for masscan's raw
# stack. masscan needs an L2 next-hop MAC; on multi-NIC cloud VMs the default
# route often points at an internal NIC whose gateway won't ARP, so we PREFER
# the interface that holds a public (non-RFC1918) IP. Skipped if the operator
# already pinned --router-mac in MASSCAN_EXTRA or MASSCAN_CMD.
# ---------------------------------------------------------------------------
if [[ "${MASSCAN_EXTRA} ${MASSCAN_CMD}" != *"--router-mac"* ]]; then
    log "Auto-detecting scan interface and gateway MAC…"
    det_iface=""; det_src=""; det_gw=""; det_mac=""
    # 1. Prefer an interface bearing a public IPv4 address.
    for dev in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$'); do
        while read -r ip4; do
            case "$ip4" in
                10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|169.254.*|127.*|"") ;;
                *) det_iface="$dev"; det_src="$ip4"; break ;;
            esac
        done < <(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        [ -n "$det_iface" ] && break
    done
    # 2. Fallback: kernel's actual egress path to a public IP.
    if [ -z "$det_iface" ]; then
        read -r det_gw det_iface det_src < <(ip route get 1.1.1.1 2>/dev/null | \
            awk '{for(i=1;i<=NF;i++){if($i=="via")g=$(i+1);if($i=="dev")d=$(i+1);if($i=="src")s=$(i+1)}print g,d,s}')
    fi
    # 3. Gateway for the chosen interface.
    [ -z "$det_gw" ] && det_gw="$(ip route show default dev "$det_iface" 2>/dev/null | awk '/via/{print $3; exit}')"
    [ -z "$det_gw" ] && det_gw="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p')"
    # 4. Actively resolve the gateway MAC (force egress, then neighbor lookup).
    for _ in 1 2 3 4 5; do
        curl -s -o /dev/null --max-time 3 https://github.com 2>/dev/null || true
        det_mac="$(ip neigh get "$det_gw" dev "$det_iface" 2>/dev/null | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)"
        [ -n "$det_mac" ] && break
        sleep 1
    done
    if [ -n "$det_iface" ] && [ -n "$det_mac" ]; then
        MASSCAN_EXTRA="--interface ${det_iface} --router-mac ${det_mac}${det_src:+ --source-ip ${det_src}} ${MASSCAN_EXTRA}"
        log "  detected interface=${det_iface} gw=${det_gw} mac=${det_mac} src=${det_src}"
    else
        log "  WARN: auto-detect incomplete (iface=${det_iface:-?} gw=${det_gw:-?} mac=${det_mac:-?})."
        log "        Set MASSCAN_EXTRA in scanner/config.env manually if masscan can't send."
    fi
fi

log "Stage 1: masscan shard ${SHARD_INDEX}/${SHARD_TOTAL} @ ${MASSCAN_RATE}pps on ${PORTS}"
# masscan numbers shards 1-based (1/N..N/N); our SHARD_INDEX is 0-based (0..N-1).
MASSCAN_SHARD=$(( SHARD_INDEX + 1 ))
${MASSCAN_CMD} ${TARGETS} \
    -p"${PORTS}" \
    --shards "${MASSCAN_SHARD}"/"${SHARD_TOTAL}" \
    --rate "${MASSCAN_RATE}" \
    --source-port "${MASSCAN_SRC_PORTS%-*}" \
    --excludefile "${BLOCKLIST}" \
    ${MASSCAN_EXTRA} \
    --open-only \
    -oL "${RAW}/masscan.list"
awk '/^open/ {print $4","$3}' "${RAW}/masscan.list" | sort -u > "${RAW}/ip_port.csv"
awk '/^open/ {print $4}'       "${RAW}/masscan.list" | sort -u > "${RAW}/ips.txt"
HITS=$(wc -l < "${RAW}/ip_port.csv" | tr -d ' ')
log "Stage 1 done: ${HITS} open ip:port pairs."

# ---------------------------------------------------------------------------
# STAGE 2a: zgrab2 — TLS certs, SSH host-key fingerprints, HTTP banners.
# ---------------------------------------------------------------------------
if [ "${DO_ZGRAB2}" = "1" ] && [ "${HITS}" -gt 0 ]; then
    log "Stage 2a: zgrab2 over ${HITS} targets"
    zgrab2 --senders "${ZGRAB2_SENDERS}" \
           --input-file "${RAW}/ip_port.csv" \
           --output-file "${RAW}/zgrab2.ndjson" \
           multiple -c scanner/zgrab2.ini || log "zgrab2 non-zero (partial ok)"
fi

# ---------------------------------------------------------------------------
# STAGE 2b: JARM — active TLS server fingerprint on TLS ports.
# ---------------------------------------------------------------------------
if [ "${DO_JARM}" = "1" ] && [ "${HITS}" -gt 0 ]; then
    log "Stage 2b: JARM on TLS ports"
    awk -F, '$2 ~ /^(443|8443|465|993|995|990|2083|2087|8883)$/ {print $1":"$2}' \
        "${RAW}/ip_port.csv" > "${RAW}/tls_targets.txt" || true
    if [ -s "${RAW}/tls_targets.txt" ]; then
        if command -v jarm >/dev/null 2>&1; then
            jarm -i "${RAW}/tls_targets.txt" -o "${RAW}/jarm.json" 2>/dev/null \
              || while read -r t; do jarm "$t"; done < "${RAW}/tls_targets.txt" > "${RAW}/jarm.txt"
        else
            python3 -m jarm.scanner.scanner -i "${RAW}/tls_targets.txt" > "${RAW}/jarm.txt" || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# STAGE 3: zdns — reverse DNS (PTR) for every responsive host.
# ---------------------------------------------------------------------------
if [ "${DO_ZDNS}" = "1" ] && [ -s "${RAW}/ips.txt" ]; then
    log "Stage 3: zdns PTR lookups"
    zdns PTR --threads 1000 < "${RAW}/ips.txt" > "${RAW}/zdns_ptr.ndjson" 2>/dev/null \
        || log "zdns non-zero (partial ok)"
fi

# ---------------------------------------------------------------------------
# Compress, summarize, chunk under 100 MB, push to intel repo in <2 GB batches.
# ---------------------------------------------------------------------------
log "Summarizing..."
gzip -f "${RAW}"/*.ndjson "${RAW}"/*.list 2>/dev/null || true
python3 scanner/summarize.py --raw-dir "${RAW}" --shard "${SHARD_INDEX}/${SHARD_TOTAL}" \
    --stamp "${STAMP}" --out "${DEST}/shard${SHARD_INDEX}_${STAMP}.json"

log "Chunking raw under ${MAX_CHUNK_MB}MB..."
for f in "${RAW}"/*.gz; do
    [ -e "$f" ] || continue
    split -b "${MAX_CHUNK_MB}m" -d -a 3 "$f" "${DEST}/raw/${STAMP}/$(basename "$f").part"
done

cd "${SYNC_DIR}"
push_with_retry() {
    local tries=0
    until git push origin "HEAD:${GIT_BRANCH}"; do
        tries=$((tries+1)); [ $tries -ge 8 ] && { log "push failed after retries"; return 1; }
        log "push race/rewrite, re-syncing and retrying ($tries)..."
        git fetch origin "${GIT_BRANCH}" && git rebase "origin/${GIT_BRANCH}" \
            || { git rebase --abort 2>/dev/null || true; git reset --soft "origin/${GIT_BRANCH}" 2>/dev/null || true; }
        sleep $((RANDOM % 5 + 2))
    done
}

log "Pushing summary..."
git add "results/vm${SHARD_INDEX}/shard${SHARD_INDEX}_${STAMP}.json"
git commit -m "vm${SHARD_INDEX} summary ${STAMP}" >/dev/null 2>&1 || true
push_with_retry

log "Pushing raw chunks in batches of ${CHUNKS_PER_PUSH}..."
mapfile -t CHUNKS < <(find "results/vm${SHARD_INDEX}/raw/${STAMP}" -type f | sort)
i=0
while [ $i -lt ${#CHUNKS[@]} ]; do
    git add "${CHUNKS[@]:i:CHUNKS_PER_PUSH}"
    git commit -m "vm${SHARD_INDEX} raw ${STAMP} batch $((i/CHUNKS_PER_PUSH))" >/dev/null 2>&1 || true
    push_with_retry || break
    i=$((i+CHUNKS_PER_PUSH))
done
log "DONE. Synced to intel repo under results/vm${SHARD_INDEX}/ (summary + raw chunks)."
