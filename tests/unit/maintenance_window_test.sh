#!/bin/sh
# Regression test: an announced maintenance window suppresses the alert for the
# service it names, for as long as it says, and for nothing else.
#
# Runs on the laptop — no container, no fleet, no network. `systemctl` is
# stubbed to hold a service permanently down, which is the only interesting
# starting state: every case below differs solely in what the marker says.
#
#   tests/unit/maintenance_window_test.sh
#
# The bug this pins (2026-08-15 04:00, cobra): `backup_plex_config` stops
# plexmediaserver for ~22 s to snapshot its config, and system_health_check.sh
# sampled that gap and paged `Service plexmediaserver: not running`. Nothing was
# wrong. The alert existed *because* coverage had just been added — before
# per-host `critical_services` on 2026-08-13, this check never looked at Plex.
#
# ⚠️ Every case here is really the same question asked from a different side:
# WHEN DOES THIS STOP SUPPRESSING? A suppression mechanism is only as good as
# the boundaries around it, so cases 2, 3, 4 and 6 — no window, expired window,
# window for another service, corrupt window — are the load-bearing ones. Case 1
# is the feature; the rest are the reason it is safe. If this file is ever
# trimmed, keep 2 and 3.
#
# 📌 Against `main` (before the fix) this file scores 9 pass / 6 fail — and the
# 9 are VACUOUS there: a script with no suppression at all trivially satisfies
# every "must still alert" case. Only the 6 failures show the feature missing.
# Stated because a green count is not evidence on its own; see the same trap in
# service_recheck_test.sh's header, where forced OS detection was what stopped
# two assertions passing without executing anything.

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

printf '\n── check_services announced maintenance windows\n'

# ------------------------------------------------------------------
# systemctl stub: the service under test is ALWAYS down. $SVC_UP=1 flips it up
# for the one case that needs a healthy service.
# ------------------------------------------------------------------
cat > "$BIN/systemctl" <<'STUB'
#!/bin/sh
[ "$1" = "is-active" ] || exit 0
[ "${SVC_UP:-0}" = "1" ] && exit 0
exit 3
STUB
chmod +x "$BIN/systemctl"
PATH="$BIN:$PATH"
export PATH

# OS_TYPE is forced because detection keys on /etc/debian_version, absent on the
# macOS control machine — without it the whole section degrades to "not
# configured for unknown" and every assertion below passes having executed
# nothing. That is not hypothetical; see service_recheck_test.sh's header.
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export OS_TYPE=debian
export CRITICAL_SERVICES="testsvc"
export SERVICE_RECHECK_ATTEMPTS=2 SERVICE_RECHECK_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent
export MAINTENANCE_DIR="$MW"

now=$(date +%s)

# Baseline: what this script reports on this machine with the service down and
# no window at all. Everything below is measured against it, so an unrelated
# check failing on the control machine cannot make a case pass or fail.
BASELINE=""

run() {
    rm -f "$MW"/* 2>/dev/null
    SVC_UP="${SVC_UP:-0}" sh "$SCRIPT" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
# Same as run(), but writes a marker first. write_marker <unit> <contents>
run_with() {
    rm -f "$MW"/* 2>/dev/null
    printf '%s\n' "$2" > "$MW/$1"
    SVC_UP="${SVC_UP:-0}" sh "$SCRIPT" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
svc_line() { sed -n '/Critical Services/,/^$/p' "$WORK/out" | sed 's/\x1b\[[0-9;]*m//g'; }
rc()       { cat "$WORK/rc"; }

# The script's exit status is NOT a usable signal here, and assuming it was
# would have made two of these cases vacuous. On the macOS control machine
# `check_auto_upgrades` reports `unattended-upgrades package not installed`, so
# the run carries one unrelated issue and exits 1 no matter what the service
# check decides. What is unambiguous is the count in the summary line, and the
# DELTA against a baseline run of the same script — a window must remove
# exactly the one issue it names, and nothing else.
issues() {
    _n=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/out" |
         sed -n 's/.*completed - \([0-9][0-9]*\) issue.*/\1/p')
    echo "${_n:-0}"
}

# ------------------------------------------------------------------
# 0. Establish the baseline: dead service, no window, nothing suppressed.
# ------------------------------------------------------------------
run
BASELINE=$(issues)
if [ "$BASELINE" -ge 1 ]; then
    pass "baseline: a dead service counts as an issue ($BASELINE total on this machine)"
else
    fail "baseline run found no issues at all — the service check never ran"; svc_line >&2
fi

# ------------------------------------------------------------------
# 1. The feature. Service down, window open → the issue is not charged, so
#    enhanced_monitoring_wrapper raises nothing.
# ------------------------------------------------------------------
run_with testsvc "$((now + 300)) backup_plex_config pid=123"
if ! svc_line | grep -q '❌'; then
    pass "a service down inside an announced window does not alert"
