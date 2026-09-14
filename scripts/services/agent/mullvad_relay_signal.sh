#!/bin/sh
# mullvad_relay_signal.sh — tell #home-logging when a Mullvad relay that one of
# OPNsense's WireGuard peers points at changes state in Mullvad's own relay list.
#
#   mullvad_relay_signal.sh <slack_webhook_path> <relay_list_file> [state_dir]
#
# relay_list_file: one relay per line, "<hostname> <label>", label optional.
#
# ── Why this exists (docs/TODO.md item 41) ────────────────────────────────────
# Around 2026-09-10 two of the three NL relays behind VLAN 40/80's failover
# group went inactive. The group quietly fell over to the last one — whose exit
# Spotify refuses — and nothing anywhere said so for three days.
#
# ── A SIGNAL, not a check ─────────────────────────────────────────────────────
# A relay being down is Mullvad's business and usually temporary; nothing here
# can fix it, so it must never page. Relay state only ever goes to the logging
# webhook, and this script never exits non-zero because a relay is down. The
# only non-zero exit is a usage error, which is a bug in the deploy.
#
# ── What it will NOT claim ────────────────────────────────────────────────────
# Mullvad's list says `active` and carries `status_messages`; it does not say
# whether an inactive relay is in maintenance or gone for good. So:
#   * "not in Mullvad's relay list" is reported as exactly that — never
#     "retired". On 2026-09-13 NL3's relay was unlisted AND carrying traffic.
#   * "first seen" is when THIS signal first saw the state, not when it began.
#   * From RETIRE_DAYS of inactivity the reminder says retirement is possible,
#     and says outright that this is inferred from duration.
#
# ── It posts on change, never on repetition ───────────────────────────────────
# One message per run at most. A state change posts once; a relay that stays
# inactive or unlisted gets one reminder every REMIND_DAYS. An unreadable API is
# its own state and is reported once, the same way.
#
# 🔴 State advances only after Slack accepted the post. A message that failed to
# send is retried next run instead of being recorded as sent — the exact bug
# that swallowed vinylstreamer's only useful alert on 2026-09-13 (item 40).
#
# No OPNsense API call: this reads Mullvad's public list and nothing else, so
# it needs no new privilege on the read-only key.

set -u

WEBHOOK="${1:-}"
RELAYS="${2:-}"
STATE_ROOT="${3:-${HOME:-/tmp}/.agent}"
CURL="${MULLVAD_SIGNAL_CURL:-curl}"
API="${MULLVAD_SIGNAL_API:-https://api.mullvad.net/www/relays/wireguard/}"
REMIND_DAYS="${MULLVAD_SIGNAL_REMIND_DAYS:-7}"
RETIRE_DAYS="${MULLVAD_SIGNAL_RETIRE_DAYS:-14}"
SERVERS_URL="https://mullvad.net/en/servers"

if [ -z "$WEBHOOK" ] || [ ! -r "$RELAYS" ]; then
    echo "usage: $0 <slack_webhook_path> <relay_list_file> [state_dir]" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 2
fi

NOW="${MULLVAD_SIGNAL_NOW:-$(date -u +%s)}"
SD="$STATE_ROOT/mullvad_relays"
mkdir -p "$SD" || exit 2
WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/next"
: > "$WORK/lines"

# Epoch -> 2026-09-14T08:29:00Z. jq rather than date(1): GNU and BSD date
# disagree on the flag, and the unit tests run on macOS.
iso() { jq -rn --argjson t "$1" '$t | todate'; }

ago() {
    _d=$(( (NOW - $1) / 86400 ))
    if [ "$_d" -lt 1 ]; then echo "under a day"; elif [ "$_d" -eq 1 ]; then echo "1 day"; else echo "$_d days"; fi
}

describe() {
    case "$1" in
        inactive) echo "INACTIVE" ;;
        unlisted) echo "not in Mullvad's relay list" ;;
        broken)   echo "unreadable" ;;
        *)        echo "active" ;;
    esac
}

add() { printf '%s\n' "$1" >> "$WORK/lines"; }

# read_state <file> -> _st _since _lp ("<state> <since_epoch> <last_post_epoch>")
read_state() {
    _st=""; _since=""; _lp=""
    if [ -r "$1" ]; then
        read -r _st _since _lp < "$1"
    fi
}

