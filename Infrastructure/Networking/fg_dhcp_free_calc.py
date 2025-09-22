#!/usr/bin/env python3
import sys, re, ipaddress

text = sys.stdin.read()

# --------------------------
# 1) Prefer "diagnose ... statistics" if present
# --------------------------
pools = {}  # iface/server -> total addresses
used  = {}  # iface/server -> used leases

blocks = re.split(r"\n(?=DHCP server:\s+\S+)", text)
found_stats = False
for b in blocks:
    m_iface = re.search(r"DHCP server:\s+(\S+)", b)
    m_tot   = re.search(r"Total addresses:\s+(\d+)", b)
    m_used  = re.search(r"Leases in use:\s+(\d+)", b)
    if m_iface and m_tot:
        found_stats = True
        iface = m_iface.group(1)
        pools[iface] = int(m_tot.group(1))
        if m_used:
            used[iface] = int(m_used.group(1))

# --------------------------
# 2) If no stats, parse pools from "show system dhcp server"
# --------------------------
if not pools:
    servers = []  # [{iface:str, ranges:[(start,end),...]}]
    current = None
    for line in text.splitlines():
        s = line.strip()
        if re.match(r"^edit\s+\d+", s):
            if current:
                servers.append(current)
            current = {"iface": None, "ranges": [], "_pending": {}}
        elif current is not None:
            m_iface = re.match(r"set\s+interface\s+(\S+)", s)
            if m_iface:
                current["iface"] = m_iface.group(1)
                continue
            m_range = re.match(r"set\s+ip-range\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)", s)
            if m_range:
                current["ranges"].append((m_range.group(1), m_range.group(2)))
                continue
            m_start = re.match(r"set\s+start-ip\s+(\d+\.\d+\.\d+\.\d+)", s)
            if m_start:
                current["_pending"]["start"] = m_start.group(1); continue
            m_end = re.match(r"set\s+end-ip\s+(\d+\.\d+\.\d+\.\d+)", s)
            if m_end:
                current["_pending"]["end"] = m_end.group(1); continue
            if s == "next":
                p = current.get("_pending", {})
                if "start" in p and "end" in p:
                    current["ranges"].append((p["start"], p["end"]))
                current["_pending"] = {}
    if current:
        servers.append(current)

    for s in servers:
        iface = s.get("iface")
        if not iface: continue
        total = 0
        for a,b in s["ranges"]:
            try:
                ai = int(ipaddress.IPv4Address(a))
                bi = int(ipaddress.IPv4Address(b))
                if bi >= ai:
                    total += (bi - ai + 1)
            except Exception:
                pass
        pools[iface] = pools.get(iface, 0) + total

# --------------------------
# 3) Parse used leases from either "lease-list" (preferred here) or older "get system dhcp lease"
# --------------------------
# Format we saw:
# <SERVER-NAME>
#   IP            MAC-Address   ...   SERVER-ID   Expiry
#   192.168.x.x   aa:bb:...     ...   <id>        <date>
current_server = None
for line in text.splitlines():
    raw = line.rstrip("\n")
    s = raw.strip()
    # Section header (server name): a single token line like "lan", "snow", "bitxbit"
    if re.match(r"^[A-Za-z0-9._-]+$", s) and not re.match(r"^\d+\.\d+\.\d+\.\d+$", s):
        # Avoid matching column header "IP" line
        if s.lower() != "ip":
            current_server = s
            used.setdefault(current_server, 0)
        continue
    # Rows that start with an IPv4 address count as 1 lease under current_server
    if current_server and re.match(r"^\s*\d+\.\d+\.\d+\.\d+\s", raw):
        used[current_server] = used.get(current_server, 0) + 1

# Fallback for older "get system dhcp lease" style (interface: <name> ...)
for line in text.splitlines():
    if re.search(r"\bip:\s*\d+\.\d+\.\d+\.\d+", line):
        m_if = re.search(r"(?:interface|ifname):\s*(\S+)", line)
        if m_if:
            iface = m_if.group(1)
            used[iface] = used.get(iface, 0) + 1

# --------------------------
# 4) Print results
# --------------------------
print("Interface/Server | % Free | Used/Total")
print("---------------------------------------")
if not pools:
    print("No DHCP pools found. Make sure 'show system dhcp server' was included.")
else:
    for iface in sorted(pools.keys()):
        total = pools.get(iface, 0)
        u = used.get(iface, 0)
        if total > 0:
            pct_free = 100.0 * (total - u) / total
            print(f"{iface:16} {pct_free:6.1f}%  {u}/{total}")
        else:
            print(f"{iface:16}   n/a   {u}/{total}")
            