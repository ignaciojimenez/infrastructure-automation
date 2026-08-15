#!/bin/sh
# Regression test: check_services must absorb a service that is mid-restart,
# and must NOT absorb one that is genuinely down.
#
# Runs on the laptop — no container, no fleet, no network. `systemctl` is
# stubbed so each case can script exactly what the real one would answer on
# each successive sample.
#
#   tests/unit/service_recheck_test.sh
#
# The bug this pins (2026-08-15): cobra alerted
# `Service plexmediaserver: not running` at 04:00. Nothing was wrong.
# `backup_plex.sh:123` does `systemctl stop plexmediaserver`, snapshots the
# config and starts it ~22 s later, and the `*/15` health check sampled that
# gap. `systemctl is-active` exits non-zero while a unit is `activating`, so on
# ONE sample a restart and an outage are the same observation.
#
# That alert existed *because of* the previous session: before per-host
# `critical_services` was declared on 2026-08-13, this check probed only
# `ssh cron fail2ban` and never looked at Plex at all.
#
# ⚠️ The dangerous direction is case 2. "Retry until it looks fine" is how a
# monitoring system stops reporting outages, so the retry is bounded, applies
# only to a service that looks DOWN, and a service still down at the end must
# fail exactly as it did before. Case 2 and case 5 are the ones worth keeping
# if this file is ever trimmed.

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
mkdir -p "$BIN"
COUNT="$WORK/count"

printf '\n── check_services restart tolerance\n'

# ------------------------------------------------------------------
# Stub systemctl. $FAIL_SAMPLES = how many leading `is-active` calls answer
# "not running" before it starts answering "running"; 99 means never recovers.
#
# Counting the calls is the point: it is what proves a retry actually happened
# rather than the case passing because the first sample was lucky.
# ------------------------------------------------------------------
cat > "$BIN/systemctl" <<STUB
#!/bin/sh
[ "\$1" = "is-active" ] || exit 0
n=\$(cat "$COUNT" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$COUNT"
[ "\$n" -le "\${FAIL_SAMPLES:-0}" ] && exit 3
exit 0
STUB
chmod +x "$BIN/systemctl"
PATH="$BIN:$PATH"
export PATH

# Keep the rest of the script off the network and out of the way; only the
# Critical Services section is under test here.
#
# OS_TYPE is forced because detection keys on /etc/debian_version, which does
# not exist on the macOS control machine — without this the whole section
# degrades to "not configured for unknown" and the assertions below pass
# without executing anything. The first run of this file did exactly that.
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export OS_TYPE=debian
export CRITICAL_SERVICES="testsvc"
export SERVICE_RECHECK_ATTEMPTS=3 SERVICE_RECHECK_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent

run_case() {
    # run_case <fail_samples>
    : > "$COUNT"
    FAIL_SAMPLES="$1" sh "$SCRIPT" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
svc_line() { sed -n '/Critical Services/,/^$/p' "$WORK/out" | sed 's/\x1b\[[0-9;]*m//g'; }
samples()  { cat "$COUNT" 2>/dev/null || echo 0; }

# ------------------------------------------------------------------
# 1. Healthy service: one sample, no retry, no warning.
# ------------------------------------------------------------------
run_case 0
if svc_line | grep -q '✅ Service testsvc: running'; then
    pass "a healthy service reports running"
else
    fail "healthy service misreported"; svc_line >&2
fi
if [ "$(samples)" -eq 1 ]; then
    pass "and costs exactly one sample — no retry on the happy path"
else
    fail "healthy service was polled $(samples) times"
fi

# ------------------------------------------------------------------
# 2. 🔴 THE LOAD-BEARING CASE. A service that never comes back must still be
#    reported down. If this ever passes-by-absorbing, the retry has become a
#    way of not noticing outages.
# ------------------------------------------------------------------
run_case 99
if svc_line | grep -q '❌ Service testsvc: not running'; then
    pass "a genuinely dead service is STILL reported down"
else
    fail "retry swallowed a real outage"; svc_line >&2
fi
if [ "$(samples)" -eq 3 ]; then
    pass "it gave up after exactly SERVICE_RECHECK_ATTEMPTS samples"
else
    fail "expected 3 samples before giving up, got $(samples)"
fi

# ------------------------------------------------------------------
# 3. Mid-restart: down on the first sample, up on the second. This is the
#    cobra/hifipi case, and it must NOT alert.
# ------------------------------------------------------------------
run_case 1
if ! svc_line | grep -q '❌'; then
    pass "a service that is mid-restart does not alert"
else
    fail "restart still produced an error"; svc_line >&2
fi

# ------------------------------------------------------------------
# 4. …and it says so, rather than silently smoothing it over. A service that
#    needed a retry WAS down a moment ago; on a host with no scheduled
#    maintenance that is a finding of its own.
# ------------------------------------------------------------------
if svc_line | grep -q 'settled after 2 checks'; then
    pass "the absorbed restart is surfaced as a warning, not hidden"
else
    fail "retry hid the fact that the service had been down"; svc_line >&2
fi

# ------------------------------------------------------------------
# 5. 🔴 The boundary. Down for exactly as long as the budget allows minus one
#    sample → absorbed. Down for one sample more → reported. Without both
#    halves, "3 attempts" could be off by one in either direction and no test
#    would notice.
# ------------------------------------------------------------------
run_case 2
if ! svc_line | grep -q '❌'; then
    pass "down for 2 of 3 samples is absorbed (boundary, inside)"
else
    fail "boundary case wrongly alerted"; svc_line >&2
fi
run_case 3
if svc_line | grep -q '❌ Service testsvc: not running'; then
    pass "down for all 3 samples alerts (boundary, outside)"
else
    fail "boundary case wrongly absorbed"; svc_line >&2
fi

# ------------------------------------------------------------------
# 6. The error text still carries the window it waited, so a reader can tell
#    this check from the old single-sample one at a glance.
# ------------------------------------------------------------------
run_case 99
if svc_line | grep -q 'checks over'; then
    pass "the failure message states how long it waited"
else
    fail "failure message lost the retry window"; svc_line >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ check_services restart tolerance: all checks passed\n'
    exit 0
fi
printf '❌ check_services restart tolerance: %s check(s) failed\n' "$failures"
exit 1
