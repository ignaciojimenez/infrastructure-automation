#!/bin/sh
# fleet_linear_sync.sh against a stateful fake Linear (PER-85 part 1).
#
# Runs on the laptop: no network, no token, no spend. The real template is
# rendered and run as-is; only curl is replaced (tests/lib/fake_linear_curl.py)
# and the clock is injected, so a 24 h close takes seconds to prove.
#
#   tests/unit/fleet_linear_sync_test.sh
#   SH=dash tests/unit/fleet_linear_sync_test.sh
#
# Every "nothing happened" below is paired with the case that must act: an
# absence the filer ignores and an absence it closes on differ by one fact
# (was the host observed?), and both are forced.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/fleet_linear_sync.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
mkdir -p "$AGENT_DIR/incidents" "$AGENT_DIR/plans" "$WORK/bin" "$WORK/state"
TOKEN="lin_api_UNITTESTSECRET"
printf 'Authorization: %s\n' "$TOKEN" > "$WORK/auth.header"
HOUR=3600
CLOSE=$((24 * HOUR))
URL_BASE="https://example.invalid/AGENT_LXC.md?incident="

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/sync.sh" \
    agent_state_dir="$AGENT_DIR" \
    agent_incident_subjects_py="$REPO_ROOT/scripts/services/agent/incident_subjects.py" \
    agent_incident_quiet_hours=26 \
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

cp "$REPO_ROOT/tests/lib/fake_linear_curl.py" "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"

export FAKE_LINEAR_DB="$WORK/db.json"
export FAKE_LINEAR_LOG="$WORK/ops.log"
export FAKE_LINEAR_ARGV="$WORK/argv.log"
: > "$FAKE_LINEAR_LOG"
: > "$FAKE_LINEAR_ARGV"

T0=1760000000

# sweep <epoch> <observed hosts, space-separated> [finding ...]
sweep() {
    _ts=$1 _obs=$2
    shift 2
    {
        printf '{"timestamp_epoch": %s, "observed": [' "$_ts"
        _sep=""
        for _h in $_obs; do printf '%s"%s"' "$_sep" "$_h"; _sep=","; done
        printf '], "findings": ['
        _sep=""
        for _f in "$@"; do printf '%s"%s"' "$_sep" "$_f"; _sep=","; done
        printf ']}\n'
    } > "$AGENT_DIR/sweep_state.json"
}

# run <now> — the filer as cron runs it, with the fake on PATH.
run() {
    : > "$FAKE_LINEAR_LOG"
    FLEET_LINEAR_NOW=$1 PATH="$WORK/bin:$PATH" "$SH" "$WORK/sync.sh" > "$WORK/out" 2>&1
    RC=$?
}

ops() { grep -c "^$1 " "$FAKE_LINEAR_LOG" 2>/dev/null || true; }
issues_total() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["issues"]))' "$FAKE_LINEAR_DB"; }
issue_state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["issues"][int(sys.argv[2])]["state_type"])' "$FAKE_LINEAR_DB" "$1"; }
comments_of() { python3 -c 'import json,sys; print("\n---\n".join(json.load(open(sys.argv[1]))["issues"][int(sys.argv[2])]["comments"]))' "$FAKE_LINEAR_DB" "$1"; }

ALL="cobra dockassist hifipi vinylstreamer unifi cwwk opnsense"
DISK="cobra: disk usage 91% (threshold 85%)"
KEY=cobra.disk-usage-threshold   # what incident_subjects.py derives from that wording

printf '\n── Tier 1 finding -> exactly one agent/fleet issue\n'

sweep "$T0" "$ALL" "$DISK"
run "$T0"
if [ "$RC" -eq 0 ] && [ "$(ops issueCreate)" = 1 ] && [ "$(issues_total)" = 1 ]; then
    pass "a new finding opens one issue"
else
    fail "expected one issueCreate (rc=$RC, creates=$(ops issueCreate)): $(cat "$WORK/out")"
