#!/usr/bin/env bash
# =============================================================================
#  netscan deployer — scanner node installer
# -----------------------------------------------------------------------------
#  Installs the distributed internet scanner on one Debian/Ubuntu VM as a
#  least-privilege systemd service + periodic timer. The node scans its shard
#  (1/N of routable IPv4) and pushes results to the intel repo.
#
#  Naming is deliberately clear and honest ("netscan"): a scanning operation
#  stays lawful by being attributable (PTR records, abuse contact, info page),
#  so this installer does NOT disguise itself or hide the admin SSH port.
#
#  Usage (local checkout):
#      sudo ./install.sh
#
#  Usage (remote, public repo):
#      curl -fsSL https://raw.githubusercontent.com/<you>/deployer-repo/main/install.sh \
#        | sudo NS_NONINTERACTIVE=1 NS_REPO=... NS_GIT_TOKEN=ghp_xxx NS_SHARD_INDEX=0 bash
#
#  Environment variables:
#      NS_REPO            git URL of the INTEL repo this node pushes to (required)
#      NS_GIT_TOKEN       fine-grained PAT, Contents: r/w on the intel repo (required)
#      NS_SHARD_INDEX     this node's shard, 0-based                 (required)
#      NS_SHARD_TOTAL     number of shards in the fleet              (default 3)
#      NS_INSTALL_REPO    deployer repo URL (for remote source fetch)
#      NS_INSTALL_TOKEN   PAT for the deployer repo if private (falls back to NS_GIT_TOKEN)
#      NS_NODE_NAME       free-form node label                       (default: hostname)
#      NS_ON_CALENDAR     systemd OnCalendar for periodic re-scan    (default: daily)
#      NS_NONINTERACTIVE  1 to disable prompts
# =============================================================================
set -Eeuo pipefail

case "${1:-}" in
  -h|--help)
    sed -n '/^# =====.*=====$/,/^# =====.*=====$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

# -----------------------------------------------------------------------------
# 0. Logging + error handling (set up first so everything is captured)
# -----------------------------------------------------------------------------
INSTALL_TS=$(date -u +%Y%m%d-%H%M%S)
INSTALL_LOG="/var/log/netscan-install-${INSTALL_TS}.log"
if ! mkdir -p /var/log 2>/dev/null || ! touch "$INSTALL_LOG" 2>/dev/null; then
  INSTALL_LOG="/tmp/netscan-install-${INSTALL_TS}.log"; touch "$INSTALL_LOG"
