#!/bin/sh
# fleet_builder_poll.sh against the stateful fake Linear (PER-85 part 2).
#
# Runs on the laptop: no network, no token, no model, no spend. The real
# template is rendered and run as-is; curl is the fake Linear, the run script
# is a stub whose behaviour each case sets, and the clock is injected so the
# daily cap can be crossed in seconds.
#
#   tests/unit/fleet_builder_poll_test.sh
#   SH=dash tests/unit/fleet_builder_poll_test.sh
#
# What is forced, not read: the attempt is on disk before the run starts; a
# poller killed with SIGKILL mid-attempt is retried, and killed again is
# handed back as "never finished"; the cap and the attempt limit hold.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/workbench/fleet_builder_poll.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin" "$WORK/state" "$WORK/jobs" "$WORK/home" "$WORK/ctl"
KEY="lin_api_BUILDERREADONLYSECRET"
printf 'Authorization: %s\n' "$KEY" > "$WORK/auth.header"
CLAUDE_TOKEN="sk-ant-oat-UNITTESTCLAUDETOKEN"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_TOKEN" > "$WORK/claude.env"

# The run script stub. Its behaviour for an issue is $CTL/<ref> (ok, fail,
# decline, hang; default ok). It logs what it saw so the cases can assert on
# ordering, environment and arguments.
cat > "$WORK/run.sh" <<'EOF'
#!/bin/sh
mode=$1 ref=$2 job=$3
ctl="$STUB_CTL/$ref"
behaviour=$(cat "$ctl" 2>/dev/null || echo ok)
state="$STUB_STATE/issues/$ref"
# Ordering: the poller must have written "started" for THIS attempt already.
last_started=$(grep -c ' started$' "$state" 2>/dev/null || echo 0)
printf '%s %s %s started_on_disk=%s token=%s\n' "$mode" "$ref" "$(basename "$job")" \
    "$last_started" "${CLAUDE_CODE_OAUTH_TOKEN:+set}" >> "$STUB_LOG"
if [ "$mode" = handback ]; then
    cp "$job/handback.md" "$STUB_CTL/$ref.handback"
    echo "PR https://github.com/o/r/pull/9$(printf '%s' "$ref" | tr -cd 0-9)"
    exit 0
fi
cp "$job/issue.md" "$STUB_CTL/$ref.prompt.$(basename "$job")"
case "$behaviour" in
    ok)      echo "noise"; echo "PR https://github.com/o/r/pull/$(printf '%s' "$ref" | tr -cd 0-9)"; exit 0 ;;
    fail)    echo "unit tests failed" > "$job/reason"; echo "FAILED: test_x" > "$job/failure.md"; exit 3 ;;
    decline) echo "full disk needs a human" > "$job/reason"; exit 4 ;;
    hang)    echo $$ > "$STUB_CTL/$ref.pid"; sleep 30; exit 0 ;;
esac
EOF
chmod +x "$WORK/run.sh"

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/poll.sh" \
    builder_linear_auth_file="$WORK/auth.header" \
    builder_claude_env_file="$WORK/claude.env" \
    builder_linear_endpoint="https://api.linear.invalid/graphql" \
    builder_linear_team_id=team-per \
    builder_linear_fleet_label_id=label-fleet \
    builder_linear_todo_state_id=state-todo \
    builder_state_dir="$WORK/state" \
    builder_jobs_dir="$WORK/jobs" \
    builder_run_user=nobody \
    builder_run_home="$WORK/home" \
    builder_run_script="$WORK/run.sh" \
    builder_run_as="" \
    builder_max_attempts=2 \
    builder_daily_cap=2 || exit 1

cp "$REPO_ROOT/tests/lib/fake_linear_curl.py" "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"

