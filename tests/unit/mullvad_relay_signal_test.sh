#!/bin/sh
# Regression test: mullvad_relay_signal.sh must report a Mullvad relay's state
# changes exactly once — to #home-alerts — keep reminders and its own API
# trouble in #home-logging, quote Mullvad's own status message, never claim a
# relay is retired, and never fail because a relay is down.
#
# Runs on the laptop — no network. `curl` is stubbed: Mullvad's relay list comes
# from a fixture, and each Slack post is captured with the channel it hit (the
# alert and logging webhooks are different stub paths).
#
#   tests/unit/mullvad_relay_signal_test.sh        # script under sh
#   dash tests/unit/mullvad_relay_signal_test.sh dash   # script under dash
#
# MULLVAD_SIGNAL_TEST_SCRIPT points it at another copy of the script, e.g. an
# older revision, to show which assertions that revision fails.
#
# The case that matters most is D: an unreadable API is reported ONCE and does
# not disturb the relay states, so its recovery does not replay stale changes.
# And E: a post Slack refused is retried — per channel — not recorded as sent
# (item 40).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="${MULLVAD_SIGNAL_TEST_SCRIPT:-$REPO_ROOT/scripts/services/agent/mullvad_relay_signal.sh}"
SH="${1:-sh}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── mullvad_relay_signal.sh (%s)\n' "$SH"

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '   ✗ jq required to run this test\n'; exit 1; }

mkdir -p "$WORK/bin"
S="$WORK/sim"
HOOK_LOG="T000/B000/log"
HOOK_ALERT="T000/B000/alert"

cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
S="$S"
out=""; data=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        --data) data="\$2"; shift ;;
        -H|-m|-X) shift ;;
        -*) ;;
        *) url="\$1" ;;
    esac
    shift
done
case "\$url" in
    *hooks.slack.com*/alert) chan=alert ;;
    *hooks.slack.com*)       chan=log ;;
    *)                       chan="" ;;
esac
if [ -n "\$chan" ]; then
    if [ -e "\$S/slack_fail_\$chan" ]; then echo "curl: (22) 500" >&2; exit 22; fi
    n=\$(ls "\$S/posts" | wc -l | tr -d ' '); n=\$((n + 1))
    printf '%s' "\$data" | jq -r .text > "\$S/posts/\$n"
    echo "\$chan" > "\$S/chans/\$n"
    exit 0
fi
case "\$(cat "\$S/api_mode")" in
    down)    echo "curl: (7) Failed to connect" >&2; exit 7 ;;
    garbage) printf '<html>maintenance</html>' > "\$out"; exit 0 ;;
    *)       cp "\$S/api.json" "\$out"; exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/curl"

reset_state() {
    rm -rf "$S"; mkdir -p "$S/posts" "$S/chans" "$S/state"
    printf '%s\n' "nl-ams-wg-001 NL1, wg0" "nl-ams-wg-002 NL2, wg2" "nl-ams-wg-101 NL3, wg3" "# comment" "" "gb-lon-wg-001" > "$S/relays.list"
}

