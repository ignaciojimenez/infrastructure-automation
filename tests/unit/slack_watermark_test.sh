#!/bin/sh
# Regression test: the Slack watch must survive a poll that returns nothing.
#
# Runs on the laptop — no container, no Slack, no network. The template is
# rendered with dummy variables, its embedded Python parser is extracted, and
# it is fed hand-written API responses.
#
#   tests/unit/slack_watermark_test.sh
#
# The bug this pins (2026-08-03): the parser seeded its high-water mark at 0.0
# and printed it unconditionally, so a poll with no new messages reported
# "OK 0.000000". The shell guard meant to catch that compared against the
# *string* "0", which "0.000000" is not, so the watermark file was overwritten
# with zero. Every later poll then sent an oldest Slack rejects, and because
# the watermark is only rewritten after a successful fetch, it could never
# recover. The watch died on its first quiet hour and had almost certainly
# never worked in production.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/investigate.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0

pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── Slack watch watermark\n'

# ------------------------------------------------------------------
# Extract the Slack parser from the template
# ------------------------------------------------------------------
python3 - "$TEMPLATE" "$WORK/parse.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Dummy-render the Jinja placeholders; none of them affect this logic.
src = re.sub(r"\{\{\s*([a-z_0-9]+)\s*\}\}", "0", src)
blocks = re.findall(r"python3 -c '\n(.*?)\n'", src, re.S)
hits = [b for b in blocks if "ERR json" in b]
if len(hits) != 1:
    sys.exit("expected exactly one Slack parser block, found %d" % len(hits))
open(sys.argv[2], "w").write(hits[0])
PY
[ -f "$WORK/parse.py" ] || { printf '   ✗ could not extract the parser\n'; exit 1; }

# Mirrors the helper of the same name in the template. Kept in sync by the
# assertion at the end of this file.
ts_is_positive() {
    awk -v v="${1:-}" 'BEGIN { exit !(v + 0 > 0) }'
}

WATERMARK=1754230021.123456

# ------------------------------------------------------------------
# 1. A quiet poll must hand back the watermark it was given
# ------------------------------------------------------------------
quiet=$(printf '{"ok":true,"messages":[]}' | python3 "$WORK/parse.py" "$WATERMARK" | head -1)
if [ "$quiet" = "OK $WATERMARK" ]; then
    pass "empty poll preserves the watermark ($quiet)"
else
    fail "empty poll returned '$quiet', expected 'OK $WATERMARK'"
fi

# ------------------------------------------------------------------
# 2. ...and the shell guard must refuse to persist a zero, however spelled
# ------------------------------------------------------------------
for bad in "0.000000" "0" "" "junk" "-1"; do
    if ts_is_positive "$bad"; then
        fail "guard would persist '$bad' as a watermark"
    else
        pass "guard rejects '$bad'"
    fi
done

if ts_is_positive "$WATERMARK"; then
    pass "guard accepts a real timestamp"
else
    fail "guard rejected a real timestamp — the watch would never advance"
fi

# ------------------------------------------------------------------
# 3. The working path must be untouched: a real alert is still detected
#    and still advances the watermark.
# ------------------------------------------------------------------
busy=$(printf '{"ok":true,"messages":[{"ts":"1754300000.500000","text":":x: ALERT: cobra disk full"}]}' \
       | python3 "$WORK/parse.py" "$WATERMARK")

if [ "$(printf '%s' "$busy" | head -1)" = "OK 1754300000.500000" ]; then
    pass "a new message advances the watermark"
else
    fail "watermark did not advance: $(printf '%s' "$busy" | head -1)"
fi

if printf '%s' "$busy" | tail -n +2 | grep -q "cobra disk full"; then
    pass "the alert is still surfaced for investigation"
else
    fail "the alert was not surfaced — filtering broke"
fi

# ------------------------------------------------------------------
# 4. Guard against drift between this file's copy of ts_is_positive
#    and the template's.
# ------------------------------------------------------------------
if grep -q 'exit !(v + 0 > 0)' "$TEMPLATE"; then
    pass "template still uses the numeric guard"
else
    fail "template's ts_is_positive changed — update this test to match"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
