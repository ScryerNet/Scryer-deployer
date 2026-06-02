# deployer-repo - distributed internet scanner (scanner + provisioning)

This is the **deployer**: the scanner code and provisioning that gets installed on
your Debian VMs. Results are pushed to a **separate intel-repo** (see its README).

Three VMs each scan one third of routable IPv4 with masscan, fingerprint services
with zgrab2 / JARM / zdns, and push results to the intel repo. Load is split with
masscan's native `--shards i/3` (disjoint, no overlap, no gaps).

## Install the scanner on a VM (one command)

```
read -rp "Intel repo URL: " REPO; \
read -rsp "Token for that repo: " GH; echo; \
read -rp "Shard index (0/1/2): " IDX; \
[ -n "$GH" ] && [ -n "$REPO" ] && \
export NS_REPO="$REPO" NS_GIT_TOKEN="$GH" NS_SHARD_INDEX="$IDX" \
       NS_SHARD_TOTAL=3 NS_NODE_NAME="$(hostname)" NS_NONINTERACTIVE=1 \
       NS_INSTALL_REPO="https://github.com/ScryerNet/Scryer-deployer.git" && \
curl -fsSL https://raw.githubusercontent.com/ScryerNet/Scryer-deployer/main/install.sh \
  | sudo -E bash; \
unset GH REPO IDX NS_REPO NS_GIT_TOKEN NS_SHARD_INDEX NS_SHARD_TOTAL NS_NODE_NAME NS_NONINTERACTIVE NS_INSTALL_REPO
```

Run this on each Debian VM (replace `<you>` / repo names):

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/deployer-repo/main/bootstrap.sh | bash
```

It clones this repo to `~/scanner-repo` and installs masscan, zgrab2, jarm, zdns.
Then launch that VM's shard (0, 1, or 2), pointing it at your intel repo:

```bash
cd ~/scanner-repo \
  && SHARD_INDEX=0 SHARD_TOTAL=3 \
     GIT_REPO_URL=https://github.com/<you>/intel-repo.git \
     GITHUB_TOKEN=github_pat_xxx \
     nohup bash scanner/scan.sh > ~/scan.log 2>&1 &
```

Or drive all three VMs from your laptop with `deployer/deploy.sh` (see below).

## Production install (systemd service + timer)

`bootstrap.sh` is the quick path. For a hardened, self-managing node use
`install.sh`, which sets up the scanner as a sandboxed, least-privilege systemd
service plus a timer that re-scans on a schedule and pushes results automatically:

```bash
sudo NS_NONINTERACTIVE=1 \
     NS_REPO=https://github.com/<you>/intel-repo.git \
     NS_GIT_TOKEN=github_pat_xxx \
     NS_SHARD_INDEX=0 NS_SHARD_TOTAL=3 \
     bash install.sh
