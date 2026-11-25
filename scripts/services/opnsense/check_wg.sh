#!/bin/sh
# check_wg.sh — are the Mullvad tunnels usable, judged the way OPNsense's own
# failover judges them: by gateway status (dpinger), group by group.
#
#   CRITICAL (2): a gateway group that an enabled firewall rule routes to has no
#                 usable member, so failover has nowhere left to send that
#                 traffic. Groups no rule uses are standby exits: they are
#                 judged through their members, below.
#   WARNING  (1): a Mullvad gateway has been down for 12 hours straight, with
#                 what its tunnel's handshake says: still handshaking points at
#                 the monitor, stale or never points at the tunnel itself.
#   WARNING  (1): no enabled rule routes to any gateway group, or the check
#                 cannot record when gateways went down.
#   OK       (0): otherwise. A gateway down for less than 12 hours is listed,
#                 not warned.
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
# ── Why a single gateway waits 12 hours (2026-11-25) ──────────────────────────
# Warning on any gateway down at the moment of a run paged 12 times in four
# days (2026-11-21 to -24) over five spells: four were over within 40 minutes,
# the fifth was ES3's F-root monitor, down 38 hours. dpinger calls a gateway
# down when more than 20 % of one minute's pings to its monitor are lost, so a
# one-minute burst that overlaps a run pages. A month of its transitions (2026-10-26 to 11-25): the
# down spells that healed on their own lasted up to 7 hours; the four faults
# that needed a hand lasted 38 hours or more (NL3 with no peer, US3 behind
# Quad9's monitor, ES3's rotated key, ES3's F-root monitor). 12 hours sits
# between the two. Every gateway gets the same wait, the standby exits too:
# they are kept ready to switch to, and a dead one must not be found then.
# A gateway is "down since" the first run that saw it down, and any run that
# sees it up clears that, so one that flaps faster than 12 hours never warns.
#
# The group alarm stays immediate but says less than it did. It used to say the
# traffic "leaves via the WAN gateway, unencrypted". OPNsense 26.7.9's source
# says otherwise: GatewayGroups::getActiveGroups falls back to the first tier's
# gateways when no tier is up, so route-to keeps the tunnel. Not tested live
# (docs/NETWORK.md, Failover), so neither claim is made here.
#
# Lines that carry a failure are marked ❌, which is what the wrapper hashes for
# its failure signature after collapsing digits — so handshake ages do not
# re-alert, but note that a swap between gateways whose names differ only in
# digits (NL1 down -> NL2 down) reads as unchanged; an added or cleared one does
# not.
#
# Reads /conf/config.xml (group wheel can) for gateway names, interfaces, group
# members and which groups enabled filter rules route to only: the file also
# holds private keys, so nothing else is read. No sudo: pluginctl and wg both
# work for the cron user. When each gateway went down is kept in a JSON file
# under ~/.log, beside the wrapper's own state.

set -u
PATH="$PATH:/usr/local/sbin:/usr/local/bin"

CONFIG="${CHECK_WG_CONFIG:-/conf/config.xml}"
NOW="${CHECK_WG_NOW:-$(date +%s)}"
STATE="${CHECK_WG_STATE:-${HOME:-/nonexistent}/.log/check_wg_down.json}"

work=$(mktemp -d) || { echo "CRITICAL: cannot create a temporary directory"; exit 2; }
trap 'rm -rf "$work"' EXIT

if ! pluginctl -r return_gateways_status > "$work/status.json" 2> "$work/err"; then
    echo "❌ CRITICAL: cannot read gateway status (pluginctl -r return_gateways_status): $(head -c 200 "$work/err")"
    exit 2
fi
# No handshakes is information, not a failure of this check: every tunnel
# then reads as never handshaken.
wg show all latest-handshakes > "$work/hs" 2> /dev/null || : > "$work/hs"

python3 - "$work/status.json" "$CONFIG" "$work/hs" "$NOW" "$STATE" <<'PY'
import json, os, re, sys
import xml.etree.ElementTree as ET

status_file, config_file, hs_file, now, state_file = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
FRESH = 180  # WireGuard re-handshakes every two minutes on a live tunnel
WARN_AFTER = 12 * 3600  # see the header: real faults lasted 38 h, blips up to 7 h

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

# Groups an enabled filter rule routes to. 26.7 keeps every filter rule in the
# MVC model; the legacy <filter> section holds none.
rules = root.find("OPNsense/Firewall/Filter/rules")
in_use = {r.findtext("gateway") for r in ([] if rules is None else rules.findall("rule"))
          if r.findtext("enabled") == "1" and r.findtext("gateway")}

def state(name):
    return (status.get(name) or {}).get("status", "missing")

def dur(secs):
    return f"{secs // 3600} h {secs % 3600 // 60} min" if secs >= 3600 else f"{secs // 60} min"

def tunnel(dev):
    t = handshake.get(dev, 0)
    if t == 0:
        return f"tunnel {dev} has not handshaken since boot, so the tunnel itself is dead"
    age = now - t
    if age <= FRESH:
        return f"tunnel {dev} still handshakes ({age} s ago), so the monitor is the likelier fault"
    return f"tunnel {dev} last handshook {age} s ago, so the tunnel itself is dead"

lines, worst, judged = [], 0, []

for g in root.iter("gateway_group"):
    name, trigger = g.findtext("name") or "?", g.findtext("trigger") or "down"
    if name not in in_use:
        continue
    judged.append(name)
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
                     "failover has no gateway left for the traffic routed to it")
if not judged:
    worst = max(worst, 1)
    lines.append("❌ WARNING: no enabled firewall rule routes to a gateway group, so no group's exhaustion is watched")

# When each gateway went down. A missing or unreadable file restarts the timers.
try:
    since = {k: int(v) for k, v in json.load(open(state_file)).items()}
    state_note = ""
except FileNotFoundError:
    since, state_note = {}, ""
except Exception:
    since, state_note = {}, f"; {state_file} was unreadable, so the down timers restarted"

held, pending = {}, []
for name, (dev, monitor) in sorted(gateways.items()):
    st = state(name)
    if st not in ("down", "missing"):
        continue
    held[name] = min(since.get(name, now), now)
    age = now - held[name]
    what = ("has no gateway status (not monitored by dpinger)" if st == "missing"
            else f"is down: monitor {monitor} not answering")
    if age >= WARN_AFTER:
        worst = max(worst, 1)
        lines.append(f"❌ WARNING: {name} {what}, for {dur(age)}; {tunnel(dev)}")
    else:
        pending.append(f"{name} ({dur(age)})")

try:
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    with open(state_file + ".tmp", "w") as f:
        json.dump(held, f)
    os.replace(state_file + ".tmp", state_file)
except OSError as e:
    worst = max(worst, 1)
    lines.append(f"❌ WARNING: cannot record when gateways went down ({state_file}: {e.strerror}), "
                 "so a down gateway can never warn")

up = sum(1 for n in gateways if state(n) not in ("down", "missing"))
alarms = sorted(f"{n} ({state(n)})" for n in gateways if state(n) not in ("none", "down", "missing"))
summary = (f"{up}/{len(gateways)} Mullvad gateways up"
           + (f"; down under {WARN_AFTER // 3600} h, not warned yet: {', '.join(pending)}" if pending else "")
           + (f"; in loss/delay alarm: {', '.join(alarms)}" if alarms else "")
           + f"; groups carrying traffic: {', '.join(judged) or 'none'}" + state_note)

if worst == 0:
    print(f"OK: {summary}")
else:
    print("\n".join(lines))
    print(summary)
sys.exit(worst)
PY