# api <host=state[=message]>... — anything "unlisted" is left out of the list.
api() {
    printf '[{"hostname":"se-got-wg-001","active":true,"status_messages":[]}]' > "$S/api.json"
    for spec in "$@"; do
        h=${spec%%=*}; rest=${spec#*=}; st=${rest%%=*}; msg=""
        case "$rest" in *=*) msg=${rest#*=} ;; esac
        [ "$st" = unlisted ] && continue
        act=false; [ "$st" = active ] && act=true
        jq --arg h "$h" --argjson a "$act" --arg m "$msg" \
            '. + [{hostname: $h, active: $a, status_messages: (if $m == "" then [] else [{message: $m, timestamp: "2026-09-13T09:28:08+00:00"}] end)}]' \
            "$S/api.json" > "$S/api.tmp" && mv "$S/api.tmp" "$S/api.json"
    done
    echo ok > "$S/api_mode"
}

# run <now> — as the cron calls it: logging webhook first, alert webhook last.
run() {
    OUT=$(MULLVAD_SIGNAL_CURL="$WORK/bin/curl" MULLVAD_SIGNAL_NOW="$1" \
          "$SH" "$SCRIPT" "$HOOK_LOG" "$S/relays.list" "$S/state" "$HOOK_ALERT" 2>&1)
    RC=$?
}

# run_without_alert_hook <now> — a cron line written before the alert channel.
run_without_alert_hook() {
    OUT=$(MULLVAD_SIGNAL_CURL="$WORK/bin/curl" MULLVAD_SIGNAL_NOW="$1" \
          "$SH" "$SCRIPT" "$HOOK_LOG" "$S/relays.list" "$S/state" 2>&1)
    RC=$?
}

posts() { find "$S/posts" -type f | wc -l | tr -d ' '; }
last() { cat "$S/posts/$(posts)" 2>/dev/null; }
last_chan() { cat "$S/chans/$(posts)" 2>/dev/null; }

expect_rc() {
    if [ "$RC" = "$1" ]; then pass "$2 (exit $RC)"; else fail "$2 — expected exit $1, got $RC: $OUT"; fi
}
expect_posts() {
    if [ "$(posts)" = "$1" ]; then pass "$2"; else fail "$2 — expected $1 post(s), got $(posts). Last: $(last)"; fi
}
expect_last() {
    if last | grep -qF -- "$1"; then pass "$2"; else fail "$2 — last post lacks: $1 | $(last)"; fi
}
expect_last_not() {
    if last | grep -qF -- "$1"; then fail "$2 — last post unexpectedly contains: $1"; else pass "$2"; fi
}
expect_chan() {
    if [ "$(last_chan)" = "$1" ]; then pass "$2"; else fail "$2 — expected the $1 webhook, last post went to: $(last_chan)"; fi
}

DAY=86400
T0=1789400000

# ── A. First run on a fresh box: ONE summary of what is unhealthy ────────────
reset_state
api nl-ams-wg-001=inactive nl-ams-wg-002=inactive nl-ams-wg-101=unlisted gb-lon-wg-001=active
run $T0
expect_rc 0 "first run with three unhealthy relays"
expect_posts 1 "first run posts one summary, not one message per relay"
expect_chan alert "first-run summary goes to #home-alerts"
expect_last "needs attention" "summary is worded as needing attention"
expect_last "now watching the 4 relays" "summary counts the relays watched"
expect_last "3 of them are not healthy" "summary counts the unhealthy ones"
expect_last "nl-ams-wg-001 (NL1, wg0) is INACTIVE" "summary names an inactive relay with its tunnel label"
expect_last "nl-ams-wg-101 (NL3, wg3) is not in Mullvad's relay list" "summary words an unlisted relay as unlisted"
expect_last "Check: https://mullvad.net/en/servers" "summary says where to check"
expect_last_not "gb-lon-wg-001" "a healthy relay is not in the summary"
expect_last_not "retired" "nothing is claimed retired"
expect_last_not "Script Failed" "not formatted as a script failure"

run $((T0 + 3600))
expect_rc 0 "second run, nothing changed"
expect_posts 1 "no repeat post on unchanged state"

# ── B. Changes after a healthy first run: every one to #home-alerts ──────────
reset_state
api nl-ams-wg-001=active nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run $T0
expect_posts 0 "healthy first run posts nothing"

api "nl-ams-wg-001=inactive=xTom servers in LAX will be moved." nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run $((T0 + 3600))
expect_rc 0 "active -> inactive"
expect_posts 1 "a change posts once"
expect_chan alert "active -> inactive goes to #home-alerts"
expect_last "Mullvad relay nl-ams-wg-001 (NL1, wg0) is INACTIVE — needs attention" "names the relay and says it needs attention"
expect_last "Mullvad says: \"xTom servers in LAX will be moved.\" (2026-09-13T09:28:08+00:00)" "quotes Mullvad's status message and its timestamp"
expect_last "Check: https://mullvad.net/en/servers" "change says where to check"

TB3=$((T0 + 7200))
api "nl-ams-wg-001=inactive=xTom servers in LAX will be moved." nl-ams-wg-002=inactive nl-ams-wg-101=active gb-lon-wg-001=active
run $TB3
expect_posts 2 "second relay going inactive posts"
expect_chan alert "second relay going inactive goes to #home-alerts"
expect_last "nl-ams-wg-002 (NL2, wg2) is INACTIVE" "names the second relay"
expect_last "Mullvad gives no status message." "says so when Mullvad gives no message"
expect_last_not "nl-ams-wg-001" "does not repeat the relay already reported"

api "nl-ams-wg-001=inactive=xTom servers in LAX will be moved." nl-ams-wg-002=inactive nl-ams-wg-101=unlisted gb-lon-wg-001=active
run $((TB3 + 3600))
expect_posts 3 "relay leaving the list posts"
expect_chan alert "relay leaving the list goes to #home-alerts"
expect_last "nl-ams-wg-101 (NL3, wg3) is not in Mullvad's relay list" "unlisted is its own wording"
expect_last_not "retired" "unlisted is not called retired"

api "nl-ams-wg-001=inactive=xTom servers in LAX will be moved." nl-ams-wg-002=inactive nl-ams-wg-101=unlisted gb-lon-wg-001=inactive
run $((TB3 + 7200))
expect_posts 4 "unlabelled relay going inactive posts"
expect_last "Mullvad relay gb-lon-wg-001 is INACTIVE" "a relay without a verified tunnel label is named by hostname only"

api nl-ams-wg-001=active nl-ams-wg-002=inactive nl-ams-wg-101=unlisted gb-lon-wg-001=inactive
run $((TB3 + 10800))
expect_rc 0 "inactive -> active"
expect_posts 5 "recovery posts once"
expect_chan alert "recovery goes to #home-alerts"
expect_last "Mullvad relay nl-ams-wg-001 (NL1, wg0) is back: active again" "recovery says the relay is back"

run $((TB3 + 14400))
expect_posts 5 "no repeat post after a recovery"

# ── C. Reminders: #home-logging, 7 days, retirement only as an inference ─────
run $((TB3 + 6 * DAY))
expect_posts 5 "no reminder before 7 days"

run $((TB3 + 7 * DAY))
expect_posts 6 "7-day reminder posts"
expect_chan log "7-day reminder goes to #home-logging, not #home-alerts"
expect_last "Still: Mullvad relay nl-ams-wg-002 (NL2, wg2) is INACTIVE — 7 days" "reminder gives the duration"
expect_last_not "retired" "no retirement wording before 14 days"

# +30 min, not +1 h: at +1 h relay 101 (first seen TB3 + 1 h) is owed its own
# 7-day reminder, which is correct and would muddy what this case pins.
run $((TB3 + 7 * DAY + 1800))
expect_posts 6 "reminder is not repeated within the week"

run $((TB3 + 14 * DAY))
expect_posts 7 "14-day reminder posts"
expect_chan log "14-day reminder goes to #home-logging, not #home-alerts"
expect_last "may mean the relay has been retired" "from 14 days, says retirement is possible"
expect_last "an inference from how long it has lasted, not something Mullvad states" "and says it is inferred, not stated"

# ── D. Unreadable API: #home-logging, once, relay states untouched ───────────
reset_state
api nl-ams-wg-001=active nl-ams-wg-002=inactive nl-ams-wg-101=active gb-lon-wg-001=active
run $T0
expect_posts 1 "setup: first run reports the inactive relay"

echo down > "$S/api_mode"
run $((T0 + 3600))
expect_rc 0 "API down does not fail the run"
expect_posts 2 "API down is reported"
expect_chan log "API down goes to #home-logging — it is the signal failing, not a relay"
expect_last "could not read Mullvad's relay list" "says the list could not be read"
expect_last "this is the signal failing, not a relay" "does not blame a relay"

run $((T0 + 7200))
expect_rc 0 "API still down"
expect_posts 2 "API down is reported once, not every run"

echo garbage > "$S/api_mode"
run $((T0 + 10800))
expect_rc 0 "garbage response does not fail the run"
expect_posts 2 "garbage while already unreadable is not a new report"

echo ok > "$S/api_mode"
run $((T0 + 14400))
expect_posts 3 "API recovery posts"
expect_chan log "API recovery goes to #home-logging"
expect_last "can read Mullvad's relay list again" "says the list is readable again"
expect_last_not "nl-ams-wg-002" "no stale relay change is replayed after the outage"

echo garbage > "$S/api_mode"
run $((T0 + 18000))
expect_rc 0 "garbage JSON from a healthy state"
expect_posts 4 "garbage JSON is reported"
expect_last "the response is not Mullvad's relay list" "names why it is unreadable"

# ── E. A post Slack refused is retried, per channel ──────────────────────────
reset_state
api nl-ams-wg-001=active nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run $T0
touch "$S/slack_fail_alert"
api nl-ams-wg-001=inactive nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run $((T0 + 3600))
expect_rc 0 "a failed Slack post does not fail the run"
expect_posts 0 "nothing delivered while Slack refuses"
if printf '%s' "$OUT" | grep -qF "state not advanced"; then pass "says the state was not advanced"; else fail "no 'state not advanced' in: $OUT"; fi
rm -f "$S/slack_fail_alert"
run $((T0 + 7200))
expect_posts 1 "the undelivered change is retried next run"
expect_chan alert "the retried change still goes to #home-alerts"
expect_last "nl-ams-wg-001 (NL1, wg0) is INACTIVE" "the retried post is the original change"

# A reminder and a change in the same run, with only #home-alerts refusing: the
# reminder lands once, and the change is retried without re-sending it.
TE=$((T0 + 7200 + 7 * DAY))
touch "$S/slack_fail_alert"
api nl-ams-wg-001=inactive nl-ams-wg-002=inactive nl-ams-wg-101=active gb-lon-wg-001=active
run $TE
expect_rc 0 "mixed run with #home-alerts refusing"
expect_posts 2 "the reminder is delivered although the alert was refused"
expect_chan log "the delivered post is the #home-logging reminder"
expect_last "Still: Mullvad relay nl-ams-wg-001" "that post is nl-ams-wg-001's reminder"
rm -f "$S/slack_fail_alert"
run $((TE + 3600))
expect_posts 3 "the refused change is retried next run"
expect_chan alert "the retried change goes to #home-alerts"
expect_last "nl-ams-wg-002 (NL2, wg2) is INACTIVE — needs attention" "it is nl-ams-wg-002's change"
run $((TE + 7200))
expect_posts 3 "neither the reminder nor the change is sent twice"

# ── F. A cron line without the alert webhook still works ─────────────────────
reset_state
api nl-ams-wg-001=active nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run_without_alert_hook $T0
api nl-ams-wg-001=inactive nl-ams-wg-002=active nl-ams-wg-101=active gb-lon-wg-001=active
run_without_alert_hook $((T0 + 3600))
expect_rc 0 "old three-argument cron line"
expect_posts 1 "a change is still posted without an alert webhook"
expect_chan log "with no alert webhook it falls back to #home-logging"

# ── G. Usage errors are the only non-zero exit ───────────────────────────────
OUT=$(MULLVAD_SIGNAL_CURL="$WORK/bin/curl" "$SH" "$SCRIPT" "" 2>&1); RC=$?
expect_rc 2 "missing arguments"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   All checks passed.\n\n'
    exit 0
fi
printf '   %d check(s) failed.\n\n' "$failures"
exit 1
