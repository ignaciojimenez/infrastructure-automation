#!/bin/sh
# heartbeat_backup.sh reports its OWN failed ping, and still exits 0.
#
#   tests/unit/heartbeat_backup_test.sh
#   SH=dash tests/unit/heartbeat_backup_test.sh
#
# A dead-man's switch that cannot say its ping failed produces a failure that
# looks exactly like the one it exists to detect: healthchecks.io goes DOWN
# either way. The fix (capture curl's status instead of `|| true` with stderr
# discarded) sat untested; this forces the failure (docs/TODO.md item 12).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/common/heartbeat_backup.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin"
python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/hb.sh" \
    backup_heartbeat_name=unit \
    backup_healthcheck_url="https://hc-ping.invalid/unit" \
    backup_state_file="$WORK/state.json" \
    backup_max_age_minutes=60 || exit 1
printf '{"last_status": "success"}\n' > "$WORK/state.json"

# curl: fails like an unresolvable host when $WORK/curl_fail exists.
cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/curl.log"
if [ -f "$WORK/curl_fail" ]; then
    echo "curl: (6) Could not resolve host: hc-ping.invalid" >&2
    exit 6
fi
EOF
chmod +x "$WORK/bin/curl"

run() { PATH="$WORK/bin:$PATH" "$SH" "$WORK/hb.sh" > "$WORK/out" 2> "$WORK/err"; RC=$?; }

printf '\n── Backup heartbeat (item 12)\n'

run
if [ "$RC" -eq 0 ] && [ ! -s "$WORK/err" ] && grep -q "hc-ping.invalid/unit" "$WORK/curl.log"; then
    pass "fresh successful backup: pinged, nothing reported"
else
    fail "good ping: rc=$RC err=$(cat "$WORK/err")"
fi

touch "$WORK/curl_fail"
run
if [ "$RC" -eq 0 ] && grep -q "heartbeat: ping FAILED (exit 6): curl: (6) Could not resolve host" "$WORK/err"; then
    pass "a failed ping is reported with curl's exit status and error, and still exits 0"
else
    fail "forced failure: rc=$RC err=$(cat "$WORK/err")"
fi
rm -f "$WORK/curl_fail"

: > "$WORK/curl.log"
printf '{"last_status": "failure"}\n' > "$WORK/state.json"
run
if [ "$RC" -eq 0 ] && [ ! -s "$WORK/curl.log" ]; then
    pass "a failed backup sends no heartbeat (healthchecks.io goes DOWN, as it should)"
else
    fail "failed backup pinged: $(cat "$WORK/curl.log")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ heartbeat_backup: all checks passed\n'
    exit 0
fi
printf '❌ heartbeat_backup: %s check(s) failed\n' "$failures"
exit 1