export FAKE_LINEAR_DB="$WORK/db.json"
export FAKE_LINEAR_LOG="$WORK/ops.log"
export FAKE_LINEAR_ARGV="$WORK/argv.log"
export STUB_CTL="$WORK/ctl" STUB_STATE="$WORK/state" STUB_LOG="$WORK/stub.log"
: > "$FAKE_LINEAR_ARGV"
: > "$STUB_LOG"

# shellcheck disable=SC2016  # literal: written for another shell to expand
PLAN='**Tier 2 investigation plan** — `/x/plans/p.md` on agent-lxc'

# seed <ref> <with plan: 1|0> [state id] — one agent/fleet issue in the fake.
seed() {
    python3 - "$FAKE_LINEAR_DB" "$1" "$2" "${3:-state-todo}" "$PLAN" <<'EOF'
import json, os, sys
path, ref, with_plan, state, plan = sys.argv[1:]
db = json.load(open(path)) if os.path.exists(path) else {"issues": [], "n": 0}
db["n"] += 1
comments = [{"body": "a human note", "createdAt": "2026-10-11T00:00:00Z"}]
if with_plan == "1":
    comments.append({"body": plan + "\n\nOLD PLAN", "createdAt": "2026-10-11T01:00:00Z"})
    comments.append({"body": plan + "\n\nNEWEST PLAN: fix check_x.sh", "createdAt": "2026-10-11T02:00:00Z"})
db["issues"].append({
    "id": f"iss-{db['n']}", "identifier": ref, "title": f"{ref} title", "description": f"{ref} description",
    "teamId": "team-per", "labelIds": ["label-fleet", "label-broken"], "stateId": state,
    "state_type": "unstarted", "attachments": [], "comments": comments,
    "createdAt": f"2026-10-11T00:{db['n']:02d}:00Z",
})
json.dump(db, open(path, "w"))
EOF
}

# run <now> — the poller as the timer runs it.
run() {
    : > "$FAKE_LINEAR_LOG"
    FLEET_BUILDER_NOW=$1 PATH="$WORK/bin:$PATH" "$SH" "$WORK/poll.sh" > "$WORK/out" 2>&1
    RC=$?
}
runs() { grep -c "^$1 " "$STUB_LOG" 2>/dev/null || true; }
state() { cat "$WORK/state/issues/$1" 2>/dev/null; }

T0=1760140800   # 2025-10-11 00:00:00 UTC
DAY=86400

printf '\n── No plan yet: wait, spend nothing\n'

seed PER-901 0
run "$T0"
if [ "$RC" -eq 0 ] && [ "$(runs attempt)" = 0 ] && [ -z "$(state PER-901)" ] &&
   grep -q "1 waiting for a plan" "$WORK/out"; then
    pass "an issue without a Tier 2 plan is skipped and no attempt is recorded"
else
    fail "planless issue acted on: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── A planned issue: attempt recorded first, then a draft PR\n'

seed PER-902 1
run "$T0"
if [ "$RC" -eq 0 ] && grep -q '^attempt PER-902 PER-902-1 started_on_disk=1 token=set$' "$STUB_LOG"; then
    pass "the attempt is on disk BEFORE the run starts, and the run gets the Claude token"
else
    fail "ordering/env: $(cat "$STUB_LOG") / $(cat "$WORK/out")"
fi
if state PER-902 | grep -q '^final [0-9]* pr https://github.com/o/r/pull/902$'; then
    pass "the PR URL is recorded as the issue's final outcome"
else
    fail "final not recorded: $(state PER-902)"
fi
prompt="$WORK/ctl/PER-902.prompt.PER-902-1"
if grep -q "PER-902 title" "$prompt" && grep -q "PER-902 description" "$prompt" &&
   grep -q "NEWEST PLAN: fix check_x.sh" "$prompt" && ! grep -q "OLD PLAN" "$prompt" &&
   ! grep -q "a human note" "$prompt"; then
    pass "prompt = title + description + the newest Tier 2 plan comment, nothing else"
else
    fail "prompt content: $(cat "$prompt")"
fi

printf '\n── The next sweep produces no second PR\n'

