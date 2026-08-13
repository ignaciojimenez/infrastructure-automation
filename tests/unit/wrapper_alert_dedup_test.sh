#!/bin/sh
# Regression test: enhanced_monitoring_wrapper must stop re-paging an UNCHANGED
# failure, without ever going quiet about a changed one.
#
# Runs on the laptop — no container, no fleet, no network, no spend. The real
# wrapper is executed against a stubbed `curl`, so what is asserted is the
# Slack payload it would actually have sent.
#
#   tests/unit/wrapper_alert_dedup_test.sh
#
# The bug this pins (measured 2026-08-13): the failure branch was
#
#     # Always notify on failures
#     if [ "$CURRENT_STATUS" = "failure" ]; then
#       SEND_TO_ALERT=true
#
# with no cooldown and no dedup, so the page rate was cron's schedule rather
# than anything about the fault. #home-alerts held `ALERT: Script Failed on
# agent-lxc` at :37 of *every hour for 24 hours*, all the same opnsense
# finding. On opnsense, where checks run every 1–5 minutes, one stuck fault is
# worth up to 288 pages a day.
#
# ⚠️ The point is not that alerts got quieter. A check that says nothing is
# also quiet, and this repo has shipped that mistake before. Suppression is
# only a fix if it cannot swallow news, so the cases below are weighted toward
# what must STILL fire:
#
#   * changed failure inside the cooldown  → must alert (case 3)
#   * cap reached                          → must alert again (case 5)
#   * corrupt / absent state               → must alert (cases 6, 7)
#   * recovery after suppression           → must still post (case 8)
#
# Only cases 2 and 4 assert silence, and both are the same fault repeating
# with time left on the clock.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WRAPPER="$REPO_ROOT/scripts/common/enhanced_monitoring_wrapper"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

BIN="$WORK/bin"
STATE="$WORK/state.json"
SENT="$WORK/sent.log"
mkdir -p "$BIN"

MON_HOOK="TTEST0000/BTEST0000/monitortoken0000"
ALERT_HOOK="TTEST0000/BTEST0000/alerttoken00000"

printf '\n── Wrapper failure-alert dedup\n'

# ------------------------------------------------------------------
# Stub the one command that reaches outside this machine.
#
# The stub records the payload rather than a bare "curl ran", because every
# assertion below is about WHICH message would have been posted — a repeat
# reminder and a first page are both alerts, and telling them apart is most of
# the behaviour under test. It answers "ok" so the wrapper takes its success
# path and never tries the fallback payload.
# ------------------------------------------------------------------
cat > "$BIN/curl" <<STUB
#!/bin/sh
payload=""
url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --data) payload="\$2"; shift 2 ;;
        http*)  url="\$1"; shift ;;
        *)      shift ;;
    esac
done
case "\$url" in
    *alerttoken*) channel=ALERT ;;
    *)            channel=MONITOR ;;
esac
printf '%s\t%s\n' "\$channel" "\$payload" >> "$SENT"
printf 'ok'
STUB
chmod +x "$BIN/curl"

PATH="$BIN:$PATH"
export PATH

# ------------------------------------------------------------------
# Scripts under the wrapper. Failure output is fixed per fault so the
# signature is stable, exactly as the Tier 1 sweep's output is in production.
# ------------------------------------------------------------------
cat > "$WORK/fault_a.sh" <<'EOF'
#!/bin/sh
echo "Fleet check found 1 issue(s) across 7 hosts:"
echo "opnsense: UNREACHABLE (no response as read_agent)"
exit 1
EOF
cat > "$WORK/fault_b.sh" <<'EOF'
#!/bin/sh
echo "Fleet check found 2 issue(s) across 7 hosts:"
echo "opnsense: UNREACHABLE (no response as read_agent)"
echo "cobra: 1 failed systemd unit(s): nmbd.service"
exit 1
EOF
cat > "$WORK/ok.sh" <<'EOF'
#!/bin/sh
echo "Fleet OK — 7/7 hosts reachable, no findings"
exit 0
EOF
chmod +x "$WORK/fault_a.sh" "$WORK/fault_b.sh" "$WORK/ok.sh"

run() {
    # run <script> [extra wrapper opts...]
    _script="$1"; shift
    : > "$SENT"
    "$WRAPPER" --heartbeat-interval=never --state-file="$STATE" "$@" \
        "$MON_HOOK" "$ALERT_HOOK" "$_script" >/dev/null 2>&1
    return 0
}

