#!/bin/sh
# Regression test: internet_speed_monitor must not page when every speedtest
# fails while the monthly update_ha job is running (PER-175), but must still
# exit 2 when the same failure happens with no update running.
#
#   tests/unit/speed_update_ha_skip_test.sh
#
# `speedtest` and `pgrep` are stubbed on PATH; no network is used.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/internet_speed_monitor"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── internet_speed_monitor: failures during update_ha\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"

cat > "$WORK/bin/speedtest" <<'STUB'
#!/bin/bash
if [[ "$*" == *--version* ]]; then
    echo "Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Linux/aarch64-linux-musl"
    exit 0
fi
echo '{"type":"log","message":"Configuration - No servers defined (NoServersException)","level":"error"}'
exit 1
STUB
chmod +x "$WORK/bin/speedtest"

make_pgrep() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$WORK/bin/pgrep"
    chmod +x "$WORK/bin/pgrep"
}

# CASE 1 — update_ha running: skip, exit 0
make_pgrep 0
"$SCRIPT" --tests=2 --delay=0 --state-dir="$WORK/state" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "all tests failed while update_ha runs → exit 0"
else
    fail "expected exit 0 while update_ha runs, got $rc"
fi

# CASE 2 — no update_ha: still a real failure
make_pgrep 1
"$SCRIPT" --tests=2 --delay=0 --state-dir="$WORK/state" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then
    pass "all tests failed with no update_ha → exit 2"
else
    fail "expected exit 2 with no update_ha, got $rc"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   ALL PASS\n\n'
    exit 0
fi
printf '   %d FAILED\n\n' "$failures"
exit 1
