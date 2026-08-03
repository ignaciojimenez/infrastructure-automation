#!/bin/sh
# The wrapper must survive two jobs writing the same state file at once.
#
# On dockassist three container checks wrapped the same script without
# --monitoring-name, so all three derived the same state file from the script's
# basename and ran in the same second. The temp file was a fixed
# "${STATE_FILE}.tmp": the first mv won, the rest died with "mv: cannot stat",
# state never persisted, and the "daily" heartbeat therefore fired on every
# 10-minute run. Those three jobs produced ~92% of #home-logging.
#
# Slack is pinned to 127.0.0.1 for the duration so the wrapper's curl fails
# fast and this test sends nothing anywhere.

. "$(dirname "$0")/../lib/harness.sh"

WRAP="$UUT_ROOT/scripts/common/enhanced_monitoring_wrapper"
WORK=/var/tmp/wraptest
HOSTS_BACKUP=/var/tmp/hosts.wraptest.bak
ROUNDS=5
CONCURRENCY=3

describe "concurrent state writes do not corrupt the state file"

cleanup() {
    if [ -f "$HOSTS_BACKUP" ]; then
        cat "$HOSTS_BACKUP" > /etc/hosts
        rm -f "$HOSTS_BACKUP"
    fi
    rm -rf "$WORK"
}

cat /etc/hosts > "$HOSTS_BACKUP"
printf '127.0.0.1 hooks.slack.com\n' >> /etc/hosts

rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/probe.sh" <<'PROBE'
#!/bin/sh
exit 0
PROBE
chmod +x "$WORK/probe.sh"

logs_dir="$WORK"
export logs_dir

# ------------------------------------------------------------------
# 1. Interval validation — deterministic
# ------------------------------------------------------------------
out=$(bash "$WRAP" --heartbeat-interval=weekly T00/B00/x "$WORK/probe.sh" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    _pass "unknown interval 'weekly' is rejected (exit $rc)"
else
    _fail "unknown interval 'weekly' was accepted — heartbeats silently disabled"
fi
if printf '%s' "$out" | grep -q "unrecognised"; then
    _pass "rejection names the offending value"
else
    _fail "rejection message unclear: $out"
fi

out=$(bash "$WRAP" --heartbeat-interval=never T00/B00/x "$WORK/probe.sh" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    _pass "'never' is accepted as a first-class value"
else
    _fail "'never' was rejected (exit $rc): $out"
fi

# ------------------------------------------------------------------
# 2. Concurrent writers — the actual collision
# ------------------------------------------------------------------
collision_log="$WORK/collisions.txt"
: > "$collision_log"

round=0
while [ "$round" -lt "$ROUNDS" ]; do
    round=$((round + 1))
    n=0
    while [ "$n" -lt "$CONCURRENCY" ]; do
        n=$((n + 1))
        bash "$WRAP" --heartbeat-interval=daily T00/B00/x "$WORK/probe.sh" \
            >> "$collision_log" 2>&1 &
    done
    wait
done

if grep -q "cannot stat" "$collision_log"; then
    _fail "state writes collided ($(grep -c 'cannot stat' "$collision_log") occurrence(s) of 'mv: cannot stat')"
else
    _pass "no 'mv: cannot stat' across $((ROUNDS * CONCURRENCY)) concurrent runs"
fi

state_file="$WORK/probe.sh.json"
if [ -f "$state_file" ]; then
    if jq -e . "$state_file" >/dev/null 2>&1; then
        _pass "state file is valid JSON after concurrent writes"
    else
        _fail "state file is corrupt: $(cat "$state_file")"
    fi
else
    _fail "state file was never written: $state_file"
fi

# No temp files may be left behind by the losing writers.
strays=$(find "$WORK" -name '*.json.*' ! -name '*.json.log' 2>/dev/null | wc -l)
if [ "$strays" -eq 0 ]; then
    _pass "no stray temp files left behind"
else
    _fail "$strays stray temp file(s) left in $WORK"
fi

finish