: > "$STUB_LOG"
run $((T0 + 3600))
if [ "$RC" -eq 0 ] && [ ! -s "$STUB_LOG" ]; then
    pass "an issue with a PR is never attempted again"
else
    fail "second run touched it: $(cat "$STUB_LOG")"
fi

printf '\n── Two failures: retried once with the failure, then handed back\n'

python3 - "$FAKE_LINEAR_DB" <<'EOF'
import json, sys
db = json.load(open(sys.argv[1]))
for i in db["issues"]:
    i["state_type"] = "completed"; i["stateId"] = "state-done"
json.dump(db, open(sys.argv[1], "w"))
EOF
seed PER-903 1
echo fail > "$WORK/ctl/PER-903"
T1=$((T0 + DAY))
run "$T1"
if state PER-903 | grep -q '^attempt 1 [0-9]* failed unit tests failed$' && [ "$(runs handback)" = 0 ]; then
    pass "first failure is recorded with its reason; no hand-back yet"
else
    fail "after first failure: $(state PER-903) / $(cat "$WORK/out")"
fi
run $((T1 + 3600))
if grep -q "Your previous attempt failed" "$WORK/ctl/PER-903.prompt.PER-903-2" &&
   grep -q "FAILED: test_x" "$WORK/ctl/PER-903.prompt.PER-903-2"; then
    pass "the second attempt's prompt carries the first one's failure"
else
    fail "retry prompt lacks the failure: $(cat "$WORK/ctl/PER-903.prompt.PER-903-2")"
fi
if [ "$(runs handback)" = 1 ] && state PER-903 | grep -q '^final [0-9]* handback ' &&
   grep -q "attempt 2: unit tests failed" "$WORK/ctl/PER-903.handback"; then
    pass "the second failure hands back in the same run, with both reasons"
else
    fail "no hand-back after attempt 2: $(state PER-903) / $(cat "$WORK/out")"
fi

printf '\n── Killed mid-attempt: retried, then visibly abandoned\n'