```

It runs pre-flight checks, installs the toolchain system-wide, isolates the token in
a `0640 root:netscan` env file, and runs the scanner as the unprivileged `netscan`
user with only `CAP_NET_RAW` (no root) under `ProtectSystem=strict` sandboxing. The
service and units are named plainly (`netscan`) on purpose — an authorized scanner
should be attributable, not hidden. Remove everything with `sudo bash uninstall.sh`.
See `install.sh -h` for all `NS_*` options.

## How the load is split

You do **not** need a custom partitioner. masscan has built-in sharding: every VM
runs the identical command with a different `--shards i/3`, and masscan
deterministically (via a cyclic multiplicative group over the address space) gives
each VM a disjoint, evenly-interleaved third. No overlap, no gaps.

```
VM0:  masscan ... --shards 0/3
VM1:  masscan ... --shards 1/3
VM2:  masscan ... --shards 2/3
```

## Architecture

```
        GitHub (this repo)  ── deployer/ orchestrates ──┐
                                                         ▼
   ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
   │     VM0      │     │     VM1      │     │     VM2      │
   │ shard 0/3    │     │ shard 1/3    │     │ shard 2/3    │
   │ masscan→zgrab│     │ masscan→zgrab│     │ masscan→zgrab│
   │   →jarm→zdns │     │   →jarm→zdns │     │   →jarm→zdns │
   └──────┬───────┘     └──────┬───────┘     └──────┬───────┘
          │   compressed shard results (NDJSON.gz)  │
   └──────────────┬───────────────┬──────────┘
                  │  each VM git-pushes its own results/vm<i>/  │
                  ▼               ▼              ▼
        Central GitHub repo (single branch: main)
          results/vm0/  results/vm1/  results/vm2/
          ├─ shardN_<stamp>.json      (small summary)
          └─ raw/<stamp>/*.gz.partNNN (compressed raw, chunked <90MB)
                  │
                  ▼  on push, GitHub Action runs
          aggregator/aggregate.py → reports/latest.{json,md}
```

**Everything lives on GitHub.** Each VM commits its summary plus its compressed raw
output (split into <90 MB chunks to clear the 100 MB file limit) into its own
`results/vm<i>/` directory and pushes to `main`. Pushes are batched to stay under
the 2 GB per-push limit. Because each VM owns a separate directory, concurrent
pushes never conflict on content — only on the ref, which a fetch/rebase/retry loop
handles. Reassemble raw locally with `./deploy.sh reassemble`.

> Note: git keeps every pushed blob in history, so the repo grows with each scan and
> will eventually pass GitHub's ~5 GB soft cap. When that day comes your only
> in-GitHub options are squashing history or Git LFS; until then, plain git is fine.

## Quick start

1. Fork this repo. Put your three VMs in `deployer/inventory.yaml` (copy the example).
2. From your laptop: `cd deployer && ./deploy.sh provision`  (installs the toolchain)
3. Configure the scan in `scanner/config.env` (ports, rate, what to fingerprint).
4. Create a fine-grained PAT (Contents: Read and write on the repo) and export it:
   ```bash
   export GITHUB_TOKEN=github_pat_xxx
   export GIT_REPO_URL=https://github.com/<you>/<repo>.git
   ```
5. Launch: `./deploy.sh scan`   — each VM gets its shard index and pushes its own
   `results/vm<i>/` (summary + chunked raw) straight to `main`.
6. The GitHub Action in `.github/workflows/aggregate.yml` runs `aggregate.py` on each
   push → `reports/latest.{json,md}`.
7. To read raw later: pull the repo and run `./deploy.sh reassemble`.

## Speed vs. survival (read this)

masscan rate is set in `scanner/config.env` as `MASSCAN_RATE` (packets/sec).

| Rate (pps) | Full IPv4, one port, split 3 ways | Risk                          |
|------------|-----------------------------------|-------------------------------|
| 10,000     | ~1.7 days / VM                    | low                           |
| 50,000     | ~8 hours / VM                     | moderate — expect complaints  |
| 150,000+   | ~3 hours / VM                     | high — providers may suspend  |

"Really fast" and "doesn't get your account terminated" are in tension. Start at
25k–50k, watch your provider's reaction, scale up only if you own/authorized the
upstream. The default is 25,000.

## Responsible scanning (non-negotiable defaults — keep them)

These are not red tape; they are why ZMap/Censys can scan continuously without being
shut down, and in several jurisdictions they're what keeps high-volume scanning on the
right side of CFAA-style "unauthorized access" lines.

- `scanner/blocklist.conf` excludes reserved/private ranges **and** an opt-out list.
- Set PTR records for your three scanning IPs to a hostname that resolves to a page
  explaining the research and offering opt-out (`coordinator/scan-info-page.html`).
- Put a real **abuse@ / research contact** in `scanner/config.env` (`ABUSE_CONTACT`).
- Honor every opt-out request by adding the network to `blocklist.conf` immediately.
- Only scan what you're authorized to. "Authorized" for the whole internet is a real
  legal question — consult the rules for your provider and jurisdiction before a full
  sweep. Targeted scans of infrastructure you own/control need none of this debate.

See `coordinator/RESPONSIBLE_SCANNING.md` for the full checklist.
