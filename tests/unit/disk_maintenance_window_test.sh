#!/bin/sh
# An announced "disk-usage" maintenance window downgrades a full-disk error to a
# warning; no, expired or corrupt window still alerts.
#
#   tests/unit/disk_maintenance_window_test.sh

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

BIN="$WORK/bin"
MW="$WORK/maintenance"
mkdir -p "$BIN" "$MW"

# df stub: root is always 86% full.
cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem Size Used Avail Use% Mounted on"
echo "/dev/root 100G 86G 14G 86% /"
STUB
chmod +x "$BIN/df"
PATH="$BIN:$PATH"
export PATH

export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export OS_TYPE=debian
export CRITICAL_SERVICES=""
export HEALTH_CHECK_CONF=/nonexistent
export MAINTENANCE_DIR="$MW"

now=$(date +%s)

run_with() {
    rm -f "$MW"/* 2>/dev/null
    [ -z "$1" ] || printf '%s\n' "$1" > "$MW/disk-usage"
    sh "$SCRIPT" > "$WORK/out" 2>&1
}
disk_line() { sed -n '/Disk Usage/,/^$/p' "$WORK/out" | sed 's/\x1b\[[0-9;]*m//g'; }

printf '\n── check_disk_usage announced maintenance windows\n'

run_with ""
if disk_line | grep -q '❌ Disk /: 86% (above 85%)'; then
    pass "with no window, a full disk still alerts"
else
    fail "full disk did not alert"; disk_line >&2
fi

run_with "$((now + 300)) update_ha pid=1"
if disk_line | grep -q '⚠️.*Disk /: 86%.*update_ha' && ! disk_line | grep -q '❌'; then
    pass "inside an announced window it is a warning naming the job"
else
    fail "window did not downgrade the alert"; disk_line >&2
fi

run_with "$((now - 60)) update_ha pid=1"
if disk_line | grep -q '❌ Disk /: 86%'; then
    pass "an expired window does not suppress"
else
    fail "expired window suppressed"; disk_line >&2
fi

run_with "garbage update_ha"
if disk_line | grep -q '❌ Disk /: 86%'; then
    pass "a corrupt marker fails closed"
else
    fail "corrupt marker suppressed"; disk_line >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ disk maintenance windows: all checks passed\n'
    exit 0
fi
printf '❌ disk maintenance windows: %s check(s) failed\n' "$failures"
exit 1