fi
shape=$(python3 -c '
import json, sys
i = json.load(open(sys.argv[1]))["issues"][0]
a = i["attachments"]
print(i["title"], "|", sorted(i["labelIds"]), i["stateId"], i["projectId"], i["teamId"], "|",
      [x["url"] for x in a], [x["subtitle"] for x in a])
' "$FAKE_LINEAR_DB")
case "$shape" in
    "$KEY: disk usage 91% (threshold 85%) | ['label-broken', 'label-fleet'] state-todo proj-fleet team-per | ['${URL_BASE}$KEY'] ['fleet incident']")
        pass "titled by key, agent/fleet + kind/broken, Todo in Fleet, identity marker planted" ;;
    *) fail "issue shape: $shape" ;;
esac

printf '\n── The same fault on the next sweep adds nothing\n'

sweep $((T0 + HOUR)) "$ALL" "$DISK"
run $((T0 + HOUR))
if [ "$RC" -eq 0 ] && [ "$(ops issueCreate)" = 0 ] && [ "$(issues_total)" = 1 ] &&
   [ "$(ops attachmentCreate)" = 0 ] && [ "$(ops commentCreate)" = 0 ]; then
    pass "second sweep: no second issue, and no write at all (no churn)"
else
    fail "second sweep wrote: $(cat "$FAKE_LINEAR_LOG")"
fi

# A finding that keys to the same incident through different words (a reminder,
# a re-wording) joins it rather than opening a sibling.
sweep $((T0 + 2 * HOUR)) "$ALL" "cobra: disk usage 93% (threshold 85%)"
run $((T0 + 2 * HOUR))
if [ "$(ops issueCreate)" = 0 ]; then pass "a re-worded finding with the same key joins the issue"; else fail "re-worded finding opened another issue"; fi

printf '\n── Tier 2 plan lands as a comment, once\n'

printf '# Cobra root disk filling\n\nCause: plex transcode cache.\n' > "$AGENT_DIR/plans/2026-10-11-cobra-disk.md"
printf '%s %s %s\n' "$T0" "$T0" "$AGENT_DIR/plans/2026-10-11-cobra-disk.md" > "$AGENT_DIR/incidents/$KEY"
sweep $((T0 + 3 * HOUR)) "$ALL" "$DISK"
run $((T0 + 3 * HOUR))
if [ "$(ops commentCreate)" = 1 ] && comments_of 0 | grep -q "plex transcode cache"; then
    pass "the plan investigate.sh recorded for the key is posted to its issue"
else
    fail "plan not posted: $(cat "$FAKE_LINEAR_LOG") / $(cat "$WORK/out")"
fi
run $((T0 + 3 * HOUR))
if [ "$(ops commentCreate)" = 0 ]; then pass "the same plan is not posted twice"; else fail "plan re-posted"; fi
printf '# Second look\n\nCause: revised.\n' > "$AGENT_DIR/plans/2026-10-12-cobra-disk.md"
printf '%s %s %s\n' "$T0" "$T0" "$AGENT_DIR/plans/2026-10-12-cobra-disk.md" > "$AGENT_DIR/incidents/$KEY"
run $((T0 + 3 * HOUR))
if [ "$(ops commentCreate)" = 1 ]; then pass "a re-investigation (new plan file) is posted"; else fail "new plan not posted"; fi

printf '\n── Absence on an UNOBSERVED host proves nothing\n'

# cobra goes dark: its disk finding vanishes because cobra was not probed.
sweep $((T0 + 4 * HOUR)) "dockassist hifipi vinylstreamer unifi cwwk opnsense" \
    "cobra: UNREACHABLE — no response at all (host down, or off the network)"
run $((T0 + 4 * HOUR))
marks=$(grep -c 'absent_since' "$FAKE_LINEAR_LOG" || true)
if [ "$marks" = 0 ] && grep -q "$KEY: cobra not observed" "$WORK/out" &&
   [ "$(ops issueCreate)" = 1 ]; then
    pass "the disk issue left alone while cobra is dark; cobra.reachability opened"
else
    fail "unobserved absence acted on: $(cat "$FAKE_LINEAR_LOG")"
fi

printf '\n── Observed absence closes after the window, not before\n'

# cobra back, disk fine: both cobra issues are now observed-absent.
sweep $((T0 + 5 * HOUR)) "$ALL"
run $((T0 + 5 * HOUR))
if [ "$(grep -c 'absent_since' "$FAKE_LINEAR_LOG")" = 2 ]; then pass "both cobra issues marked absent"; else fail "absence marks: $(cat "$FAKE_LINEAR_LOG")"; fi

