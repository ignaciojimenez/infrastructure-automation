#!/bin/sh
# authorized_keys_sync and its validator, forced through every guardrail (PER-182).
#
#   tests/unit/authorized_keys_sync_test.sh
#   SH=dash tests/unit/authorized_keys_sync_test.sh
#
# Runs on the laptop with real keys from ssh-keygen and a curl stub that serves
# a "gist" file and records Slack posts. It proves the decisions; the test
# container proves the deploy, the timer and the real fetch (docs/archive/DONE.md).
#
# What it pins:
#   - a new key and a removed key each change the file and post their
#     fingerprints; a re-run with no change writes nothing and posts nothing
#   - the same keys in Ansible's layout are not a change (no write fight)
#   - a failed fetch, an empty list and a malformed list leave the file
#     untouched and fail the unit; each distinct refusal alerts once
#   - KEEP_KEY cannot rescue an empty list; a failed Slack post fails the unit

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SYNC="$REPO_ROOT/scripts/ssh/authorized_keys_sync"
VALIDATOR="$REPO_ROOT/scripts/ssh/authorized_keys_validate"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin" "$WORK/home/.ssh" "$WORK/state" "$WORK/keys"
for k in a b keep; do
    ssh-keygen -q -t ed25519 -N '' -C "key-$k" -f "$WORK/keys/$k" || exit 1
done
fp() { ssh-keygen -lf "$WORK/keys/$1.pub" | cut -d' ' -f2; }
A=$(cat "$WORK/keys/a.pub")
B=$(cat "$WORK/keys/b.pub")
KEEP=$(cat "$WORK/keys/keep.pub")

# curl: a Slack post (any --data) is appended to slack.log and answered "ok",
# or "invalid_token" when $WORK/slack_fail exists. Anything else is the gist
# fetch: copies $WORK/gist to the -o path, or times out when $WORK/fetch_fail
# exists.
cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
out="" data=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out=\$2; shift ;;
        --data) data=\$2; shift ;;
    esac
    shift
done
if [ -n "\$data" ]; then
    printf '%s\n' "\$data" >> "$WORK/slack.log"
    if [ -f "$WORK/slack_fail" ]; then printf 'invalid_token'; else printf 'ok'; fi
    exit 0
fi
if [ -f "$WORK/fetch_fail" ]; then
    echo "curl: (28) Operation timed out" >&2
    exit 28
fi
cp "$WORK/gist" "\$out"
EOF
chmod +x "$WORK/bin/curl"

AK="$WORK/home/.ssh/authorized_keys"
run() {
    : > "$WORK/slack.log"
    PATH="$WORK/bin:$PATH" HOME="$WORK/home" STATE_DIRECTORY="$WORK/state" \
        KEYS_URL="https://gist.invalid/keys" SLACK_WEBHOOK="https://slack.invalid/hook" \
        VALIDATOR="$VALIDATOR" KEEP_KEY="${KEEP_KEY:-}" \
        "$SH" "$SYNC" > "$WORK/out" 2> "$WORK/err"
    RC=$?
}
posts() { grep -c . "$WORK/slack.log"; }
snapshot() { cp "$AK" "$WORK/before"; }
untouched() { cmp -s "$AK" "$WORK/before"; }

printf '\n── authorized_keys_sync (PER-182)\n'

# A new key in the gist.
printf '%s\n' "$A" > "$AK"
printf '%s\n%s\n' "$A" "$B" > "$WORK/gist"
run
if [ "$RC" -eq 0 ] && grep -qF "$B" "$AK" && grep -qF "$A" "$AK" \
        && [ "$(posts)" -eq 1 ] && grep -q "+1 -0" "$WORK/slack.log" \
        && grep -qF "$(fp b)" "$WORK/slack.log"; then
    pass "a key added to the gist is written and its fingerprint posted"
else
    fail "add: rc=$RC err=$(cat "$WORK/err") slack=$(cat "$WORK/slack.log")"
fi
exact_600=$(find "$AK" -perm 600 | wc -l | tr -d ' ')
leftover=$(find "$WORK/home/.ssh" -name '.authorized_keys.*' | wc -l | tr -d ' ')
if [ "$exact_600" -eq 1 ] && [ "$leftover" -eq 0 ]; then
    pass "the file is 0600 and no temp file is left behind"
else
    fail "mode not 0600 or temp left: exact_600=$exact_600 leftover=$leftover"
fi

# Nothing changed.
snapshot
run
if [ "$RC" -eq 0 ] && untouched && [ "$(posts)" -eq 0 ]; then
    pass "an unchanged gist writes nothing and posts nothing"
else
    fail "no-op: rc=$RC slack=$(cat "$WORK/slack.log")"
fi

# The same keys in another layout: reverse order, a blank line, trailing
# spaces, and one comment dropped, as Ansible's authorized_key module writes a
# key with no comment ("type blob \n"). None of that is a change of access.
printf '%s  \n\n%s \n' "$B" "$(printf '%s' "$A" | cut -d' ' -f1-2)" > "$AK"
snapshot
run
if [ "$RC" -eq 0 ] && untouched && [ "$(posts)" -eq 0 ]; then
    pass "the same key set in another layout is not a change (no fight with Ansible)"
