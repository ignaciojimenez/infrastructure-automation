#!/bin/sh
# Alert -> Tier 2 plan -> hand-off -> agent/fleet issue, end to end on the laptop.
#
# The real investigate.sh and the real fleet_linear_sync.sh are rendered and
# run in sequence, against stubbed Slack and opencode and the fake Linear. No
# network, no token, no spend.
#
#   tests/unit/alert_handoff_test.sh
#   SH=dash tests/unit/alert_handoff_test.sh
#
# The gap this closes (2026-10-13): workbench-lxc paged "ufw not running" for
# 22 h. The Slack watch bought a plan, posted it, and stopped there. Only Tier 1
# sweep findings reached the queue, so the builder never saw the most common
# real fault: a check's own alert.
#
# Every "filed" below is paired with a "not filed": the plan's verdict decides,
# and a wrong verdict, an unnamed key, or a stale hand-off must all file
# nothing.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
HANDOFF="$AGENT_DIR/handoff"
INCIDENTS="$AGENT_DIR/incidents"
mkdir -p "$AGENT_DIR" "$WORK/bin" "$WORK/plans" "$WORK/state"
HOUR=3600
CLOSE=$((24 * HOUR))
QUIET_HOURS=26
URL_BASE="https://example.invalid/AGENT_LXC.md?incident="

python3 "$REPO_ROOT/tests/lib/render_j2.py" \
    "$REPO_ROOT/scripts/services/agent/investigate.sh.j2" "$WORK/investigate.sh" \
    agent_env_file="$WORK/agent.env" \
    agent_incident_subjects_py="$REPO_ROOT/scripts/services/agent/incident_subjects.py" \
    agent_state_dir="$AGENT_DIR" \
    agent_plans_dir="$WORK/plans" \
    agent_failure_alert_cooldown_seconds=21600 \
    agent_run_timeout_seconds=600 \
    agent_slack_channel=C_TEST \
    agent_slack_max_per_run=3 \
    agent_incident_quiet_hours=$QUIET_HOURS \
    agent_incident_max_age_days=7 \
    agent_daily_spend_cap_usd=5.00 \
    agent_fleet_hosts=cobra:linux,hifipi:linux,workbench-lxc:linux \
    opencode_bin="$WORK/bin/opencode" || exit 1

printf 'Authorization: lin_api_UNITTEST\n' > "$WORK/auth.header"
python3 "$REPO_ROOT/tests/lib/render_j2.py" \
    "$REPO_ROOT/scripts/services/agent/fleet_linear_sync.sh.j2" "$WORK/sync.sh" \
    agent_state_dir="$AGENT_DIR" \
    agent_incident_subjects_py="$REPO_ROOT/scripts/services/agent/incident_subjects.py" \
    agent_incident_quiet_hours=$QUIET_HOURS \
    agent_linear_auth_file="$WORK/auth.header" \
    agent_linear_state_dir="$WORK/state" \
    agent_linear_endpoint="https://api.linear.invalid/graphql" \
    agent_linear_team_id=team-per \
    agent_linear_project_id=proj-fleet \
    agent_linear_todo_state_id=state-todo \
    agent_linear_done_state_id=state-done \
    agent_linear_fleet_label_id=label-fleet \
    agent_linear_broken_label_id=label-broken \
    agent_linear_incident_url_base="$URL_BASE" \
    agent_linear_close_after_seconds="$CLOSE" \
    agent_linear_stale_after_seconds=7200 \
    agent_builder_pulls_url="https://api.github.invalid/repos/o/r/pulls" \
    agent_builder_login=ignaciojimenez-builder \
    agent_builder_repo=o/r \
    agent_builder_merged_grace_hours=6 || exit 1

