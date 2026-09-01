#!/bin/sh
# Regression test: check_auto_upgrades must survive the logrotate window
# WITHOUT going blind to a genuinely stale host.
#
# Runs on the laptop — no container, no apt, no unattended-upgrades. The
# function definitions are extracted from system_health_check.sh, and a fixture
# tree stands in for /var/log/unattended-upgrades.
#
#   tests/unit/auto_upgrades_rotation_test.sh
#
# The bug this pins (2026-09-01): the freshness probe grepped only the LIVE
# unattended-upgrades.log. Debian rotates that log `monthly`, so on the 1st of
# each month it is an empty file from just after midnight until the apt timer
# fires at ~06:00-07:00. In that window the check reported "No upgrade activity
# found in logs - ACTION REQUIRED" and paged — six hosts on 2026-09-01, plus
# three fleet investigations at $0.99 that each re-derived the same non-fault.
#
# The obvious fix — read the rotated log too — is also the obvious way to
# lobotomise the check, because "stop complaining" is satisfied just as well by
# a probe that can no longer fail. So this asserts BOTH halves:
#
#   1. fresh run in the ROTATED log, empty live log  -> no issue  (the fix)
#   2. only a 40-day-old run anywhere                -> STILL fails (the teeth)
#
# Case 2 is the one that matters. If someone later replaces the fallback with
# something that always returns 0, case 1 keeps passing and case 2 goes red.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_auto_upgrades across the logrotate window\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

# Extract definitions only, stopping before the main call section — sourcing the
# whole script would run every check against this laptop. Same anchor the other
# unit tests use: the CALL to check_uptime, in either shape.
main_line=$(grep -nE '^check_uptime([^(]|$)' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$main_line" ]; then
    printf '   ✗ could not locate the main call section (no check_uptime call line)\n'
    exit 1
fi
sed -n "1,$((main_line - 1))p" "$SCRIPT" > "$WORK/funcs.sh"

# Fail loudly rather than skipping. A test that quietly does nothing when its
# subject is absent is the same class of defect it is here to catch.
if ! grep -q '^check_auto_upgrades()' "$WORK/funcs.sh"; then
    printf '   ✗ check_auto_upgrades() is not defined in %s\n' "$SCRIPT"
    exit 1
fi

# ------------------------------------------------------------------
# Harness. The function hard-codes /var/log/unattended-upgrades, so the fixture
# is injected by overriding log_dir/log_file after sourcing but before the call
# — the function reads them as globals. dpkg/systemctl are stubbed so the test
# reaches the freshness probe instead of failing earlier on this laptop.
# ------------------------------------------------------------------
run_case() {
    fixture_dir="$1"
    cat > "$WORK/case.sh" <<CASE
. "$WORK/funcs.sh" >/dev/null 2>&1
OS_TYPE=debian
dpkg() { echo "ii  unattended-upgrades"; }
systemctl() { return 0; }
check_auto_upgrades() {
$(sed -n '/^check_auto_upgrades()/,/^}/p' "$WORK/funcs.sh" \
    | sed '1d;$d' \
    | sed "s#log_dir=\"/var/log/unattended-upgrades\"#log_dir=\"$fixture_dir\"#")
}
check_auto_upgrades >"$WORK/out.txt" 2>&1
echo \$?
CASE
    sh "$WORK/case.sh"
}

recent=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d '1 day ago' '+%Y-%m-%d')
ancient=$(date -v-40d '+%Y-%m-%d' 2>/dev/null || date -d '40 days ago' '+%Y-%m-%d')
# ------------------------------------------------------------------
# Baseline — a healthy live log. This laptop has no /etc/apt/apt.conf.d, so the
# function always books one issue for the missing config regardless of what the
# freshness probe does. Every assertion below is therefore relative to this
# number, which isolates the only thing under test.
# ------------------------------------------------------------------
FIX0="$WORK/fix0"; mkdir -p "$FIX0"
printf '%s 06:53:01,123 INFO Starting unattended upgrades script\n' "$recent" \
    > "$FIX0/unattended-upgrades.log"
base=$(run_case "$FIX0")
if grep -q "Last upgrade: $recent" "$WORK/out.txt"; then
    pass "baseline: healthy live log reads $recent (ambient issues: $base)"
else
    fail "baseline fixture did not work; got:"
    sed 's/^/       /' "$WORK/out.txt"
    exit 1
fi

# ------------------------------------------------------------------
# Case 1 — the 1st-of-the-month shape: live log rotated to empty, fresh run
#          sitting in the compressed .1.gz. This is exactly what all six hosts
#          looked like at 00:02 CEST on 2026-09-01. It must cost NOTHING more
#          than the healthy baseline.
# ------------------------------------------------------------------
FIX1="$WORK/fix1"; mkdir -p "$FIX1"
: > "$FIX1/unattended-upgrades.log"
printf '%s 06:53:01,123 INFO Starting unattended upgrades script\n' "$recent" \
    | gzip -c > "$FIX1/unattended-upgrades.log.1.gz"

rc=$(run_case "$FIX1")
if [ "$rc" -eq "$base" ]; then
    pass "empty live log + fresh run in .1.gz -> no issue beyond baseline (no page)"
else
    fail "empty live log + fresh run in .1.gz -> $rc vs baseline $base"
    sed 's/^/       /' "$WORK/out.txt"
fi
if grep -q "Last upgrade: $recent" "$WORK/out.txt"; then
    pass "recovered the real date from the rotated log ($recent)"
else
    fail "did not report the rotated log's date; got:"
    sed 's/^/       /' "$WORK/out.txt"
fi

# ------------------------------------------------------------------
# Case 2 — THE TEETH. Nothing anywhere but a 40-day-old run. The fallback must
#          find it, parse it, and still fail on STALE_DAYS. A fallback that
#          merely suppresses would come back at baseline here.
# ------------------------------------------------------------------
FIX2="$WORK/fix2"; mkdir -p "$FIX2"
: > "$FIX2/unattended-upgrades.log"
printf '%s 06:12:56,369 INFO Starting unattended upgrades script\n' "$ancient" \
    | gzip -c > "$FIX2/unattended-upgrades.log.1.gz"

rc=$(run_case "$FIX2")
if [ "$rc" -gt "$base" ]; then
    pass "only a 40-day-old run -> still fails ($rc vs baseline $base); kept its teeth"
else
    fail "only a 40-day-old run -> $rc, same as baseline; the fallback silenced a REAL stale host"
    sed 's/^/       /' "$WORK/out.txt"
fi
if grep -q 'ACTION REQUIRED' "$WORK/out.txt"; then
    pass "reported the staleness as ACTION REQUIRED"
else
    fail "stale host did not produce ACTION REQUIRED; got:"
    sed 's/^/       /' "$WORK/out.txt"
fi

# ------------------------------------------------------------------
# Case 3 — genuinely nothing: empty live log, no rotated log at all. A host
#          where unattended-upgrades has never run must still be reported.
# ------------------------------------------------------------------
FIX3="$WORK/fix3"; mkdir -p "$FIX3"
: > "$FIX3/unattended-upgrades.log"

rc=$(run_case "$FIX3")
if [ "$rc" -gt "$base" ]; then
    pass "no run anywhere -> still fails ($rc vs baseline $base)"
else
    fail "no run anywhere -> $rc, same as baseline; expected a failure"
    sed 's/^/       /' "$WORK/out.txt"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   all checks passed\n\n'
    exit 0
fi
printf '   %d check(s) failed\n\n' "$failures"
exit 1
