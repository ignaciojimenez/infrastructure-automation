#!/bin/sh
# An announced "load" maintenance window downgrades a high-load error to a
# warning; no window, or an expired one, still alerts.
#
#   tests/unit/load_maintenance_window_test.sh
#
# The event this pins (fleet#173, 2026-11-10): dockassist's monthly update_ha
# backs up and pulls an image for ~17 min; the :02 health check sampled a load
# of 6.83 on 4 CPUs and paged. The expired case is the load-bearing one: a hung
# update must not silence the check for good.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_load announced maintenance windows\n'

# Not a container; nproc says 4.
BIN="$WORK/bin"
MW="$WORK/maintenance"
mkdir -p "$BIN" "$MW"
printf '#!/bin/sh\nexit 1\n' > "$BIN/systemd-detect-virt"
printf '#!/bin/sh\necho 4\n' > "$BIN/nproc"
chmod +x "$BIN/systemd-detect-virt" "$BIN/nproc"
PATH="$BIN:$PATH"
export PATH

export OS_TYPE=debian THRESHOLD_CPU=80
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent MAINTENANCE_DIR="$MW"
export LOADAVG_FILE="$WORK/loadavg"
printf '6.83 2.52 0.93 1/100 1\n' > "$LOADAVG_FILE"

now=$(date +%s)
ESC=$(printf '\033')

run_with() {
    rm -f "$MW"/* 2>/dev/null
    [ -z "$1" ] || printf '%s\n' "$1" > "$MW/load"
    sh "$SCRIPT" > "$WORK/out" 2>&1
}
load_line() {
    sed -n '/System Load/,/^$/p' "$WORK/out" | sed "s/${ESC}\[[0-9;]*m//g" | grep 'Load:'
}

run_with ""
if load_line | grep -q '❌ Load: 6.83 on 4 CPUs (171%)'; then
    pass "with no window, high load still alerts"
else
    fail "high load did not alert"; load_line >&2
fi

run_with "$((now + 300)) update_ha pid=1"
if load_line | grep -q '⚠️.*Load: 6.83.*update_ha' && ! load_line | grep -q '❌'; then
    pass "inside an announced window it is a warning naming the job"
else
    fail "window did not downgrade the alert"; load_line >&2
fi

run_with "$((now - 60)) update_ha pid=1"
if load_line | grep -q '❌ Load: 6.83'; then
    pass "an expired window does not suppress"
else
    fail "expired window suppressed"; load_line >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ load maintenance windows: all checks passed\n'
    exit 0
fi
printf '❌ load maintenance windows: %s check(s) failed\n' "$failures"
exit 1