else
    fail "the window did not suppress"; svc_line >&2
fi
if [ "$(issues)" -eq $((BASELINE - 1)) ]; then
    pass "and it costs exactly one issue less than the baseline — no more, no less"
else
    fail "expected $((BASELINE - 1)) issues inside the window, got $(issues)"
fi

# ------------------------------------------------------------------
# 2. 🔴 SUPPRESSION IS NOT SILENCE. The service is still reported down, in the
#    output, with the reason from the marker. A window that removed the line
#    would leave a reader unable to tell a maintenance window from a healthy
#    host.
# ------------------------------------------------------------------
if svc_line | grep -q '⚠️.*Service testsvc: not running.*announced maintenance window'; then
    pass "the suppressed service is still printed, as a warning"
else
    fail "the window hid the service entirely"; svc_line >&2
fi
if svc_line | grep -q 'backup_plex_config'; then
    pass "and the line names the job that opened the window"
else
    fail "the marker's reason never reached the output"; svc_line >&2
fi

# ------------------------------------------------------------------
# 3. 🔴 THE LOAD-BEARING CASE — the real failure, forced. Same dead service,
#    no marker at all. This must fail exactly as it did before any of this
#    existed. If it ever passes-by-suppressing, the check has been lobotomised
#    and every case above is worthless.
# ------------------------------------------------------------------
run
if svc_line | grep -q '❌ Service testsvc: not running'; then
    pass "🔴 with NO window, a dead service still alerts"
else
    fail "the real failure stopped firing"; svc_line >&2
fi
if [ "$(issues)" -eq "$BASELINE" ] && [ "$(rc)" -ne 0 ]; then
    pass "🔴 …it is still charged as an issue, and the script still exits non-zero"
else
    fail "dead service: expected $BASELINE issues and rc≠0, got $(issues) and rc $(rc)"
fi

# ------------------------------------------------------------------
# 4. 🔴 An EXPIRED window does not suppress. This is the case that matters most
#    in production: a backup killed between `stop` and `start` leaves the
#    service down forever. The deadline is what stops that from being silent.
# ------------------------------------------------------------------
run_with testsvc "$((now - 60)) backup_plex_config pid=123"
if svc_line | grep -q '❌'; then
    pass "🔴 an expired window does NOT suppress"
else
    fail "a stale marker suppressed indefinitely"; svc_line >&2
fi
if [ "$(issues)" -eq "$BASELINE" ]; then
    pass "…and the issue is charged in full, exactly as with no window at all"
else
    fail "expired window still discounted the issue: $(issues) vs $BASELINE"
fi
# …and it is reported as the worse fault it actually is, not as a plain outage.
if svc_line | grep -q 'EXPIRED maintenance window'; then
    pass "and it says the window expired, naming the real fault"
else
    fail "expired window reported as an ordinary outage"; svc_line >&2
fi

# ------------------------------------------------------------------
# 5. A window is per service. plexmediaserver's backup says nothing about smbd.
# ------------------------------------------------------------------
run_with othersvc "$((now + 300)) some other job"
if svc_line | grep -q '❌ Service testsvc: not running'; then
    pass "a window for another service does not suppress this one"
else
    fail "suppression leaked across services"; svc_line >&2
fi

# ------------------------------------------------------------------
# 6. Fail closed. A truncated or corrupt marker — a writer killed mid-write —
#    must read as "no window", not as "window forever".
# ------------------------------------------------------------------
run_with testsvc "not-a-number backup_plex_config"
if svc_line | grep -q '❌'; then
    pass "an unparseable marker fails closed and still alerts"
else
    fail "garbage in the marker suppressed the alert"; svc_line >&2
fi
if svc_line | grep -q 'unreadable maintenance marker'; then
    pass "and the corrupt marker is named, not silently ignored"
else
    fail "corrupt marker was dropped without a word"; svc_line >&2
fi
run_with testsvc ""
if svc_line | grep -q '❌'; then
    pass "an empty marker fails closed too"
else
    fail "empty marker suppressed the alert"; svc_line >&2
fi

# ------------------------------------------------------------------
# 7. A healthy service is unaffected by an open window. The window is consulted
#    only once a service already looks down, so it can never turn a running
#    service into a warning — and it costs a healthy host nothing.
# ------------------------------------------------------------------
SVC_UP=1 run_with testsvc "$((now + 300)) backup_plex_config pid=123"
if svc_line | grep -q '✅ Service testsvc: running'; then
    pass "a running service reports running even with a window open"
else
    fail "an open window disturbed a healthy service"; svc_line >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ check_services maintenance windows: all checks passed\n'
    exit 0
fi
printf '❌ check_services maintenance windows: %s check(s) failed\n' "$failures"
exit 1
