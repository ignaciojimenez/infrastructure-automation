#!/bin/sh
# Regression test: Tier 1 must not rewrite last_anomaly.json when the findings
# have not changed.
#
# Runs on the laptop — no container, no fleet, no network. The template is
# rendered with test values and driven against a stubbed `ssh`.
#
#   tests/unit/anomaly_dedup_test.sh
#
# The bug this pins (found 2026-08-04, fixed 2026-08-06): investigate.sh gates
# on `[ ! "$ANOMALY_FILE" -nt "$MARKER" ]`, with the stated intent that a
# persistent fault is not re-investigated — and re-billed — every hour. But
# fleet_health_check.sh rewrote the snapshot on every sweep that found
# anything, so its mtime advanced hourly and the guard never once engaged. With
# opnsense unreachable that was ~$7-13/day and 24 push notifications, for the
# same finding.
#
# The assertion below is deliberately the *exact* predicate investigate.sh
# uses. Testing "the file was not written" would pass for a fix that wrote it
# with a stale mtime and still fail in production for some third reason; this
# tests the question Tier 2 actually asks.
#
# shellcheck disable=SC3013
# SC3013 ("in POSIX sh, -nt is undefined") is suppressed for the whole file,
# and only after checking rather than assuming: `-nt` was run under real dash
# on cwwk 2026-08-08 and is correct in both directions. Keeping `-nt` is the
# point — investigate.sh gates on `[ ! "$ANOMALY_FILE" -nt "$MARKER" ]`, so
# rewriting this as `find -newer` would test a predicate production does not
# use, which is exactly the vacuous pass the header above warns about.
# Surfaced only after the L-A merge: the CI shellcheck step arrived on
# test/e2e-harness, this file on fix/agent-lxc-logs-dir, and neither branch
# alone had both.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/fleet_health_check.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
ANOMALY="$AGENT_DIR/last_anomaly.json"
MARKER="$AGENT_DIR/.last_investigated"
STUB_DIR="$WORK/stub"
mkdir -p "$AGENT_DIR" "$STUB_DIR" "$WORK/bin"

printf '\n── Tier 1 anomaly snapshot dedup\n'

# ------------------------------------------------------------------
# Render, and stub the two commands that reach outside this machine
# ------------------------------------------------------------------
python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/sweep.sh" \
    agent_disk_threshold=85 \
    agent_wrapper_max_age_hours=26 \
    agent_ssh_timeout=5 \
    agent_ssh_backoff_base_seconds=3600 \
    agent_ssh_backoff_max_seconds=21600 \
    agent_state_dir="$AGENT_DIR" \
    agent_sweep_healthcheck_url="" \
    agent_fleet_hosts=cobra:linux,opnsense:linux || exit 1
# ^ deliberately empty: an unconfigured URL is the sweep's "do not ping" path,
# which keeps this test off the network. The ping itself is covered by
# tests/unit/sweep_healthcheck_test.sh.

# Answers as whichever host it was asked about, per $STUB_DIR/<host>.
cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
host=""
for a in "$@"; do
    case "$a" in *-agent) host="${a%-agent}" ;; esac
done
cat >/dev/null   # swallow the probe script
mode=ok
[ -f "$STUB_DIR/$host" ] && mode=$(cat "$STUB_DIR/$host")
case "$mode" in
    diskfull) echo "DISK=99" ;;
    *)        echo "DISK=10" ;;
esac
echo "FAILED=0"
echo "FAILEDUNITS="
echo "WRAPPER_LAST=$(date +%s)"
STUB
# The sweep's DNS pre-check; getent does not exist on macOS.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/getent"
chmod +x "$WORK/bin/ssh" "$WORK/bin/getent"

export STUB_DIR
PATH="$WORK/bin:$PATH"
export PATH

sweep() { sh "$WORK/sweep.sh" >"$WORK/out" 2>&1; }

# ------------------------------------------------------------------
# 1. A finding produces a snapshot
# ------------------------------------------------------------------
echo diskfull > "$STUB_DIR/cobra"
sweep
if [ -f "$ANOMALY" ] && grep -q 'disk usage 99%' "$ANOMALY"; then
    pass "a finding writes the snapshot"
else
    fail "no snapshot written for a real finding"
    printf '%s\n' "$(cat "$WORK/out")" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 2. Pretend Tier 2 has just handled it, then sweep again with the SAME
#    finding. The snapshot must NOT come out newer than the marker.
#
#    Both mtimes are set explicitly. Letting them land in the same second
#    would make `-nt` false for the wrong reason and pass vacuously.
# ------------------------------------------------------------------
touch -t 202001010000 "$ANOMALY"
touch -t 202001010001 "$MARKER"
sweep
if [ "$ANOMALY" -nt "$MARKER" ]; then
    fail "unchanged findings still advanced the snapshot — Tier 2 re-investigates and re-bills"
else
    pass "unchanged findings leave the snapshot older than the marker"
fi

if grep -q 'findings unchanged since the last sweep' "$WORK/out"; then
    pass "the sweep says so in its log"
else
    fail "the sweep did not report skipping the write"
fi

# ------------------------------------------------------------------
# 3. Different findings must still get through — a dedup that never
#    releases is the same outage as no dedup at all.
# ------------------------------------------------------------------
echo diskfull > "$STUB_DIR/opnsense"
sweep
if [ "$ANOMALY" -nt "$MARKER" ]; then
    pass "a changed finding advances the snapshot"
else
    fail "a NEW finding was swallowed — Tier 2 would never see it"
fi
if grep -q 'opnsense: disk usage 99%' "$ANOMALY"; then
    pass "the new finding is in the snapshot"
else
    fail "snapshot content did not update"
fi

# ------------------------------------------------------------------
# 4. The timestamp alone must never count as a change. This is the
#    trap the fix could most easily have fallen into: comparing whole
#    files leaves the guard exactly as dead, and every other assertion
#    here would still pass.
# ------------------------------------------------------------------
if grep -q "grep -v '\"timestamp\":'" "$TEMPLATE"; then
    pass "the comparison excludes the timestamp line"
else
    fail "the timestamp is no longer excluded — the guard is a no-op again"
fi

# ------------------------------------------------------------------
# 5. Recovery clears nothing by surprise: a clean sweep exits 0 and does
#    not touch the snapshot (Tier 2's marker logic owns that lifecycle).
# ------------------------------------------------------------------
rm -f "$STUB_DIR/cobra" "$STUB_DIR/opnsense"
touch -t 202001010000 "$ANOMALY"
if sweep; then
    pass "a clean sweep exits 0"
else
    fail "a clean sweep exited non-zero"
fi
if [ "$ANOMALY" -nt "$MARKER" ]; then
    fail "a clean sweep touched the snapshot"
else
    pass "a clean sweep leaves the snapshot alone"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
