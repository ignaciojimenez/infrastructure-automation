#!/bin/sh
# Regression test: vinylstreamer must give NetworkManager-wait-online more than
# the stock ~60 s to see Wi-Fi come up.
#
#   tests/unit/wait_online_dropin_test.sh
#
# After the 2026-10-28 plug-watchdog power cycle, wlan0 did not exist until ~2
# minutes after boot, so the stock unit failed and left a "1 failed systemd
# unit" finding behind. Static check on the audio_streaming role: the drop-in
# must be deployed, must raise NM_ONLINE_TIMEOUT (which the stock ExecStart
# reads) above 60 s, and systemd's start timeout must outlast it.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TASKS="$REPO_ROOT/ansible/roles/services/audio_streaming/tasks/main.yml"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── NetworkManager-wait-online drop-in\n'

[ -r "$TASKS" ] || { printf '   ✗ cannot read %s\n' "$TASKS"; exit 1; }

if grep -q 'NetworkManager-wait-online.service.d/override.conf' "$TASKS"; then
    pass "role deploys a wait-online drop-in"
else
    fail "role does not deploy a wait-online drop-in"
fi

timeout=$(sed -n 's/^[[:space:]]*Environment=NM_ONLINE_TIMEOUT=\([0-9][0-9]*\).*/\1/p' "$TASKS" | head -n 1)
if [ -n "$timeout" ] && [ "$timeout" -gt 60 ]; then
    pass "NM_ONLINE_TIMEOUT is ${timeout}s (> 60)"
else
    fail "NM_ONLINE_TIMEOUT missing or not above 60 s"
fi

start=$(sed -n 's/^[[:space:]]*TimeoutStartSec=\([0-9][0-9]*\).*/\1/p' "$TASKS" | head -n 1)
if [ -n "$start" ] && [ -n "$timeout" ] && [ "$start" -gt "$timeout" ]; then
    pass "TimeoutStartSec (${start}s) outlasts nm-online"
else
    fail "TimeoutStartSec missing or not above the nm-online timeout"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '   FAIL (%s)\n' "$failures"
exit 1