# `grep -c` prints 0 AND exits 1 on no match, so the obvious `|| echo 0`
# appends a second zero and every numeric comparison below dies on "0\n0".
_count() { _n=$(grep -c "$1" "$SENT" 2>/dev/null); [ -n "$_n" ] || _n=0; echo "$_n"; }
alerts()   { _count '^ALERT'; }
monitors() { _count '^MONITOR'; }
sent_has() { grep -q "$1" "$SENT" 2>/dev/null; }

# ------------------------------------------------------------------
# 1. First failure always pages.
# ------------------------------------------------------------------
rm -f "$STATE"
run "$WORK/fault_a.sh"
if [ "$(alerts)" -eq 1 ] && sent_has 'ALERT: Script Failed'; then
    pass "first failure alerts, titled as a new fault"
else
    fail "first failure did not alert (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 2. Same failure, inside the cooldown → silence. This is the 24-pages-a-day
#    case, and the only kind of silence this change is allowed to introduce.
# ------------------------------------------------------------------
run "$WORK/fault_a.sh"
if [ "$(alerts)" -eq 0 ]; then
    pass "unchanged failure inside the cooldown is suppressed"
else
    fail "unchanged failure still paged (alerts=$(alerts))"
fi

# Four more runs, standing in for four more hourly sweeps.
for _ in 1 2 3 4; do run "$WORK/fault_a.sh"; done
if [ "$(alerts)" -eq 0 ]; then
    pass "six consecutive identical failures produced one page, not six"
else
    fail "repeat failures kept paging (alerts on last run=$(alerts))"
fi

# ------------------------------------------------------------------
# 3. 🔴 The load-bearing case. A DIFFERENT failure, arriving while the
#    cooldown from the first is still running, must page immediately.
#
#    Without this, "suppress repeats" degrades into "go deaf on any host that
#    is already unwell" — the moment a second fault is most likely and least
#    affordable to miss.
# ------------------------------------------------------------------
run "$WORK/fault_b.sh"
if [ "$(alerts)" -eq 1 ]; then
    pass "a CHANGED failure pages immediately, cooldown notwithstanding"
else
    fail "changed failure was swallowed by the cooldown (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 4. …and the new fault then starts its own cooldown.
# ------------------------------------------------------------------
run "$WORK/fault_b.sh"
if [ "$(alerts)" -eq 0 ]; then
    pass "the changed failure starts a fresh cooldown of its own"
else
    fail "changed failure did not reset the ladder (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 5. 🔴 The cap is a floor on speech. With base=1 the delay elapses between
#    runs, so a persisting fault must speak again — labelled as a reminder,
#    carrying how long it has been failing.
#
#    This is what stops "suppressed" from meaning "silent forever".
# ------------------------------------------------------------------
rm -f "$STATE"
run "$WORK/fault_a.sh" --alert-repeat-base=1 --alert-repeat-max=1
sleep 2
run "$WORK/fault_a.sh" --alert-repeat-base=1 --alert-repeat-max=1
if [ "$(alerts)" -eq 1 ] && sent_has 'STILL FAILING'; then
    pass "once the delay elapses the same fault is re-stated as STILL FAILING"
else
    fail "persisting fault went permanently silent (alerts=$(alerts))"
fi
if sent_has 'consecutive failing runs'; then
    pass "the reminder carries the run count and elapsed time"
else
    fail "reminder lost the repeat context"
fi

# ------------------------------------------------------------------
# 6. Corrupt state fails OPEN. Same rule as the sweep's back-off machine: a
#    monitoring system that goes quiet because it cannot read its own
#    bookkeeping has chosen the worst of the two available failure modes.
# ------------------------------------------------------------------
rm -f "$STATE"
run "$WORK/fault_a.sh"
python3 - "$STATE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["next_alert_epoch"] = "not-a-number"
json.dump(d, open(p, "w"))
PY
run "$WORK/fault_a.sh"
if [ "$(alerts)" -eq 1 ]; then
    pass "unparseable next_alert_epoch fails open and alerts"
else
    fail "corrupt state silenced the alert (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 7. A state file written by the PREVIOUS version of this wrapper has none of
#    the new keys. The upgrade must page once more than needed, never once
#    less.
# ------------------------------------------------------------------
rm -f "$STATE"
printf '%s\n' '{"last_notification": "2026-08-13 12:00:00", "last_status": "failure", "last_success_notification": "never"}' > "$STATE"
run "$WORK/fault_a.sh"
if [ "$(alerts)" -eq 1 ]; then
    pass "a pre-upgrade state file alerts on the first run after deploy"
