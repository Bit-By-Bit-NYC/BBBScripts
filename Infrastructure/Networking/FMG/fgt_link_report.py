#!/usr/bin/env python3
import re, sys
from collections import defaultdict, OrderedDict

if len(sys.argv) < 2:
    print("Usage: python3 fgt_link_report.py <fmg_output.txt>")
    sys.exit(1)

text = open(sys.argv[1], 'r', encoding='utf-8', errors='ignore').read()

# --- Parse switch-interface section ---
switch_members = defaultdict(list)
cur_switch = None
for line in text.splitlines():
    line = line.strip()
    # start of a switch block: edit "<name>"
    m = re.match(r'^edit\s+"?([A-Za-z0-9._-]+)"?', line)
    if m:
        cur_switch = m.group(1)
        continue
    # members
    if cur_switch and line.startswith("set member "):
        # members may be quoted or unquoted, space-separated
        members = re.findall(r'"?([A-Za-z0-9._-]+)"?', line[len("set member "):])
        switch_members[cur_switch].extend(members)
    # end of block
    if line == "next":
        cur_switch = None

# --- Parse physical interface status section ---
# Blocks look like:
# ==[port1]
# mode: ...
# status: up
# speed: 1000Mbps (Duplex: full)
iface = None
status = {}
speed = {}
for line in text.splitlines():
    m = re.match(r'^==\[(.+?)\]', line.strip())
    if m:
        iface = m.group(1)
        continue
    if iface:
        if line.strip().startswith('status:'):
            status[iface] = line.split(':',1)[1].strip()
        elif line.strip().startswith('speed:'):
            speed[iface] = line.split(':',1)[1].strip()

# --- Build reverse map: interface -> switch (if any) ---
iface_to_switch = {}
for sw, members in switch_members.items():
    for m in members:
        iface_to_switch[m] = sw

# --- Output: grouped by switch, then unassigned ---
def sort_key(name):
    m = re.match(r'([A-Za-z]+)(\d+)$', name)
    if m:
        return (m.group(1), int(m.group(2)))
    return (name, 0)

print("=== PORT STATUS BY SWITCH ===")
if switch_members:
    for sw in sorted(switch_members.keys()):
        print(f"[{sw}]")
        for m in sorted(switch_members[sw], key=sort_key):
            s = status.get(m, 'unknown')
            sp = speed.get(m, '')
            print(f"  {m:<12} {s:<5} {sp}")
        print()
else:
    print("(No switch-interface configured)")

print("[UNASSIGNED PORTS]")
others = [i for i in status.keys() if i not in iface_to_switch]
for i in sorted(others, key=sort_key):
    print(f"  {i:<12} {status.get(i,'unknown'):<5} {speed.get(i,'')}")

    