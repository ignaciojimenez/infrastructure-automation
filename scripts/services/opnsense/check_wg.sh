#!/bin/sh
# check_wg.sh — are the Mullvad tunnels usable, judged the way OPNsense's own
# failover judges them: by gateway status (dpinger), group by group.
#
#   CRITICAL (2): every member of a gateway group is unavailable. Traffic
#                 policy-routed to that group then leaves via the default (WAN)
#                 gateway, unencrypted — OPNsense's documented default with
#                 skip_rules_gw_down unset (docs/NETWORK.md, Failover).
#   WARNING  (1): any Mullvad gateway is down, with what its tunnel's handshake
#                 says: still handshaking points at the monitor, stale or never
#                 points at the tunnel itself.
#   OK       (0): every Mullvad gateway is up.
#   CRITICAL (2): the gateway status or the config cannot be read — a check that
#                 cannot judge must not report OK.
#
# ── Why it was rewritten (2026-11-20) ─────────────────────────────────────────
# The old check counted handshaking tunnels against fixed thresholds written for
# four tunnels: WARNING below 3 active, CRITICAL below 2. With twelve it stayed
# green until ten were dead. ES3 sat dead for three days (2026-11-17 to -20) and
# it said nothing; it also called US3 healthy while its gateway was down,
# because a tunnel can handshake while dpinger — which drives failover — says
# down. Gateway status is what failover acts on, so it is what this judges.
#
# A member is unavailable when dpinger says down — or, if the group's trigger
# includes loss or latency, when it is in that alarm, because failover then
# skips it too. A single gateway is only WARNED on `down`: loss and delay alarms
# flap (ES2's monitor sat at 5–8 % loss on 2026-11-20) and failover handles them.
#
# Lines that carry a failure are marked ❌, which is what the wrapper hashes for
# its failure signature after collapsing digits — so handshake ages do not
# re-alert, but note that a swap between gateways whose names differ only in
# digits (NL1 down -> NL2 down) reads as unchanged; an added or cleared one does
# not.
#
# Reads /conf/config.xml (group wheel can) for gateway names, interfaces and
# group members only: the file also holds private keys, so nothing else is read.
# No sudo: pluginctl and wg both work for the cron user.

set -u
PATH="$PATH:/usr/local/sbin:/usr/local/bin"

CONFIG="${CHECK_WG_CONFIG:-/conf/config.xml}"
NOW="${CHECK_WG_NOW:-$(date +%s)}"

work=$(mktemp -d) || { echo "CRITICAL: cannot create a temporary directory"; exit 2; }
trap 'rm -rf "$work"' EXIT

if ! pluginctl -r return_gateways_status > "$work/status.json" 2> "$work/err"; then
    echo "❌ CRITICAL: cannot read gateway status (pluginctl -r return_gateways_status): $(head -c 200 "$work/err")"
    exit 2
fi
# No handshakes is information, not a failure of this check: every tunnel
# then reads as never handshaken.
wg show all latest-handshakes > "$work/hs" 2> /dev/null || : > "$work/hs"

python3 - "$work/status.json" "$CONFIG" "$work/hs" "$NOW" <<'PY'
import json, re, sys
import xml.etree.ElementTree as ET

status_file, config_file, hs_file, now = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
FRESH = 180  # WireGuard re-handshakes every two minutes on a live tunnel

def die(msg):
    print(f"❌ CRITICAL: {msg}")
    sys.exit(2)

try:
    status = json.load(open(status_file))["dpinger"]
    assert isinstance(status, dict) and status
except Exception:
    die("gateway status is not the expected JSON (no 'dpinger' map)")
try:
    root = ET.parse(config_file).getroot()
except Exception as e:
    die(f"cannot read {config_file}: {e}")

ifaces = root.find("interfaces")
devices = {i.tag: i.findtext("if") or "" for i in ([] if ifaces is None else ifaces)}
gateways = {}  # name -> (device, monitor)
for g in root.iter("gateway_item"):
    dev = devices.get(g.findtext("interface") or "", "")
    if dev.startswith("wg") and g.findtext("disabled") != "1":
        gateways[g.findtext("name")] = (dev, g.findtext("monitor") or "?")
if not gateways:
    die(f"no enabled WireGuard gateway found in {config_file}")

handshake = {}
for line in open(hs_file):
    parts = line.split()
    if len(parts) == 3 and parts[2].isdigit():
        handshake[parts[0]] = max(handshake.get(parts[0], 0), int(parts[2]))

def state(name):
    return (status.get(name) or {}).get("status", "missing")

def tunnel(dev):
    t = handshake.get(dev, 0)
    if t == 0:
        return f"tunnel {dev} has not handshaken since boot, so the tunnel itself is dead"
    age = now - t
    if age <= FRESH:
        return f"tunnel {dev} still handshakes ({age} s ago), so the monitor is the likelier fault"
    return f"tunnel {dev} last handshook {age} s ago, so the tunnel itself is dead"

lines, worst = [], 0

for g in root.iter("gateway_group"):
    name, trigger = g.findtext("name") or "?", g.findtext("trigger") or "down"
    tiers = sorted((int(re.sub(r"\D", "", e.tag) or 1), e.text or "")
                   for e in g if re.fullmatch(r"item\d*", e.tag))
    members = [m.strip() for _, t in tiers for m in t.split(",") if m.strip()]
    def usable(m):
        st = state(m)
        if st == "none":
            return True
        if st in ("down", "missing"):
            return False
        return not (("loss" in st and "loss" in trigger[4:]) or ("delay" in st and "latency" in trigger))
    available = [m for m in members if usable(m)]
    if members and not available:
        worst = 2
        lines.append(f"❌ CRITICAL: gateway group {name} has no usable member ({', '.join(members)}): "
                     "traffic routed to it now leaves via the WAN gateway, unencrypted")

for name, (dev, monitor) in sorted(gateways.items()):
    st = state(name)
    if st == "missing":
        worst = max(worst, 1)
        lines.append(f"❌ WARNING: {name} has no gateway status (not monitored by dpinger); {tunnel(dev)}")
    elif st == "down":
        worst = max(worst, 1)
        lines.append(f"❌ WARNING: {name} is down: monitor {monitor} not answering; {tunnel(dev)}")

up = sum(1 for n in gateways if state(n) not in ("down", "missing"))
alarms = sorted(f"{n} ({state(n)})" for n in gateways if state(n) not in ("none", "down", "missing"))
summary = f"{up}/{len(gateways)} Mullvad gateways up" + (f"; in loss/delay alarm: {', '.join(alarms)}" if alarms else "")

if worst == 0:
    print(f"OK: {summary}")
else:
    print("\n".join(lines))
    print(summary)
sys.exit(worst)
PY
