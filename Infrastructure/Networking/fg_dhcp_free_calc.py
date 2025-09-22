#!/usr/bin/env python3
import sys, re, ipaddress
from datetime import datetime
from typing import Optional, Dict, Tuple

# ---------------- CLI flags ----------------
DEBUG = False
CSV = False
paths = []
for a in sys.argv[1:]:
    if a == "--debug":
        DEBUG = True
    elif a == "--csv":
        CSV = True
    else:
        paths.append(a)

# ---------------- helpers ----------------
def norm_name(s: Optional[str]) -> str:
    """Strip quotes/whitespace and lowercase the scope/server/interface name."""
    if not s: return ""
    s = s.strip()
    if len(s) >= 2 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'")):
        s = s[1:-1]
    return s.strip().lower()

def parse_dt(s: str) -> Optional[datetime]:
    """Parse FortiGate lease-list expiry like 'Mon Sep 29 11:05:03 2025'."""
    s = s.strip()
    try:
        return datetime.strptime(s, "%a %b %d %H:%M:%S %Y")
    except Exception:
        return None

def read_all_text() -> str:
    if paths:
        with open(paths[0], "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    else:
        return sys.stdin.read()

# ---------------- parse ----------------
text = read_all_text()

# Accumulators
pools: Dict[str, int] = {}    # scope -> total addresses
used:  Dict[str, int] = {}    # scope -> used count
exp_min: Dict[str, datetime] = {}  # scope -> earliest expiry
exp_max: Dict[str, datetime] = {}  # scope -> latest expiry

# 1) Prefer "diagnose ip dhcp server statistics" if present (quick totals/used)
stats_blocks = re.split(r"\n(?=DHCP server:\s+\S+)", text)
for b in stats_blocks:
    m_iface = re.search(r"DHCP server:\s+(\S+)", b)
    m_tot   = re.search(r"Total addresses:\s+(\d+)", b)
    m_used  = re.search(r"Leases in use:\s+(\d+)", b)
    if m_iface and m_tot:
        name = norm_name(m_iface.group(1))
        pools[name] = int(m_tot.group(1))
        if m_used:
            used[name] = int(m_used.group(1))
        if DEBUG:
            print(f"[stats] scope={name} total={pools[name]} used={used.get(name,0)}", file=sys.stderr)

# 2) If we didn’t get totals yet, parse "show system dhcp server"
if not pools:
    servers = []  # list of {"iface": str, "ranges": [(start,end),...], "_pending": {}}
    current = None
    for line in text.splitlines():
        s = line.strip()
        if re.match(r"^edit\s+\d+\s*$", s):
            if current:
                servers.append(current)
            current = {"iface": None, "ranges": [], "_pending": {}}
            continue
        if current is None:
            continue

        # set interface "lan"
        m_iface = re.match(r'^set\s+interface\s+(.+)$', s)
        if m_iface:
            current["iface"] = norm_name(m_iface.group(1))
            continue

        # Single range: set ip-range A.B.C.D W.X.Y.Z
        m_range = re.match(r"^set\s+ip-range\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)$", s)
        if m_range:
            current["ranges"].append((m_range.group(1), m_range.group(2)))
            continue

        # Multi-range style with start-ip / end-ip inside config ip-range
        m_start = re.match(r"^set\s+start-ip\s+(\d+\.\d+\.\d+\.\d+)$", s)
        if m_start:
            current["_pending"]["start"] = m_start.group(1)
            continue
        m_end = re.match(r"^set\s+end-ip\s+(\d+\.\d+\.\d+\.\d+)$", s)
        if m_end:
            current["_pending"]["end"] = m_end.group(1)
            continue

        if s == "next":
            p = current.get("_pending", {})
            if "start" in p and "end" in p:
                current["ranges"].append((p["start"], p["end"]))
            current["_pending"] = {}

    if current:
        servers.append(current)

    # Sum ranges per interface name
    for sv in servers:
        iface = sv.get("iface")
        if not iface: continue
        total = 0
        for a, b in sv["ranges"]:
            try:
                ai = int(ipaddress.IPv4Address(a))
                bi = int(ipaddress.IPv4Address(b))
                if bi >= ai:
                    total += (bi - ai + 1)
            except Exception:
                pass
        pools[iface] = pools.get(iface, 0) + total
        if DEBUG:
            print(f"[pool] scope={iface} total={pools[iface]}", file=sys.stderr)

# 3) Parse leases + expirations from "exec dhcp lease-list"
# Block headers are scope names (e.g., lan, VOICE, snow), followed by a table whose
# data lines start with an IPv4 address. The expiry timestamp is at the end of the line.
current_scope = None
expiry_re = re.compile(r'([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s*$')
for raw in text.splitlines():
    s = raw.strip()

    # Scope header line: one token, not an IP, not column header "IP"
    if re.match(r"^[A-Za-z0-9._-]+$", s) and not re.match(r"^\d+\.\d+\.\d+\.\d+$", s) and s.lower() != "ip":
        current_scope = norm_name(s)
        used.setdefault(current_scope, 0)
        continue

    # Lease rows start with an IPv4 address
    if current_scope and re.match(r"^\s*\d+\.\d+\.\d+\.\d+\s", raw):
        used[current_scope] = used.get(current_scope, 0) + 1
        mexp = expiry_re.search(raw)
        if mexp:
            dt = parse_dt(mexp.group(1))
            if dt:
                if current_scope not in exp_min or dt < exp_min[current_scope]:
                    exp_min[current_scope] = dt
                if current_scope not in exp_max or dt > exp_max[current_scope]:
                    exp_max[current_scope] = dt

# Fallback: very old "get system dhcp lease" format (key off interface/ifname)
for line in text.splitlines():
    if re.search(r"\bip:\s*\d+\.\d+\.\d+\.\d+", line):
        m_if = re.search(r"(?:interface|ifname):\s*(\S+)", line)
        if m_if:
            name = norm_name(m_if.group(1))
            used[name] = used.get(name, 0) + 1

# ---------------- output ----------------
def fmt_dt(d: Optional[datetime]) -> str:
    return d.strftime("%a %b %d %H:%M:%S %Y") if d else "-"

scopes = sorted(set(pools.keys()) | set(used.keys()))
if CSV:
    print("Scope,%Free,Used,Total,Available,SoonestExpiry,LatestExpiry")
    for name in scopes:
        total = pools.get(name, 0)
        u = used.get(name, 0)
        avail = total - u if total else 0
        pct = (100.0 * avail / total) if total else None
        pct_str = f"{pct:.1f}" if pct is not None else ""
        print(f"{name},{pct_str},{u},{total},{avail},{fmt_dt(exp_min.get(name))},{fmt_dt(exp_max.get(name))}")
else:
    print("Scope            | % Free | Used/Total | Available | Soonest Expiry           | Latest Expiry")
    print("-----------------------------------------------------------------------------------------------")
    for name in scopes:
        total = pools.get(name, 0)
        u = used.get(name, 0)
        avail = total - u if total else 0
        pct_str = f"{(100.0 * avail / total):6.1f}%" if total else "  n/a  "
        print(f"{name:16} {pct_str}  {u}/{total:<9} {avail:<9} {fmt_dt(exp_min.get(name)):23} | {fmt_dt(exp_max.get(name))}")

if DEBUG:
    # Quick visibility into what we matched
    print("\n[debug] pools:", pools, file=sys.stderr)
    print("[debug] used:", used, file=sys.stderr)
    print("[debug] exp_min:", {k: fmt_dt(v) for k,v in exp_min.items()}, file=sys.stderr)
    print("[debug] exp_max:", {k: fmt_dt(v) for k,v in exp_max.items()}, file=sys.stderr)