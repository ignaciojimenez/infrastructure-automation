#!/bin/sh
# unifi_state.py's render(): a diff of two captures is the upgrade's pass/fail.
#
#   tests/unit/unifi_state_test.sh
#
# PER-128's forced acceptance, at unit scale: an unchanged controller renders
# byte-identical (even when the API returns its arrays in another order), and
# one change renders as exactly the lines it touched — no more, no fewer. A
# check that always reports "no difference" passes the first half alone, so
# the second half is the one that matters. The same two cases run against the
# live controller in the procedure (ansible/roles/services/unifi_os/README.md).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

# Renders the fixture after applying one mutation (a Python statement on `s`,
# the site dict) to a fresh copy.
render() {
    python3 -I - "$REPO_ROOT/scripts/services/network" "$1" <<'EOF'
import copy, sys
sys.path.insert(0, sys.argv[1])
import unifi_state
site = {
    "name": "default", "desc": "Default",
    "devices": [
        {"mac": "02:00:00:00:00:01", "name": "AP One", "model": "U7PG2", "type": "uap",
         "adopted": True, "state": 1, "version": "6.7.57.15670", "uptime": 100, "ip": "10.0.0.2"},
        {"mac": "02:00:00:00:00:02", "name": "AP Two", "model": "UAL6", "type": "uap",
         "adopted": True, "state": 1, "version": "6.8.2.15592", "uptime": 200, "ip": "10.0.0.3"},
    ],
    "networks": [
        {"_id": "n1", "name": "LAN", "purpose": "corporate", "vlan_enabled": False,
         "ip_subnet": "10.0.0.1/24", "enabled": True},
        {"_id": "n2", "name": "IoT", "purpose": "vlan-only", "vlan_enabled": True, "vlan": 30,
         "enabled": True},
    ],
    "wlans": [
        {"_id": "w1", "name": "Home Net", "enabled": True, "networkconf_id": "n1",
         "security": "wpapsk", "wpa_mode": "wpa2", "hide_ssid": False, "is_guest": False,
         "x_passphrase": "fixture-psk-must-not-appear"},
        {"_id": "w2", "name": "Things", "enabled": True, "networkconf_id": "n2",
         "security": "wpapsk", "wpa_mode": "wpa2", "hide_ssid": True, "is_guest": False},
    ],
}
s = copy.deepcopy(site)
exec(sys.argv[2])
sys.stdout.write("\n".join(unifi_state.render([s])) + "\n")
EOF
}

# Lines diff adds or removes, without the ---/+++ headers.
changed() { diff -u "$1" "$2" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) '; }

printf '\n── unifi-state render (PER-128)\n'

render 'pass' > "$WORK/a" || exit 1
render 'pass' > "$WORK/b"
render 's["devices"].reverse(); s["networks"].reverse(); s["wlans"].reverse()' > "$WORK/reordered"
render 's["devices"][0]["uptime"] = 999; s["devices"][1]["ip"] = "10.0.0.9"' > "$WORK/noise"

if cmp -s "$WORK/a" "$WORK/b" && cmp -s "$WORK/a" "$WORK/reordered"; then
    pass "unchanged controller: identical, whatever order the API lists objects in"
else
    fail "unchanged controller rendered differently"
fi

if cmp -s "$WORK/a" "$WORK/noise"; then
    pass "uptime and IP are not state: no difference"
else
    fail "volatile fields leaked into the snapshot"
fi

render 's["wlans"][0]["name"] = "Home Net 2"' > "$WORK/renamed"
got=$(changed "$WORK/a" "$WORK/renamed")
want='-wlan "default" "Home Net" enabled=true network="LAN" security="wpapsk" wpa_mode="wpa2" hidden=false guest=false
+wlan "default" "Home Net 2" enabled=true network="LAN" security="wpapsk" wpa_mode="wpa2" hidden=false guest=false'
if [ "$got" = "$want" ]; then
    pass "renamed WLAN: exactly its own line changes"
else
    fail "renamed WLAN: expected one -/+ pair, got:"; printf '%s\n' "$got" | sed 's/^/       /'
fi

render 's["devices"][1]["state"] = 0' > "$WORK/offline"
if [ "$(changed "$WORK/a" "$WORK/offline" | wc -l | tr -d ' ')" = 2 ] \
    && changed "$WORK/a" "$WORK/offline" | grep -q '^+device "default" "02:00:00:00:00:02" .*state=0'; then
    pass "device offline: exactly its own line changes"
else
    fail "device offline not reported as one line"
fi

render 's["networks"][1]["vlan"] = 31' > "$WORK/vlan"
if changed "$WORK/a" "$WORK/vlan" | grep -q '^+network "default" "IoT" .*vlan=31'; then
    pass "VLAN change is reported"
else
    fail "VLAN change not reported"
fi

render 's["devices"].pop()' > "$WORK/gone"
if changed "$WORK/a" "$WORK/gone" | grep -q '^+site "default" .*devices=1'; then
    pass "a lost device changes the site's device count"
else
    fail "device count did not change when a device vanished"
fi

if grep -q 'fixture-psk' "$WORK/a"; then
    fail "the WLAN passphrase reached the snapshot"
else
    pass "no passphrase in the snapshot"
fi

[ "$failures" -eq 0 ]