sweep $((T0 + 5 * HOUR + CLOSE - 1)) "$ALL"
run $((T0 + 5 * HOUR + CLOSE - 1))
if [ "$(ops issueUpdate)" = 0 ] && [ "$(issue_state 0)" = unstarted ]; then
    pass "one second short of the window: still open"
else
    fail "closed early: $(cat "$FAKE_LINEAR_LOG")"
fi

# Back for one sweep inside the window: the mark is cleared, the clock restarts.
sweep $((T0 + 6 * HOUR)) "$ALL" "$DISK"
run $((T0 + 6 * HOUR))
if grep -q '^attachmentCreate PER-901 {}$' "$FAKE_LINEAR_LOG" && [ "$(ops issueCreate)" = 0 ]; then
    pass "a recurrence inside the window clears the mark on the SAME issue"
else
    fail "recurrence: $(cat "$FAKE_LINEAR_LOG")"
fi
sweep $((T0 + 7 * HOUR)) "$ALL"
run $((T0 + 7 * HOUR))
sweep $((T0 + 7 * HOUR + CLOSE)) "$ALL"
run $((T0 + 7 * HOUR + CLOSE))
if [ "$(issue_state 0)" = completed ] && comments_of 0 | grep -q "Closed by agent-lxc fleet sweep — absent for 24h"; then
    pass "absent for the full window on observed sweeps: closed, with the reason as a comment"
else
    fail "not closed: state=$(issue_state 0) $(cat "$FAKE_LINEAR_LOG")"
fi

printf '\n── A fault that returns after close gets a new issue\n'

sweep $((T0 + 8 * HOUR + CLOSE)) "$ALL" "$DISK"
run $((T0 + 8 * HOUR + CLOSE))
if [ "$(ops issueCreate)" = 1 ]; then pass "closed issue is not reopened; a fresh one is filed"; else fail "recurrence after close: $(cat "$FAKE_LINEAR_LOG")"; fi

printf '\n── Refusals: each must fail loudly and write nothing\n'

sweep $((T0 + 8 * HOUR + CLOSE)) "$ALL" "$DISK"
run $((T0 + 8 * HOUR + CLOSE + 7201))
if [ "$RC" -ne 0 ] && [ ! -s "$FAKE_LINEAR_LOG" ] && grep -q "Tier 1 has stopped writing it" "$WORK/out"; then pass "stale sweep state: non-zero, no API call"; else fail "stale state: rc=$RC $(cat "$WORK/out")"; fi

sweep $((T0 + 9 * HOUR + CLOSE)) "$ALL" "cwwk: zpool rpool is DEGRADED"
FAKE_LINEAR_MORE=1; export FAKE_LINEAR_MORE
run $((T0 + 9 * HOUR + CLOSE))
unset FAKE_LINEAR_MORE
if [ "$RC" -ne 0 ] && [ "$(ops issueCreate)" = 0 ]; then pass "partial issue list: refuses before writing"; else fail "partial view acted on: rc=$RC $(cat "$FAKE_LINEAR_LOG")"; fi

FAKE_LINEAR_FAIL=issueCreate; export FAKE_LINEAR_FAIL
run $((T0 + 9 * HOUR + CLOSE))
if [ "$RC" -ne 0 ] && grep -q "Linear refused" "$WORK/out"; then pass "a GraphQL error exits non-zero (the wrapper pages)"; else fail "GraphQL error swallowed: rc=$RC $(cat "$WORK/out")"; fi

FAKE_LINEAR_FAIL=attachmentCreate
run $((T0 + 9 * HOUR + CLOSE))
unset FAKE_LINEAR_FAIL
if [ "$RC" -ne 0 ] && grep -q "next run will open a duplicate" "$WORK/out"; then pass "an issue opened without its marker is reported, not ignored"; else fail "marker failure swallowed: rc=$RC $(cat "$WORK/out")"; fi

mv "$WORK/auth.header" "$WORK/auth.off"
run $((T0 + 9 * HOUR + CLOSE))
if [ "$RC" -ne 0 ] && [ ! -s "$FAKE_LINEAR_LOG" ]; then pass "no credential: non-zero, no API call"; else fail "ran without a credential: rc=$RC"; fi
mv "$WORK/auth.off" "$WORK/auth.header"

