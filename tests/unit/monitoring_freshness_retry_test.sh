#!/bin/sh
# Regression test: one failed healthchecks.io lookup must not become a finding.
#
# Runs on the laptop — no container, no network. The function under test is cut
# out of the rendered-free template and driven against a stubbed `curl`.
#
#   tests/unit/monitoring_freshness_retry_test.sh
#
# PER-146: the sweep reported "monitoring freshness UNKNOWN ... curl exit 6" (a
# single DNS failure), and the very next check ~15 minutes later resolved fine.
# A ticket for a blip that clears itself is noise. Transport failures are now
# retried; a PERSISTENT failure must still be reported, so both are pinned.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/fleet_health_check.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── healthchecks.io freshness read retries transport failures\n'

if ! command -v jq >/dev/null 2>&1; then
    printf '   - jq not installed; skipping\n\nPASS\n'
    exit 0
fi

mkdir -p "$WORK/bin"

# The function parses last_ping with GNU `date -d` (agent-lxc is Debian). On
# the laptop BSD date has no -d, so put coreutils' gdate first on PATH.
if ! date -d @0 >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
        ln -s "$(command -v gdate)" "$WORK/bin/date"
    else
        printf '   - no GNU date (brew install coreutils); skipping\n\nPASS\n'
        exit 0
    fi
fi

# The function body only; it has no template syntax inside it.
sed -n '/^check_opnsense_monitoring_alive() {/,/^}/p' "$TEMPLATE" > "$WORK/func.sh"
if [ ! -s "$WORK/func.sh" ]; then
    fail "could not extract check_opnsense_monitoring_alive from the template"
    printf '\nFAIL (%s)\n' "$failures"
    exit 1
fi

# Fails with $CURL_FAIL_RC for the first $CURL_FAILS calls, then answers 200.
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out=$2; shift ;; esac
    shift
done
cat >/dev/null
n=$(cat "$CALLS" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$CALLS"
if [ "$n" -le "$CURL_FAILS" ]; then
    exit "${CURL_FAIL_RC:-6}"
fi
printf '{"checks":[{"name":"OPNsense monitoring alive","status":"up","last_ping":"%s"}]}' \
    "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$out"
printf 200
STUB
chmod +x "$WORK/bin/curl"

CALLS="$WORK/calls"
export CALLS
PATH="$WORK/bin:$PATH"
export PATH

# The variables and stubs below are read by the sourced function, which the
# linter cannot follow.
# shellcheck disable=SC2034,SC2329
run() {
    # run <fails-before-success>
    CURL_FAILS=$1
    export CURL_FAILS
    echo 0 > "$CALLS"
    (
        NOTES="$WORK/notes"
        : > "$NOTES"
        API_OUT="$WORK/api.json"
        HEALTHCHECKS_API_KEY_FILE="$WORK/creds"
        HEALTHCHECKS_CHECK_NAME="OPNsense monitoring alive"
        HEALTHCHECKS_RETRY_DELAY=0
        OPNSENSE_API_TIMEOUT=5
        WRAPPER_MAX_AGE_HOURS=26
        printf 'api_key=abc\n' > "$HEALTHCHECKS_API_KEY_FILE"
        note() { printf '%s: %s\n' "$1" "$2" >> "$NOTES"; }
        is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
        . "$WORK/func.sh"
        check_opnsense_monitoring_alive opnsense
    )
}

run 1
if [ ! -s "$WORK/notes" ]; then
    pass "a single DNS failure (curl exit 6) is absorbed by a retry"
else
    fail "one transient failure still produced a finding: $(cat "$WORK/notes")"
fi

run 2
if [ ! -s "$WORK/notes" ]; then
    pass "two failures in a row still recover on the third attempt"
else
    fail "two transient failures produced a finding: $(cat "$WORK/notes")"
fi

run 99
if grep -q 'monitoring freshness UNKNOWN.*curl exit 6' "$WORK/notes"; then
    pass "a persistent failure is still reported as UNKNOWN"
else
    fail "persistent failure was swallowed: $(cat "$WORK/notes")"
fi
if [ "$(cat "$CALLS")" = "3" ]; then
    pass "retries are bounded at three attempts"
else
    fail "expected 3 attempts, saw $(cat "$CALLS")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
