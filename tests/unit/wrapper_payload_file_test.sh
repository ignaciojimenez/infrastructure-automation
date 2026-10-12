#!/bin/sh
# enhanced_monitoring_wrapper keeps a Slack payload only when Slack rejects
# it, next to the job's own state file, readable by its owner alone (PER-116).
#
# Runs on the laptop against a stubbed curl; no network.
#
#   tests/unit/wrapper_payload_file_test.sh
#
# The bug this pins (found 2026-10-11 on the workbench): every send wrote the
# payload to /tmp/slack_payload_debug.json first. On a host where two accounts
# run the wrapper, whoever wrote first owned the file and the other was
# refused ("Permission denied", root too, because of fs.protected_regular in
# sticky /tmp). The send still worked, but the file was script output that
# every account could read.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WRAPPER="$REPO_ROOT/scripts/common/enhanced_monitoring_wrapper"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin" "$WORK/state"
STATE="$WORK/state/job.json"
DEBUG="$WORK/state/job.failed_payload.json"
MARK="payload-marker-$$"
OLD=/tmp/slack_payload_debug.json

# curl answers "ok", or rejects the rich payload (the one with attachments)
# the way Slack does ("invalid_payload") and accepts the plain fallback.
cat > "$WORK/bin/curl" <<STUB
#!/bin/sh
case "\$*" in
    *'"attachments"'*) if [ -f "$WORK/reject" ]; then printf invalid_payload; else printf ok; fi ;;
    *) printf ok ;;
esac
STUB
chmod +x "$WORK/bin/curl"
printf '#!/bin/sh\necho "%s"\nexit 1\n' "$MARK" > "$WORK/fails.sh"
chmod +x "$WORK/fails.sh"

# A fingerprint of the old shared path: a write by this run would change it.
# shellcheck disable=SC2012  # ls -ln is the portable way to read owner and mode
old_print() { { ls -ln "$OLD"; cksum < "$OLD"; } 2>/dev/null; }

run() {
    rm -f "$STATE"
    PATH="$WORK/bin:$PATH" "$WRAPPER" --heartbeat-interval=never --state-file="$STATE" \
        TTEST/BTEST/monitor TTEST/BTEST/alert "$WORK/fails.sh" > "$WORK/out" 2>&1
}

printf '\n── Wrapper payload file (PER-116)\n'

before=$(old_print)
run
if [ ! -e "$DEBUG" ] && [ "$(old_print)" = "$before" ] && ! grep -q "$MARK" "$OLD" 2>/dev/null; then
    pass "an accepted send writes the payload nowhere, /tmp included"
else
    fail "accepted send left a payload: $(ls -l "$DEBUG" 2>&1) / /tmp changed: $(old_print)"
fi

touch "$WORK/reject"
before=$(old_print)
run
# shellcheck disable=SC2012  # stat differs between macOS and Linux; ls -ln does not
mode=$(ls -ln "$DEBUG" 2>/dev/null | cut -c1-10)
if [ "$mode" = "-rw-------" ] && grep -q "$MARK" "$DEBUG" && grep -q "Rejected payload saved to $DEBUG" "$WORK/out"; then
    pass "a rejected send keeps the payload beside the state file, 0600, and logs where"
else
    fail "rejected send: mode=[$mode] $(head -c 200 "$DEBUG" 2>&1) / $(grep -i payload "$WORK/out")"
fi
if [ "$(old_print)" = "$before" ] && ! grep -q "$MARK" "$OLD" 2>/dev/null; then
    pass "a rejected send does not touch the old shared /tmp path either"
else
    fail "/tmp/slack_payload_debug.json was written"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ wrapper_payload_file: all checks passed\n'
    exit 0
fi
printf '❌ wrapper_payload_file: %s check(s) failed\n' "$failures"
exit 1
