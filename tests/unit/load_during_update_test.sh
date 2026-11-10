#!/bin/sh
# Regression test: high load while the scheduled HA update runs is a warning,
# not a failure of the health check.
#
#   tests/unit/load_during_update_test.sh
#
# The bug this pins (2026-11-10): dockassist's monthly update_ha (03:00 on the
# 10th) backs up and pulls an image for ~17 min; the :02 health check sampled
# a load of 6.83 on 4 CPUs and paged "1 issue(s) found".
#
# Case 3 is the load-bearing one: the same load with no update running must
# still fail.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_load while update_ha runs\n'

# Not a container; pgrep answers from $UPDATE_RUNNING; nproc says 4.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/systemd-detect-virt" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$BIN/pgrep" <<'STUB'
#!/bin/sh
[ "${UPDATE_RUNNING:-0}" = 1 ]
STUB
cat > "$BIN/nproc" <<'STUB'
#!/bin/sh
echo 4
STUB
chmod +x "$BIN/systemd-detect-virt" "$BIN/pgrep" "$BIN/nproc"
PATH="$BIN:$PATH"
export PATH

export OS_TYPE=debian THRESHOLD_CPU=80
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent MAINTENANCE_DIR="$WORK/no-windows"

ESC=$(printf '\033')
load_line() {
    sed -n '/System Load/,/^$/p' "$WORK/out" | sed "s/${ESC}\[[0-9;]*m//g" | grep 'Load:'
}
run_case() {
    printf '%s 2.52 0.93 1/100 1\n' "$2" > "$WORK/loadavg"
    UPDATE_RUNNING="$1" LOADAVG_FILE="$WORK/loadavg" sh "$SCRIPT" > "$WORK/out" 2>&1
}

# 1. The reported event: 6.83 on 4 CPUs with the update running.
run_case 1 6.83
if load_line | grep -q '⚠️ Load: 6.83 on 4 CPUs (171%) - scheduled HA update in progress'; then
    pass "high load during the HA update is a warning"
else
    fail "load during update not downgraded"; load_line >&2
fi

# 2. ... and it does not count as an issue.
if sed "s/${ESC}\[[0-9;]*m//g" "$WORK/out" | grep -q '❌ Load'; then
    fail "load still reported as an error"
else
    pass "the load line is not an error"
fi

# 3. 🔴 Same load, nothing running: must fail.
run_case 0 6.83
if load_line | grep -q '❌ Load: 6.83 on 4 CPUs (171%)'; then
    pass "high load with no update running still fails"
else
    fail "high load no longer reported"; load_line >&2
fi

if [ "$failures" -gt 0 ]; then
    printf '\n%s failure(s)\n' "$failures"
    exit 1
fi
printf '\nall passed\n'