sweep $((T0 + 9 * HOUR + CLOSE)) "$ALL" "garbage-without-host-separator"
run $((T0 + 9 * HOUR + CLOSE))
if [ "$RC" -ne 0 ] && grep -q "none keyed" "$WORK/out"; then pass "findings that key to nothing fail, not read as healthy"; else fail "unkeyed findings: rc=$RC $(cat "$WORK/out")"; fi

printf '\n── The builder'"'"'s draft PRs reach their issue, once each\n'

# Fresh state: one open issue for the disk finding, nothing posted yet.
rm -f "$FAKE_LINEAR_DB"; rm -rf "$WORK/state"; mkdir -p "$WORK/state"
sweep "$T0" "$ALL" "$DISK"
run "$T0"
REF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["issues"][0]["identifier"])' "$FAKE_LINEAR_DB")
pr() {  # pr <number> <head ref> <login> <repo> <title> [merged_at ISO]
    printf '{"html_url":"https://github.com/o/r/pull/%s","title":"%s","user":{"login":"%s"},"head":{"ref":"%s","repo":{"full_name":"%s"}},"merged_at":%s}' \
        "$1" "$5" "$3" "$2" "$4" "$(if [ -n "${6:-}" ]; then printf '"%s"' "$6"; else printf null; fi)"
}
BR="builder/fleet-${REF#*-}"   # the builder never puts PER-<n> in a branch (TODO 50)
{
    printf '['
    pr 7 "$BR" ignaciojimenez-builder o/r "fix(fleet#${REF#*-}): fix the threshold"; printf ','
    pr 8 "$BR" mallory mallory/r "fix(fleet#${REF#*-}): from a fork"; printf ','
    pr 9 "$BR" mallory o/r "fix(fleet#${REF#*-}): wrong author"; printf ','
    pr 10 "builder/fleet-1" ignaciojimenez-builder o/r "fix(fleet#1): another issue"; printf ','
    pr 12 "builder/$REF" ignaciojimenez-builder o/r "fix($REF): the old branch name"
    printf ']'
} > "$WORK/pulls.json"
export FAKE_GITHUB_PULLS="$WORK/pulls.json"
sweep $((T0 + HOUR)) "$ALL" "$DISK"
run $((T0 + HOUR))
if [ "$RC" -eq 0 ] && [ "$(ops commentCreate)" = 1 ] &&
   comments_of 0 | grep -q "Builder opened a draft PR.*https://github.com/o/r/pull/7$"; then
    pass "the builder's PR is commented on its issue"
else
    fail "PR not posted: rc=$RC $(cat "$FAKE_LINEAR_LOG") / $(cat "$WORK/out")"
fi
if ! comments_of 0 | grep -q -e "pull/8" -e "pull/9" -e "pull/10" -e "pull/12"; then
    pass "a fork, another author, another issue's branch, or a PER-<n> branch is ignored"
else
    fail "believed a PR it should not have: $(comments_of 0)"
fi
if grep -q "^github GET no-credential$" "$FAKE_LINEAR_LOG"; then
    pass "the GitHub read carries no credential (the Linear key never goes to GitHub)"
else
    fail "GitHub read: $(grep github "$FAKE_LINEAR_LOG")"
fi
sweep $((T0 + 2 * HOUR)) "$ALL" "$DISK"
run $((T0 + 2 * HOUR))
if [ "$(ops commentCreate)" = 0 ]; then pass "the same PR is not posted twice"; else fail "PR re-posted"; fi
{
    printf '['
    pr 11 "$BR" ignaciojimenez-builder o/r "[hand-back] fleet#${REF#*-}: no fix passed the unit tests and the rig"; printf ','
    pr 7 "$BR" ignaciojimenez-builder o/r "fix(fleet#${REF#*-}): fix the threshold"
    printf ']'
} > "$WORK/pulls.json"
sweep $((T0 + 3 * HOUR)) "$ALL" "$DISK"
run $((T0 + 3 * HOUR))
if [ "$(ops commentCreate)" = 1 ] && comments_of 0 | grep -q "Builder handed this back.*pull/11$"; then
    pass "a hand-back is commented as a hand-back"