# ------------------------------------------------------------------
# Stubs. curl serves both the Slack history poll (investigate.sh) and Linear
# and GitHub (the filer, through the shared fake). opencode returns whatever
# plan $PLAN_FILE holds, so each case picks its verdict.
# ------------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/flock"
cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in -*) shift 2 ;; [0-9]*) shift ;; *) break ;; esac
done
exec "$@"
STUB
cp "$REPO_ROOT/tests/lib/fake_linear_curl.py" "$WORK/bin/fake_linear_curl"
cat > "$WORK/bin/curl" <<STUB
#!/bin/sh
case "\$*" in *conversations.history*) cat "\$SLACK_FIXTURE"; exit 0 ;; esac
exec python3 "$WORK/bin/fake_linear_curl" "\$@"
STUB
cat > "$WORK/bin/opencode" <<'STUB'
#!/bin/sh
echo run >> "$CALLS"
python3 -c '
import json, sys
plan = open(sys.argv[1]).read()
text = "===PLAN===\n" + plan + "\n===SUMMARY===\nstub summary\n"
print(json.dumps({"type": "text", "part": {"messageID": "m1", "text": text}}))
print(json.dumps({"type": "step_finish", "part": {"cost": 0.25}}))
' "$PLAN_FILE"
STUB
chmod +x "$WORK"/bin/*
printf 'ANTHROPIC_API_KEY=test\nSLACK_READ_TOKEN=test\n' > "$WORK/agent.env"

SLACK_FIXTURE="$WORK/slack.json"
PLAN_FILE="$WORK/plan.md"
CALLS="$WORK/calls"
: > "$CALLS"
export SLACK_FIXTURE PLAN_FILE CALLS
export FAKE_LINEAR_DB="$WORK/db.json" FAKE_LINEAR_LOG="$WORK/ops.log" FAKE_LINEAR_ARGV="$WORK/argv.log"
PATH="$WORK/bin:$PATH"
export PATH

# alerts "<host>|<output line>" ... — one wrapper-shaped failure per argument,
# from system_health_check.sh, as #home-alerts history.
alerts() {
    python3 - "$SLACK_FIXTURE" "$@" <<'PY'
import json, sys, time
msgs = []
for i, spec in enumerate(sys.argv[2:]):
    host, line = spec.split("|", 1)
    msgs.append({
        "ts": "%.6f" % (time.time() + i),
        "text": ":x: ALERT: Script Failed on " + host,
        "attachments": [{
            "text": "*Output:*\n```System Health Check\nHost: " + host + "\n" + line + "\n```",
            "fields": [{"title": "Host", "value": host}, {"title": "Script", "value": "system_health_check.sh"}],
        }],
    })
json.dump({"ok": True, "messages": msgs}, open(sys.argv[1], "w"))
PY
}

# plan <action> <fixes incidents>
plan() {
    cat > "$PLAN_FILE" <<EOF
# ufw.service never started on workbench-lxc

- **Severity:** degraded
- **Observed at:** 2026-10-13T08:00:00Z
- **Hosts:** workbench-lxc
- **Action:** $1
- **Fixes incidents:** $2

## Proposed fix
1. bootstrap.yml: start ufw.service after \`ufw enable\`.
EOF
}

poll() { rm -f "$AGENT_DIR/.last_slack_ts"; "$SH" "$WORK/investigate.sh" --slack > "$WORK/inv.out" 2>&1; }
runs() { wc -l < "$CALLS" | tr -d ' '; }

# file <now> [observed hosts] — the filer, with a fresh and empty sweep.
file() {
    printf '{"timestamp_epoch": %s, "observed": ["cobra","hifipi","workbench-lxc"], "findings": [%s]}\n' \
        "$1" "${2:-}" > "$AGENT_DIR/sweep_state.json"
    : > "$FAKE_LINEAR_LOG"
    FLEET_LINEAR_NOW=$1 "$SH" "$WORK/sync.sh" > "$WORK/sync.out" 2>&1
    RC=$?
}
ops() { grep -c "^$1 " "$FAKE_LINEAR_LOG" 2>/dev/null || true; }
issues_total() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["issues"]))' "$FAKE_LINEAR_DB" 2>/dev/null || echo 0; }
issue_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["issues"][int(sys.argv[2])][sys.argv[3]])' "$FAKE_LINEAR_DB" "$1" "$2"; }
comments_of() { python3 -c 'import json,sys; print("\n---\n".join(json.load(open(sys.argv[1]))["issues"][int(sys.argv[2])]["comments"]))' "$FAKE_LINEAR_DB" "$1"; }
reset() { rm -rf "$AGENT_DIR" "$WORK/state" "$FAKE_LINEAR_DB"; mkdir -p "$AGENT_DIR" "$WORK/state"; : > "$CALLS"; }

UFW="workbench-lxc|❌ Service ufw: not running"
KEY=workbench-lxc.ufw
NOW=$(date +%s)

printf '\n── A repo-change verdict on an alert becomes one queue issue\n'

alerts "$UFW"
plan repo-change "\`$KEY\`"
poll
if [ "$(runs)" = 1 ] && [ -f "$HANDOFF/$KEY" ]; then
    pass "the alert was investigated once and handed off as $KEY"
else
    fail "expected one run and handoff/$KEY (runs=$(runs)): $(ls "$HANDOFF" 2>&1) $(tail -3 "$WORK/inv.out")"
fi
case "$(cat "$HANDOFF/$KEY" 2>/dev/null)" in
    "workbench-lxc: "*"Service ufw: not running"*) pass "the hand-off holds '<host>: <alert text>'" ;;
    *) fail "hand-off content: $(cat "$HANDOFF/$KEY" 2>&1)" ;;
esac

file "$NOW"
if [ "$RC" -eq 0 ] && [ "$(ops issueCreate)" = 1 ] && [ "$(issues_total)" = 1 ]; then
    pass "the filer opened one issue for it"
else
    fail "filer (rc=$RC, creates=$(ops issueCreate)): $(cat "$WORK/sync.out")"
fi
case "$(issue_field 0 description)" in
    "Alert in #home-alerts on **workbench-lxc**, incident key \`$KEY\`."*) pass "the issue says it came from an alert, not the sweep" ;;
    *) fail "description: $(issue_field 0 description | head -2)" ;;
esac
if comments_of 0 | grep -q '^\*\*Tier 2 investigation plan\*\*' &&
   comments_of 0 | grep -q 'start ufw.service'; then
    pass "the plan is posted as the comment the builder polls for"
else
    fail "plan comment missing: $(comments_of 0 | head -3)"
fi

printf '\n── The same fault paging again adds nothing\n'

alerts "workbench-lxc|❌ Service ufw: not running" "workbench-lxc|❌ Service ufw: not running"
poll
file $((NOW + HOUR))
if [ "$(runs)" = 1 ] && [ "$(ops issueCreate)" = 0 ] && [ "$(ops commentCreate)" = 0 ]; then
    pass "a STILL FAILING reminder buys no run, no issue and no comment"
else
    fail "reminder re-acted (runs=$(runs), creates=$(ops issueCreate), comments=$(ops commentCreate))"
fi

printf '\n── Verdicts that must NOT file\n'

reset
alerts "$UFW"
plan host-action "—"
poll
file "$NOW"
if [ "$(runs)" = 1 ] && [ ! -e "$HANDOFF/$KEY" ] && [ "$(issues_total)" = 0 ]; then
    pass "host-action: investigated, nothing handed off, nothing filed"
else
    fail "host-action leaked (handoff=$(ls "$HANDOFF" 2>&1), issues=$(issues_total))"
fi

reset
alerts "$UFW"
plan repo-change "cobra.disk-usage"
poll
if [ ! -e "$HANDOFF/$KEY" ] && [ ! -e "$HANDOFF/cobra.disk-usage" ] && grep -q 'names none of the investigated keys' "$WORK/inv.out"; then
    pass "repo-change naming a key this run did not investigate hands off nothing, and says so"
else
    fail "unvalidated key handed off: $(ls "$HANDOFF" 2>&1) $(tail -2 "$WORK/inv.out")"
fi

reset
alerts "$UFW"
plan repo-change "—"
poll
if [ -z "$(ls "$HANDOFF" 2>/dev/null)" ]; then
    pass "repo-change with no key named hands off nothing"
else
    fail "handed off without a key: $(ls "$HANDOFF")"
fi

printf '\n── One root cause, two voices: built once\n'

reset
alerts "$UFW" "workbench-lxc|❌ Service fail2ban: not running"
plan repo-change "$KEY"
poll
if [ "$(runs)" = 1 ] && [ -f "$HANDOFF/$KEY" ] && [ ! -e "$HANDOFF/workbench-lxc.fail2ban" ]; then
    pass "two alerts in one run, plan names one key: one hand-off"
else
    fail "expected only $KEY handed off: $(ls "$HANDOFF" 2>&1)"
fi

printf '\n── A lapsed incident closes; a stale hand-off never reopens\n'

reset
alerts "$UFW"
plan repo-change "$KEY"
poll
file "$NOW"
# Nothing has named it for longer than the quiet window.
read -r _o _s _p < "$INCIDENTS/$KEY"
printf '%s %s %s\n' "$((NOW - 30 * HOUR))" "$((NOW - 27 * HOUR))" "$_p" > "$INCIDENTS/$KEY"
file "$NOW"
if [ "$(ops attachmentCreate)" = 1 ] && grep -q "absent; marked" "$WORK/sync.out"; then
    pass "past the quiet window, the key is absent and marked"
else
    fail "lapse not marked: $(cat "$WORK/sync.out")"
fi
file $((NOW + CLOSE))
if [ "$(issue_field 0 state_type)" = completed ] && comments_of 0 | grep -q 'no alert has named this'; then
    pass "after the close window it closes, in the alert's own words"
else
    fail "not closed: $(issue_field 0 state_type) $(cat "$WORK/sync.out")"
fi
file $((NOW + CLOSE + HOUR))
if [ "$(issues_total)" = 1 ] && [ "$(ops issueCreate)" = 0 ]; then
    pass "the leftover hand-off of a lapsed incident files nothing new"
else
    fail "a stale hand-off reopened the issue"
fi

# The fault returns and is re-investigated, now judged host-action.
alerts "$UFW"
plan host-action "—"
poll
file $((NOW + CLOSE + 2 * HOUR))
if [ ! -e "$HANDOFF/$KEY" ] && [ "$(ops issueCreate)" = 0 ]; then
    pass "a re-investigation judged host-action clears the old hand-off and files nothing"
else
    fail "old repo-change verdict outlived the new plan (handoff=$(ls "$HANDOFF" 2>&1), creates=$(ops issueCreate))"
fi

printf '\n── Keys the filer must not take from a hand-off\n'

reset
mkdir -p "$HANDOFF" "$INCIDENTS"
printf 'x: no host\n' > "$HANDOFF/alert-heating-offline"
printf '%s %s -\n' "$NOW" "$NOW" > "$INCIDENTS/alert-heating-offline"
file "$NOW"
if [ "$RC" -eq 0 ] && [ "$(issues_total)" = 0 ]; then
    pass "a hostless alert key is not filed (nothing could ever observe it closed)"
else
    fail "hostless key filed (rc=$RC): $(cat "$WORK/sync.out")"
fi

reset
mkdir -p "$HANDOFF" "$INCIDENTS"
printf 'cobra: alert wording\n' > "$HANDOFF/cobra.disk-usage-threshold"
printf '%s %s -\n' "$NOW" "$NOW" > "$INCIDENTS/cobra.disk-usage-threshold"
file "$NOW" '"cobra: disk usage 91% (threshold 85%)"'
case "$(issue_field 0 description 2>/dev/null)" in
    "Tier 1 fleet sweep finding"*) pass "a key the sweep also reports stays a sweep finding" ;;
    *) fail "sweep key re-labelled as alert: $(issue_field 0 description 2>&1 | head -1)" ;;
esac

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ alert_handoff: all checks passed\n'
    exit 0
fi
printf '❌ alert_handoff: %s check(s) failed\n' "$failures"
exit 1