# Moves this run's staged state into place. Called only once the message (if
# any) has been delivered.
commit() {
    for _f in "$WORK/next"/* "$WORK/next"/.api; do
        [ -e "$_f" ] && mv -f "$_f" "$SD/"
    done
    if [ "$1" = initialise ]; then
        : > "$SD/.initialised"
    fi
}

# deliver <text> <commit-mode>: post, then commit; on a failed post, commit
# nothing so the same message is attempted again next run.
deliver() {
    _payload=$(jq -n --arg text "$1" '{text: $text}')
    if "$CURL" -sS -f -m 15 -X POST -H 'Content-type: application/json' \
        --data "$_payload" "https://hooks.slack.com/services/$WEBHOOK" >/dev/null 2>"$WORK/post.err"; then
        commit "$2"
        echo "posted to Slack"
    else
        echo "Slack post failed ($(tr '\n' ' ' < "$WORK/post.err")); state not advanced, will retry next run"
    fi
}

# ── Mullvad's relay list ──────────────────────────────────────────────────────
api_ok=1
reason=""
if ! "$CURL" -sS -f -m 30 -o "$WORK/relays.json" "$API" 2>"$WORK/curl.err"; then
    api_ok=0
    reason="request failed: $(head -c 160 "$WORK/curl.err" | tr '\n' ' ')"
elif ! jq -e 'type == "array" and length > 0 and (.[0] | has("hostname") and has("active"))' \
        "$WORK/relays.json" >/dev/null 2>&1; then
    api_ok=0
    reason="the response is not Mullvad's relay list"
fi

read_state "$SD/.api"
if [ "$api_ok" -eq 0 ]; then
    if [ "$_st" != broken ]; then
        printf 'broken %s %s\n' "$NOW" "$NOW" > "$WORK/next/.api"
        deliver "⚠️ Mullvad relay signal could not read Mullvad's relay list (${reason}). Relay states are unknown until it recovers — this is the signal failing, not a relay. Check: ${SERVERS_URL}" keep
    elif [ $((NOW - _lp)) -ge $((REMIND_DAYS * 86400)) ]; then
        printf 'broken %s %s\n' "$_since" "$NOW" > "$WORK/next/.api"
        deliver "⚠️ Still: Mullvad relay signal has been unable to read Mullvad's relay list for $(ago "$_since") (since $(iso "$_since")). Latest: ${reason}." keep
    else
        echo "relay list still unreadable (${reason}); already reported"
    fi
    exit 0
fi
if [ "$_st" = broken ]; then
    add "✅ Mullvad relay signal can read Mullvad's relay list again (unreadable for $(ago "$_since"), since $(iso "$_since"))."
fi
if [ "$_st" != ok ]; then
    printf 'ok %s %s\n' "$NOW" "$NOW" > "$WORK/next/.api"
fi

# ── Per relay ─────────────────────────────────────────────────────────────────
fresh=1
[ -e "$SD/.initialised" ] && fresh=0
total=0
unhealthy=0

while read -r host label; do
    case "$host" in ''|'#'*) continue ;; esac
    total=$((total + 1))
    name="$host"
    [ -n "$label" ] && name="$host ($label)"

    state=$(jq -r --arg h "$host" \
        'map(select(.hostname == $h)) | if length == 0 then "unlisted" elif .[0].active then "active" else "inactive" end' \
        "$WORK/relays.json")
    msgs=$(jq -r --arg h "$host" \
        '[.[] | select(.hostname == $h) | (.status_messages // [])[] | "\"\(.message)\" (\(.timestamp))"] | join("; ")' \
        "$WORK/relays.json")

    case "$state" in
        inactive)
            if [ -n "$msgs" ]; then says=" Mullvad says: ${msgs}."; else says=" Mullvad gives no status message."; fi ;;
        unlisted)
            says=" With no entry, Mullvad gives no status message for it." ;;
        *)
            says="" ;;
    esac
    [ "$state" != active ] && unhealthy=$((unhealthy + 1))

    read_state "$SD/$host"

    if [ "$fresh" -eq 1 ]; then
        printf '%s %s %s\n' "$state" "$NOW" "$NOW" > "$WORK/next/$host"
        if [ "$state" != active ]; then
            add "• ${name} is $(describe "$state") (first seen $(iso "$NOW")).${says}"
        fi
        continue
    fi

    # A relay added to the list after the first run: nothing to compare with,
    # so treat its previous state as healthy — silent if it is, a change if not.
    if [ -z "$_st" ]; then
        _st=active; _since=$NOW; _lp=$NOW
    fi

    if [ "$state" != "$_st" ]; then
        printf '%s %s %s\n' "$state" "$NOW" "$NOW" > "$WORK/next/$host"
        if [ "$state" = active ]; then
            add "✅ Mullvad relay ${name} is active again (was $(describe "$_st") for $(ago "$_since"), first seen $(iso "$_since"))."
        else
            add "🛈 Mullvad relay ${name} is $(describe "$state") (first seen $(iso "$NOW")).${says}"
        fi
    elif [ "$state" != active ] && [ $((NOW - _lp)) -ge $((REMIND_DAYS * 86400)) ]; then
        days=$(( (NOW - _since) / 86400 ))
        line="🛈 Still: Mullvad relay ${name} is $(describe "$state") — $(ago "$_since") since first seen ($(iso "$_since")).${says}"
        if [ "$days" -ge "$RETIRE_DAYS" ]; then
            line="${line} After ${days} days this may mean the relay has been retired — an inference from how long it has lasted, not something Mullvad states."
        fi
        add "$line"
        printf '%s %s %s\n' "$state" "$_since" "$NOW" > "$WORK/next/$host"
    fi
done < "$RELAYS"

echo "checked ${total} relays: ${unhealthy} not active"

mode=keep
[ "$fresh" -eq 1 ] && mode=initialise

if [ ! -s "$WORK/lines" ]; then
    commit "$mode"
    exit 0
fi

if [ "$fresh" -eq 1 ] && [ "$unhealthy" -gt 0 ]; then
    text="🛈 Mullvad relay signal is now watching the ${total} relays OPNsense's WireGuard peers use. ${unhealthy} of them are not healthy in Mullvad's relay list:
$(cat "$WORK/lines")
Check: ${SERVERS_URL}"
else
    text="$(cat "$WORK/lines")
Check: ${SERVERS_URL}"
fi

deliver "$text" "$mode"
exit 0