else
    fail "hand-back: $(cat "$FAKE_LINEAR_LOG")"
fi
FAKE_GITHUB_FAIL=1; export FAKE_GITHUB_FAIL
sweep $((T0 + 4 * HOUR)) "$ALL" "$DISK"
run $((T0 + 4 * HOUR))
unset FAKE_GITHUB_FAIL FAKE_GITHUB_PULLS
if [ "$RC" -ne 0 ] && grep -q "could not read builder PRs" "$WORK/out" && grep -q "builder PRs posted 0" "$WORK/out"; then
    pass "GitHub unreachable: Linear still reconciled, then the run fails (pages)"
else
    fail "GitHub failure swallowed: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── A merged fix that did not clear its finding is flagged once, after a grace period\n'

iso() { python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
MERGED=$((T0 + 5 * HOUR))
{
    printf '['
    pr 7 "$BR" ignaciojimenez-builder o/r "fix(fleet#${REF#*-}): fix the threshold" "$(iso "$MERGED")"; printf ','
    pr 11 "$BR" ignaciojimenez-builder o/r "[hand-back] fleet#${REF#*-}: no fix passed the unit tests and the rig" "$(iso "$MERGED")"
    printf ']'
} > "$WORK/pulls.json"
export FAKE_GITHUB_PULLS="$WORK/pulls.json"
sweep $((MERGED + 5 * HOUR)) "$ALL" "$DISK"
run $((MERGED + 5 * HOUR))
if [ "$RC" -eq 0 ] && [ "$(ops commentCreate)" = 0 ]; then pass "within the grace period: no comment"; else fail "early: $(cat "$WORK/out")"; fi
sweep $((MERGED + 6 * HOUR)) "$ALL"
run $((MERGED + 6 * HOUR))
if [ "$RC" -eq 0 ] && [ "$(ops commentCreate)" = 0 ]; then pass "finding gone after the merge: no comment"; else fail "absent finding flagged: $(cat "$WORK/out")"; fi
sweep $((MERGED + 7 * HOUR)) "$ALL" "$DISK"
run $((MERGED + 7 * HOUR))
if [ "$RC" -eq 0 ] && [ "$(ops commentCreate)" = 1 ] &&
   comments_of 0 | grep -q "fix did not clear this finding.*pull/7 was merged 7h ago"; then
    pass "merged fix, finding present after the grace period: one comment naming the PR"
else
    fail "persisting finding: rc=$RC $(cat "$WORK/out") / $(comments_of 0 | tail -2)"
fi
if ! comments_of 0 | grep "did not clear" | grep -q "pull/11"; then pass "a merged hand-back is not flagged"; else fail "hand-back flagged"; fi
sweep $((MERGED + 8 * HOUR)) "$ALL" "$DISK"
run $((MERGED + 8 * HOUR))
if [ "$(ops commentCreate)" = 0 ]; then pass "the same merged PR is flagged only once"; else fail "flagged twice"; fi
unset FAKE_GITHUB_PULLS

printf '\n── The credential never reaches argv\n'

if grep -q "$TOKEN" "$FAKE_LINEAR_ARGV"; then
    fail "token appeared in curl's argv"
elif grep -q -- "-H @$WORK/auth.header" "$FAKE_LINEAR_ARGV"; then
    pass "curl got the header as a file ($(wc -l < "$FAKE_LINEAR_ARGV" | tr -d ' ') calls, token in none)"
else
    fail "could not find the header-file argument: $(head -1 "$FAKE_LINEAR_ARGV")"
fi

printf '\n── Keys match investigate.sh character for character\n'

extract() { sed -n '/^incident_key() {/,/^}/p' "$1"; }
if [ -n "$(extract "$TEMPLATE")" ] &&
   [ "$(extract "$TEMPLATE")" = "$(extract "$REPO_ROOT/scripts/services/agent/investigate.sh.j2")" ]; then
    pass "incident_key() is identical in both scripts"
else
    fail "incident_key() differs between fleet_linear_sync.sh and investigate.sh"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ fleet_linear_sync: all checks passed\n'
    exit 0
fi
printf '❌ fleet_linear_sync: %s check(s) failed\n' "$failures"
exit 1
