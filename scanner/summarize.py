#!/usr/bin/env python3
"""summarize.py — turn one shard's raw NDJSON into a compact summary safe to commit.

We never commit raw banners/certs (too big). The summary holds counts + a small
sample, plus fingerprint tallies the aggregator merges across shards.
"""
import argparse, gzip, json, io, os, glob
from collections import Counter, defaultdict

def open_any(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)

def iter_ndjson(pattern):
    for p in glob.glob(pattern):
        try:
            with open_any(p) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        try: yield json.loads(line)
                        except json.JSONDecodeError: continue
        except OSError:
            continue

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", required=True)
    ap.add_argument("--shard", required=True)
    ap.add_argument("--stamp", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rd = a.raw_dir

    ports = Counter()
    services = Counter()
    tls_versions = Counter()
    cert_issuers = Counter()
    ssh_kex = Counter()
    ssh_hostkey_fp = Counter()
    jarm_fp = Counter()
    http_servers = Counter()
    open_hosts = set()
    sample = []

    # masscan list (ip,port pairs already extracted to ip_port.csv, but also count from list)
    ipport_csv = os.path.join(rd, "ip_port.csv")
    if os.path.exists(ipport_csv):
        with open(ipport_csv) as fh:
            for line in fh:
                ip, _, port = line.strip().partition(",")
                if ip:
                    open_hosts.add(ip)
                    ports[port] += 1

    # zgrab2 output: one object per host, keyed by module name under ["data"]
    for obj in iter_ndjson(os.path.join(rd, "zgrab2.ndjson*")):
        data = obj.get("data", {})
        ip = obj.get("ip") or obj.get("domain")
        for mod, res in data.items():
            status = (res or {}).get("status")
            if status == "success":
                services[mod] += 1
            r = (res or {}).get("result", {}) or {}
            # TLS
            tls = r.get("tls") or (r if mod.startswith("tls") else {})
            hs = (tls or {}).get("handshake_log", {}) if isinstance(tls, dict) else {}
            sv = hs.get("server_hello", {})
            if sv.get("version", {}).get("name"):
                tls_versions[sv["version"]["name"]] += 1
            for cert in (hs.get("server_certificates", {}) or {}).get("certificate", {}).get("parsed", {}).get("issuer", {}).get("organization", []) or []:
                cert_issuers[cert] += 1
            # SSH
            if mod == "ssh":
                kex = (r.get("server_id", {}) or {}).get("software")
                if kex: ssh_kex[kex] += 1
                fp = (r.get("server_host_key", {}) or {}).get("fingerprint_sha256")
                if fp: ssh_hostkey_fp[fp] += 1
            # HTTP
            if mod in ("http", "https"):
                srv = (((r.get("response", {}) or {}).get("headers", {}) or {}).get("server") or [None])
                if isinstance(srv, list) and srv and srv[0]:
                    http_servers[srv[0]] += 1
        if len(sample) < 50 and ip:
            sample.append({"ip": ip, "modules": list(data.keys())})

    # JARM
    jarm_txt = os.path.join(rd, "jarm.txt")
    if os.path.exists(jarm_txt):
        with open(jarm_txt) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and len(parts[-1]) >= 10:
                    jarm_fp[parts[-1]] += 1
    for obj in iter_ndjson(os.path.join(rd, "jarm.json*")):
        fp = obj.get("fingerprint") or obj.get("jarm")
        if fp: jarm_fp[fp] += 1

    # PTR (zdns)
    ptr_count = 0
    for obj in iter_ndjson(os.path.join(rd, "zdns_ptr.ndjson*")):
        if (obj.get("data") or {}).get("answers"):
            ptr_count += 1

    summary = {
        "shard": a.shard,
        "stamp": a.stamp,
        "open_hosts": len(open_hosts),
        "open_ports": sum(ports.values()),
        "ports": dict(ports.most_common()),
        "services": dict(services),
        "tls_versions": dict(tls_versions.most_common(20)),
        "cert_issuers_top": dict(cert_issuers.most_common(25)),
        "ssh_software_top": dict(ssh_kex.most_common(25)),
        "ssh_hostkey_unique": len(ssh_hostkey_fp),
        "jarm_fingerprints_top": dict(jarm_fp.most_common(25)),
        "http_servers_top": dict(http_servers.most_common(25)),
        "ptr_resolved": ptr_count,
        "sample": sample,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as fh:
        json.dump(summary, fh, indent=2)
    print(f"wrote {a.out}: {summary['open_hosts']} hosts, {summary['open_ports']} ports")

if __name__ == "__main__":
    main()