else
    fail "layout: rc=$RC slack=$(cat "$WORK/slack.log")"
fi

# A key removed from the gist.
printf '# comment\r\n  %s\r\n\r\n' "$A" > "$WORK/gist"
run
if [ "$RC" -eq 0 ] && ! grep -qF "$B" "$AK" && [ "$(cat "$AK")" = "$A" ] \
        && grep -q "+0 -1" "$WORK/slack.log" && grep -qF "$(fp b)" "$WORK/slack.log"; then
    pass "a key removed from the gist disappears and its fingerprint is posted (CRLF and comments tolerated)"
else
    fail "remove: rc=$RC file=$(cat "$AK") slack=$(cat "$WORK/slack.log")"
fi

# Fetch fails.
snapshot
touch "$WORK/fetch_fail"
run
rm -f "$WORK/fetch_fail"
if [ "$RC" -ne 0 ] && untouched && [ "$(posts)" -eq 0 ] && grep -q "fetch failed" "$WORK/err"; then
    pass "a failed fetch leaves the file untouched and fails the unit"
else
    fail "fetch fail: rc=$RC err=$(cat "$WORK/err")"
fi

# Empty list: refused and alerted, once.
: > "$WORK/gist"
run
if [ "$RC" -ne 0 ] && untouched && [ "$(posts)" -eq 1 ] \
        && grep -q "REFUSED" "$WORK/slack.log" && grep -q "no keys" "$WORK/slack.log"; then
    pass "an empty list is refused, file untouched, refusal posted"
else
    fail "empty: rc=$RC slack=$(cat "$WORK/slack.log") err=$(cat "$WORK/err")"
fi
run
if [ "$RC" -ne 0 ] && untouched && [ "$(posts)" -eq 0 ] && grep -q "already alerted" "$WORK/err"; then
    pass "the same refused list does not alert again, and still fails the unit"
else
    fail "repeat refusal: rc=$RC slack=$(cat "$WORK/slack.log")"
fi

# Malformed: a different refusal, so it alerts. Options before the key are
# refused too, as the Jinja assert this replaces refused them.
printf '%s\nnot a key\n' "$A" > "$WORK/gist"
run
if [ "$RC" -ne 0 ] && untouched && [ "$(posts)" -eq 1 ] \
        && grep -q "line 2 is not a public key" "$WORK/slack.log"; then
    pass "a malformed list is refused with its line number, file untouched, posted"
else
    fail "malformed: rc=$RC slack=$(cat "$WORK/slack.log")"
fi
printf 'no-pty %s\n' "$A" > "$WORK/gist"
run
if [ "$RC" -ne 0 ] && untouched && [ "$(posts)" -eq 1 ]; then
    pass "a key line with options is refused"
else
    fail "options: rc=$RC"
fi

# KEEP_KEY cannot turn an empty list into a valid one...
: > "$WORK/gist"
KEEP_KEY="$KEEP" run
if [ "$RC" -ne 0 ] && untouched; then
    pass "KEEP_KEY does not rescue an empty list"
else
    fail "keep+empty: rc=$RC file=$(cat "$AK")"
fi
# ...and is kept alongside a good one.
printf '%s\n' "$A" > "$WORK/gist"
KEEP_KEY="$KEEP" run
if [ "$RC" -eq 0 ] && grep -qF "$A" "$AK" && grep -qF "$KEEP" "$AK" && [ ! -e "$WORK/state/refused" ]; then
    pass "KEEP_KEY is kept alongside the gist, and a good list clears the refusal state"
else
    fail "keep: rc=$RC file=$(cat "$AK")"
fi

# A change whose Slack post fails: the change stands, the unit fails.
printf '%s\n%s\n' "$A" "$B" > "$WORK/gist"
touch "$WORK/slack_fail"
run
rm -f "$WORK/slack_fail"
if [ "$RC" -ne 0 ] && grep -qF "$B" "$AK" && grep -q "Slack post failed: invalid_token" "$WORK/err"; then
    pass "a failed Slack post fails the unit (the write still stands)"
else
    fail "slack fail: rc=$RC err=$(cat "$WORK/err")"
fi

# A comment carrying JSON metacharacters still makes a valid payload.
ssh-keygen -q -t ed25519 -N '' -C 'evil "quote" \back' -f "$WORK/keys/evil" || exit 1
cat "$WORK/keys/evil.pub" > "$WORK/gist"
run
if [ "$RC" -eq 0 ] && python3 -c 'import json,sys; json.loads(open(sys.argv[1]).readline())' "$WORK/slack.log" 2>/dev/null; then
    pass "a key comment with quotes and backslashes still posts valid JSON"
else
    fail "json: rc=$RC payload=$(cat "$WORK/slack.log")"
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s failure(s)\n' "$failures"
    exit 1
fi