else
    fail "migration swallowed the first alert (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 8. 🔴 Recovery still posts after a suppressed run — and the fault returning
#    afterwards is treated as new, because the recovery in between was a real
#    state change.
# ------------------------------------------------------------------
rm -f "$STATE"
run "$WORK/fault_a.sh"      # pages
run "$WORK/fault_a.sh"      # suppressed
run "$WORK/ok.sh"
if [ "$(monitors)" -eq 1 ]; then
    pass "recovery is still announced after a suppressed failure"
else
    fail "recovery notice lost (monitors=$(monitors))"
fi
run "$WORK/fault_a.sh"
if [ "$(alerts)" -eq 1 ] && ! sent_has 'STILL FAILING'; then
    pass "the same fault after a recovery pages as new, not as a reminder"
else
    fail "post-recovery failure was treated as a continuing episode"
fi

# ------------------------------------------------------------------
# 9. 🔴 Volatile lines that are not findings must not mint a new signature.
#
#    Measured on agent-lxc 2026-08-14: the Tier 1 sweep emits a bookkeeping
#    line — "(findings unchanged since the last sweep …)" — that by
#    construction appears only from the SECOND identical run onward. With the
#    signature taken over the whole output, the first repeat of every fault
#    looked like a different fault and paged again.
#
#    The rule under test: when the output marks failures with ❌, the signature
#    is taken from those lines alone. This is also what makes an unchanging
#    fault survive a changing timestamp, load average or uptime line.
# ------------------------------------------------------------------
rm -f "$STATE"
cat > "$WORK/fault_noisy.sh" <<'EOF'
#!/bin/sh
echo "=== Fleet sweep ==="
echo "Date: $(date)"
echo "❌ opnsense: UP but no usable shell as read_agent"
if [ -f "$NOISE_FLAG" ]; then
    echo "(findings unchanged since the last sweep - snapshot left untouched)"
fi
exit 1
EOF
chmod +x "$WORK/fault_noisy.sh"
NOISE_FLAG="$WORK/noise"; export NOISE_FLAG
rm -f "$NOISE_FLAG"
run "$WORK/fault_noisy.sh"          # first run: pages
: > "$NOISE_FLAG"                    # second run gains the bookkeeping line
sleep 1
run "$WORK/fault_noisy.sh"
if [ "$(alerts)" -eq 0 ]; then
    pass "an added non-finding line does not re-page (signature is ❌-scoped)"
else
    fail "bookkeeping/timestamp noise minted a new signature (alerts=$(alerts))"
fi

# ...but a changed ❌ line still must.
cat > "$WORK/fault_noisy2.sh" <<'EOF'
#!/bin/sh
echo "=== Fleet sweep ==="
echo "Date: $(date)"
echo "❌ opnsense: UP but no usable shell as read_agent"
echo "❌ cobra: 1 failed systemd unit(s): nmbd.service"
exit 1
EOF
chmod +x "$WORK/fault_noisy2.sh"
run "$WORK/fault_noisy2.sh"
if [ "$(alerts)" -eq 1 ]; then
    pass "a changed ❌ line still pages through the same noise"
else
    fail "❌-scoping went too far and swallowed a real change"
fi

# ------------------------------------------------------------------
# 10. The escape hatch: base=0 restores the old always-page behaviour, so a
#    job that genuinely wants every run announced can say so.
# ------------------------------------------------------------------
rm -f "$STATE"
run "$WORK/fault_a.sh" --alert-repeat-base=0
run "$WORK/fault_a.sh" --alert-repeat-base=0
if [ "$(alerts)" -eq 1 ]; then
    pass "--alert-repeat-base=0 disables suppression entirely"
else
    fail "base=0 did not restore per-run alerting (alerts=$(alerts))"
fi

# ------------------------------------------------------------------
# 11. A malformed value is fatal rather than silently meaning 0. Same
#     reasoning as --heartbeat-interval: a typo must not quietly restore the
#     flood.
# ------------------------------------------------------------------
rm -f "$STATE"
if "$WRAPPER" --state-file="$STATE" --alert-repeat-base=1h \
        "$MON_HOOK" "$ALERT_HOOK" "$WORK/ok.sh" >/dev/null 2>&1; then
    fail "a non-numeric --alert-repeat-base was accepted"
else
    pass "a non-numeric --alert-repeat-base is fatal"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ wrapper alert dedup: all checks passed\n'
    exit 0
fi
printf '❌ wrapper alert dedup: %s check(s) failed\n' "$failures"
exit 1