fi
chmod 0600 "$INSTALL_LOG" 2>/dev/null || true
exec > >(tee -a "$INSTALL_LOG") 2>&1

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;34m'; C_N='\033[0m'
_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log()  { echo -e "$(_ts) ${C_B}[*]${C_N} $*"; }
ok()   { echo -e "$(_ts) ${C_G}[+]${C_N} $*"; }
warn() { echo -e "$(_ts) ${C_Y}[!]${C_N} $*"; }
err()  { echo -e "$(_ts) ${C_R}[x]${C_N} $*" >&2; }
die()  { err "$*"; exit 1; }

declare -a INSTALLED_UNITS=() CREATED_DIRS=()
on_error() {
  local lineno="$1" rc="$2" cmd="$3"
  trap '' ERR; set +eE; set +o pipefail
  err "----------------------------------------------------------------"
  err "Install failed at line ${lineno}: '${cmd}' (exit ${rc})"
  err "Log: ${INSTALL_LOG}"
  tail -n 15 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
  if (( ${#INSTALLED_UNITS[@]} > 0 )); then
    err "Partial install performed. Clean up with:  sudo bash uninstall.sh"
  fi
  exit "${rc:-1}"
}
trap 'on_error "${LINENO}" "$?" "${BASH_COMMAND}"' ERR

log "netscan installer starting (log: $INSTALL_LOG)"

# -----------------------------------------------------------------------------
# 1. Pre-flight
# -----------------------------------------------------------------------------
log "Pre-flight checks…"
[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."
[[ -f /etc/debian_version ]] || die "Debian/Ubuntu required. Found: $(uname -a)"
KERNEL_VER=$(uname -r | cut -d. -f1); (( KERNEL_VER >= 4 )) || die "Kernel >= 4.0 required"
RAM_MB=$(free -m | awk '/^Mem:/{print $2}'); (( RAM_MB >= 512 )) || die "Need >= 512MB RAM (found ${RAM_MB})"
DISK_MB=$(df -Pm / | awk 'NR==2{print $4}'); (( DISK_MB >= 2048 )) || die "Need >= 2GB free on / (found ${DISK_MB})"
for t in curl git awk sed grep shuf; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
ok "Pre-flight passed (kernel $(uname -r), ${RAM_MB}MB RAM, ${DISK_MB}MB disk)"

# -----------------------------------------------------------------------------
# 2. Env parsing
# -----------------------------------------------------------------------------
NS_REPO="${NS_REPO:-}"
NS_GIT_TOKEN="${NS_GIT_TOKEN:-}"
NS_SHARD_INDEX="${NS_SHARD_INDEX:-}"
NS_SHARD_TOTAL="${NS_SHARD_TOTAL:-3}"
NS_NODE_NAME="${NS_NODE_NAME:-$(hostname)}"
NS_ON_CALENDAR="${NS_ON_CALENDAR:-daily}"
NS_INSTALL_REPO="${NS_INSTALL_REPO:-https://github.com/CHANGE_ME/deployer-repo.git}"
NS_INSTALL_TOKEN="${NS_INSTALL_TOKEN:-$NS_GIT_TOKEN}"

prompt() { local v; [[ "${NS_NONINTERACTIVE:-0}" == "1" ]] && die "$1 is required"; read -rp "$2" v; echo "$v"; }
[[ -n "$NS_REPO" ]]        || NS_REPO=$(prompt NS_REPO "Intel repo URL (https://github.com/<you>/intel-repo.git): ")
[[ -n "$NS_GIT_TOKEN" ]]   || { [[ "${NS_NONINTERACTIVE:-0}" == "1" ]] && die "NS_GIT_TOKEN required"; read -rsp "Fine-grained PAT (Contents r/w): " NS_GIT_TOKEN; echo; }
[[ -n "$NS_SHARD_INDEX" ]] || NS_SHARD_INDEX=$(prompt NS_SHARD_INDEX "This node's shard index (0..$((NS_SHARD_TOTAL-1))): ")

[[ "$NS_REPO" =~ ^https://github\.com/.+\.git$ ]] || warn "Repo URL doesn't look like an https git URL: $NS_REPO"
[[ "$NS_SHARD_INDEX" =~ ^[0-9]+$ ]] || die "NS_SHARD_INDEX must be an integer"
(( NS_SHARD_INDEX < NS_SHARD_TOTAL )) || die "NS_SHARD_INDEX ($NS_SHARD_INDEX) must be < NS_SHARD_TOTAL ($NS_SHARD_TOTAL)"
[[ -n "$NS_GIT_TOKEN" ]] || die "token empty"

# -----------------------------------------------------------------------------
# 3. Paths and names (clear, non-disguised)
# -----------------------------------------------------------------------------
SVC=netscan
SVC_USER=netscan
SVC_GROUP=netscan
INSTALL_ROOT=/opt/netscan
DATA_DIR=/var/lib/netscan
ETC_DIR=/etc/netscan
WORK_DIR="$DATA_DIR/work"
SYNC_DIR="$DATA_DIR/intel-sync"

# Detect local checkout vs remote fetch
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
LOCAL_SRC=""
[[ -n "${SCRIPT_PATH:-}" && -f "$SCRIPT_DIR/scanner/scan.sh" ]] && LOCAL_SRC="$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# 4. Connectivity + token validation
# -----------------------------------------------------------------------------
log "Checking GitHub connectivity…"
curl -fsS --connect-timeout 10 --max-time 15 -o /dev/null https://github.com 2>/dev/null \
  || die "Cannot reach https://github.com"
API_URL=$(echo "$NS_REPO" | sed -E 's|^https://github\.com/([^/]+)/([^/]+)\.git$|https://api.github.com/repos/\1/\2|')
if curl -fsS --connect-timeout 10 --max-time 30 -H "Authorization: token ${NS_GIT_TOKEN}" -o /dev/null "$API_URL" 2>/dev/null; then
  ok "Intel repo reachable with provided token"
else
  warn "Could not validate $NS_REPO via API — push may fail later."
fi

cat <<EOF

------------------------------------------------------------------------
  Node label    : $NS_NODE_NAME
  Shard         : $NS_SHARD_INDEX / $NS_SHARD_TOTAL
  Intel repo    : $NS_REPO
  Install source: ${LOCAL_SRC:-$NS_INSTALL_REPO (remote)}
  Install root  : $INSTALL_ROOT
  Re-scan timer : OnCalendar=$NS_ON_CALENDAR
  Install log   : $INSTALL_LOG
------------------------------------------------------------------------

EOF

# -----------------------------------------------------------------------------
# 5. APT packages (with retries)
# -----------------------------------------------------------------------------
log "Installing system packages…"
export DEBIAN_FRONTEND=noninteractive
_apt() { local n=0; while (( n<3 )); do apt-get "$@" && return 0; n=$((n+1)); warn "apt $1 retry $n/3"; sleep 5; done; return 1; }
_apt update -qq
_apt install -yqq masscan git curl jq iptables ca-certificates \
                  build-essential libpcap-dev clang gcc make python3
ok "System packages installed"

# -----------------------------------------------------------------------------
# 6. Go toolchain → /usr/local/bin (system-wide so the service user can run it)
# -----------------------------------------------------------------------------
GO_VERSION="1.22.5"
if ! command -v go >/dev/null 2>&1; then
  log "Installing Go ${GO_VERSION}…"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH="$PATH:/usr/local/go/bin"
log "Building zgrab2 / zdns / jarm into /usr/local/bin…"
GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install github.com/zmap/zgrab2/cmd/zgrab2@latest
GOBIN=/usr/local/bin go install github.com/zmap/zdns/cmd/zdns@latest
GOBIN=/usr/local/bin go install github.com/RumbleDiscovery/jarm-go/cmd/jarm@latest 2>/dev/null \
  || warn "jarm-go build failed; JARM stage will be skipped unless installed manually"
ok "Scanner toolchain installed: $(command -v masscan), zgrab2, zdns"

# -----------------------------------------------------------------------------
# 7. Stage source (local checkout preferred, else clone)
# -----------------------------------------------------------------------------
log "Staging scanner source…"
STAGING=$(mktemp -d -t netscan-stage.XXXXXX); CREATED_DIRS+=("$STAGING")
trap 'rm -rf "$STAGING"' EXIT
if [[ -n "$LOCAL_SRC" ]]; then
  cp -r "$LOCAL_SRC/scanner" "$LOCAL_SRC/coordinator" "$STAGING/"
else
  AUTH=$(echo "$NS_INSTALL_REPO" | sed "s|https://|https://x-access-token:${NS_INSTALL_TOKEN}@|")
  for a in 1 2 3; do git clone --depth 1 -q "$AUTH" "$STAGING/_repo" && break; warn "clone retry $a/3"; sleep 3; (( a==3 )) && die "clone failed"; done
  cp -r "$STAGING/_repo/scanner" "$STAGING/_repo/coordinator" "$STAGING/"; rm -rf "$STAGING/_repo"
fi
for f in scanner/scan.sh scanner/summarize.py scanner/config.env scanner/zgrab2.ini scanner/blocklist.conf; do
  [[ -f "$STAGING/$f" ]] || die "staged source missing $f"
done
ok "Source staged"

# -----------------------------------------------------------------------------
# 8. Least-privilege user, group, directories
# -----------------------------------------------------------------------------
log "Creating service account and directories…"
getent group "$SVC_GROUP" >/dev/null || groupadd --system "$SVC_GROUP"
id "$SVC_USER" &>/dev/null || useradd --system --no-create-home --home "$DATA_DIR" \
    --shell /usr/sbin/nologin --gid "$SVC_GROUP" "$SVC_USER"

for d in "$INSTALL_ROOT" "$DATA_DIR" "$ETC_DIR" "$WORK_DIR" "$SYNC_DIR"; do mkdir -p "$d"; CREATED_DIRS+=("$d"); done

rm -rf "$INSTALL_ROOT/scanner" "$INSTALL_ROOT/coordinator"
cp -r "$STAGING/scanner" "$STAGING/coordinator" "$INSTALL_ROOT/"
chown -R root:root "$INSTALL_ROOT"; chmod -R 0755 "$INSTALL_ROOT"      # read-only to the service
chown -R "$SVC_USER":"$SVC_GROUP" "$DATA_DIR"; chmod 0750 "$DATA_DIR"  # service-writable scratch + clone
ok "Installed to $INSTALL_ROOT (read-only), data in $DATA_DIR"

# -----------------------------------------------------------------------------
# 9. Config + secret (token isolated in 0640 root:netscan EnvironmentFile)
# -----------------------------------------------------------------------------
cat > "$ETC_DIR/env" <<EOF
# Drives scanner/scan.sh under systemd. Token lives here; keep mode 0640 root:netscan.
SHARD_INDEX=$NS_SHARD_INDEX
SHARD_TOTAL=$NS_SHARD_TOTAL
GIT_REPO_URL=$NS_REPO
GITHUB_TOKEN=$NS_GIT_TOKEN
NODE_NAME=$NS_NODE_NAME
WORK_DIR=$WORK_DIR
SYNC_DIR=$SYNC_DIR
MASSCAN_CMD=masscan
EOF
chown root:"$SVC_GROUP" "$ETC_DIR/env"; chmod 0640 "$ETC_DIR/env"
ok "Wrote $ETC_DIR/env (token isolated)"

# -----------------------------------------------------------------------------
# 10. systemd unit + timer (least privilege, sandboxed; CAP_NET_RAW for masscan)
# -----------------------------------------------------------------------------
log "Writing systemd units…"
_write_unit() { local p="$1"; cat > "$p"; ok "  wrote $p"; }

_write_unit "/etc/systemd/system/${SVC}.service" <<EOF
[Unit]
Description=Distributed internet scanner (shard ${NS_SHARD_INDEX}/${NS_SHARD_TOTAL})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SVC_USER
Group=$SVC_GROUP
EnvironmentFile=$ETC_DIR/env
WorkingDirectory=$INSTALL_ROOT
ExecStart=/bin/bash $INSTALL_ROOT/scanner/scan.sh
TimeoutStartSec=0

# masscan needs raw sockets — grant the capability instead of running as root
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN

# Sandboxing
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateTmp=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
ReadOnlyPaths=$INSTALL_ROOT
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

_write_unit "/etc/systemd/system/${SVC}.timer" <<EOF
[Unit]
Description=Periodic internet scan (shard ${NS_SHARD_INDEX}/${NS_SHARD_TOTAL})

[Timer]
OnCalendar=$NS_ON_CALENDAR
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# -----------------------------------------------------------------------------
# 11. Enable timer; optionally kick one scan now
# -----------------------------------------------------------------------------
systemctl enable --now "${SVC}.timer"
INSTALLED_UNITS+=("${SVC}.timer")
ok "${SVC}.timer enabled (OnCalendar=$NS_ON_CALENDAR)"

if [[ "${NS_NONINTERACTIVE:-0}" != "1" ]]; then
  read -rp "Run an initial scan now? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] && { log "Starting initial scan (runs in background)…"; systemctl start "${SVC}.service" --no-block; }
fi

# -----------------------------------------------------------------------------
# 12. Operator info + summary
# -----------------------------------------------------------------------------
cat > /root/.netscan-info <<EOF
node_name=$NS_NODE_NAME
shard=$NS_SHARD_INDEX/$NS_SHARD_TOTAL
intel_repo=$NS_REPO
install_root=$INSTALL_ROOT
installed_at=$(date -u +%FT%TZ)
install_log=$INSTALL_LOG
EOF
chmod 0600 /root/.netscan-info

cat <<EOF

========================================================================
  Install complete.

  Node     : $NS_NODE_NAME   shard $NS_SHARD_INDEX/$NS_SHARD_TOTAL
  Intel    : $NS_REPO
  Units    : ${SVC}.service  ${SVC}.timer

  Operator commands:
    run now : systemctl start ${SVC}.service
    status  : systemctl status ${SVC}.service ${SVC}.timer
    logs    : journalctl -u ${SVC}.service -f
    config  : $ETC_DIR/env   (ports/rate in $INSTALL_ROOT/scanner/config.env)
    info    : cat /root/.netscan-info
    remove  : sudo bash uninstall.sh

  Reminder: set PTR + abuse contact for this VM (coordinator/RESPONSIBLE_SCANNING.md).
========================================================================
EOF
ok "Done."
exit 0