# Attempts below are on a fresh day, so the cap is not what stops them.
seed PER-904 1
echo hang > "$WORK/ctl/PER-904"
T2=$((T0 + 2 * DAY))
kill_mid_attempt() {
    : > "$FAKE_LINEAR_LOG"
    FLEET_BUILDER_NOW=$1 PATH="$WORK/bin:$PATH" "$SH" "$WORK/poll.sh" > "$WORK/out" 2>&1 &
    _poller=$!
    _i=0
    while [ ! -s "$WORK/ctl/PER-904.pid" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
    kill -KILL "$_poller" "$(cat "$WORK/ctl/PER-904.pid")" 2>/dev/null
    wait "$_poller" 2>/dev/null
    rm -f "$WORK/ctl/PER-904.pid"
}
kill_mid_attempt "$T2"
if [ "$(state PER-904 | grep -c started)" = 1 ] && ! state PER-904 | grep -q -e failed -e final; then
    pass "SIGKILL mid-attempt leaves 'started' with no outcome"
else
    fail "after kill: $(state PER-904)"
fi
kill_mid_attempt $((T2 + 3600))
if [ "$(state PER-904 | grep -c started)" = 2 ]; then
    pass "the next run retries it as attempt 2"
else
    fail "not retried: $(state PER-904)"
fi
run $((T2 + 7200))
if state PER-904 | grep -q '^final [0-9]* handback ' &&
   grep -q "attempt 1: never finished" "$WORK/ctl/PER-904.handback" &&
   grep -q "attempt 2: never finished" "$WORK/ctl/PER-904.handback" &&
   [ "$(state PER-904 | grep -c started)" = 2 ]; then
    pass "killed twice: handed back as 'never finished', with no third attempt"
else
    fail "kill x2 not handed back: $(state PER-904) / $(cat "$WORK/out")"
fi

printf '\n── Declined: handed back at once, never retried\n'

T3=$((T0 + 3 * DAY))
seed PER-905 1
echo decline > "$WORK/ctl/PER-905"
run "$T3"
if state PER-905 | grep -q '^final [0-9]* handback ' && [ "$(state PER-905 | grep -c started)" = 1 ] &&
   grep -q "declined: full disk needs a human" "$WORK/ctl/PER-905.handback"; then
    pass "a decline is handed back in the same run with the model's reason"
else
    fail "decline: $(state PER-905) / $(cat "$WORK/out")"
fi

printf '\n── Daily cap: attempts, per UTC day\n'

T4=$((T0 + 4 * DAY))
seed PER-906 1; seed PER-907 1; seed PER-908 1
: > "$STUB_LOG"
run "$T4"; run $((T4 + 3600)); run $((T4 + 7200))
if [ "$(runs attempt)" = 2 ] && [ -z "$(state PER-908)" ] && grep -q "1 held by the daily cap of 2" "$WORK/out"; then
    pass "the third issue waits once two attempts were spent today"
else
    fail "cap: $(cat "$STUB_LOG") / $(cat "$WORK/out")"
fi
run $((T4 + DAY))
if state PER-908 | grep -q '^final [0-9]* pr '; then
    pass "it is attempted the next UTC day"
else
    fail "not attempted next day: $(state PER-908) / $(cat "$WORK/out")"
fi

printf '\n── Only Todo is the queue\n'

seed PER-909 1 state-backlog
: > "$STUB_LOG"
run $((T4 + 2 * DAY))
if ! grep -q PER-909 "$STUB_LOG"; then pass "an agent/fleet issue outside Todo is never picked"; else fail "picked a non-Todo issue"; fi

printf '\n── Refusals: each fails loudly and attempts nothing\n'

seed PER-910 1
: > "$STUB_LOG"
FAKE_LINEAR_FAIL=issues; export FAKE_LINEAR_FAIL
run $((T4 + 3 * DAY))
unset FAKE_LINEAR_FAIL
if [ "$RC" -ne 0 ] && [ ! -s "$STUB_LOG" ] && [ -z "$(state PER-910)" ]; then
    pass "a GraphQL error: non-zero, nothing recorded, nothing run"
else
    fail "GraphQL error: rc=$RC $(cat "$WORK/out")"
fi
mv "$WORK/auth.header" "$WORK/auth.off"
run $((T4 + 3 * DAY))
mv "$WORK/auth.off" "$WORK/auth.header"
if [ "$RC" -ne 0 ] && [ ! -s "$STUB_LOG" ]; then pass "no Linear key: non-zero"; else fail "ran without a key"; fi
echo ok > "$WORK/ctl/PER-910"
cat > "$WORK/run.ok" < "$WORK/run.sh"
printf '#!/bin/sh\necho "PR https://evil.example/pull/1"\nexit 0\n' > "$WORK/run.sh"
run $((T4 + 3 * DAY))
cp "$WORK/run.ok" "$WORK/run.sh"
if [ "$RC" -ne 0 ] && ! state PER-910 | grep -q '^final'; then
    pass "a 'PR' line that is not a github.com PR URL is not accepted as success"
else
    fail "accepted a bogus PR URL: $(state PER-910)"
fi

printf '\n── Neither secret reaches argv\n'

if grep -q -e "$KEY" -e "$CLAUDE_TOKEN" "$FAKE_LINEAR_ARGV"; then
    fail "a secret appeared in curl's argv"
elif grep -q -- "-H @$WORK/auth.header" "$FAKE_LINEAR_ARGV"; then
    pass "curl got the Linear key as a header file; the Claude token reached the run only via env"
else
    fail "header-file argument missing: $(head -1 "$FAKE_LINEAR_ARGV")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ fleet_builder_poll: all checks passed\n'
    exit 0
fi
printf '❌ fleet_builder_poll: %s check(s) failed\n' "$failures"
exit 1
