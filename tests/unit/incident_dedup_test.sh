#!/bin/sh
# Regression test: one fault buys one Tier 2 investigation, not one per message.
#
# Runs on the laptop — no container, no Slack, no network, no spend. The real
# investigate.sh is rendered and driven against stubbed Slack and opencode.
#
#   tests/unit/incident_dedup_test.sh
#
# The night this pins (2026-09-12/13): raspotify died on hifipi at ~00:00 CEST
# and agent-lxc paid for SIX investigations of it in ten hours — $1.5701, every
# one reaching the same conclusion. Three keys each let it through:
#   * the Slack watch deduped on message text, and system_health_check,
#     check_raspotify and the wrapper's STILL FAILING reminder are three texts;
#   * anomaly mode deduped on the whole finding set, so vinylstreamer joining
#     it re-billed hifipi, and vinylstreamer leaving re-billed it again;
#   * the two modes shared no state.
#
# Part 1 replays that night, in order, with the real alert texts and findings.
# Part 2 forces the failures a dedup is most likely to introduce — silence is
# not a fix, so every "did not run" below is paired with a "still runs".

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/investigate.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
INCIDENTS="$AGENT_DIR/incidents"
ANOMALY="$AGENT_DIR/last_anomaly.json"
MARKER="$AGENT_DIR/.last_investigated"
CALLS="$WORK/opencode_calls"
PROMPTS="$WORK/prompts"
SLACK_FIXTURE="$WORK/slack.json"
COST_FILE="$WORK/cost"
FAIL_FILE="$WORK/fail"
mkdir -p "$AGENT_DIR" "$PROMPTS" "$WORK/bin" "$WORK/plans" "$WORK/fx"
: > "$CALLS"

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/investigate.sh" \
    agent_env_file="$WORK/agent.env" \
    agent_state_dir="$AGENT_DIR" \
    agent_plans_dir="$WORK/plans" \
    agent_failure_alert_cooldown_seconds=21600 \
    agent_run_timeout_seconds=600 \
    agent_slack_channel=C_TEST \
    agent_slack_max_per_run=3 \
    agent_incident_quiet_hours=26 \
    agent_incident_max_age_days=7 \
    agent_daily_spend_cap_usd=2.00 \
    agent_fleet_hosts=cobra:linux,dockassist:linux,hifipi:linux,vinylstreamer:linux,unifi:linux,cwwk:proxmox,opnsense:opnsense \
    opencode_bin="$WORK/bin/opencode" || exit 1

# ------------------------------------------------------------------
# Stubs. flock and timeout: macOS ships neither and neither is under test.
# curl answers the history poll from a fixture; webhooks are unset, so no
# post ever reaches it. opencode records each call and bills what COST_FILE
# says, so the ledger can be checked against real numbers.
# ------------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/flock"
cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -*) shift 2 ;;
        [0-9]*) shift ;;
        *) break ;;
    esac
done
exec "$@"
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in *conversations.history*) cat "$SLACK_FIXTURE" ;; esac
exit 0
STUB
cat > "$WORK/bin/opencode" <<'STUB'
#!/bin/sh
for a in "$@"; do last="$a"; done
cost=$(cat "$COST_FILE" 2>/dev/null || echo 0.25)
echo "$cost" >> "$CALLS"
n=$(wc -l < "$CALLS" | tr -d ' ')
printf '%s' "$last" > "$PROMPTS/$n.txt"
[ -f "$FAIL_FILE" ] && { echo "stub failure" >&2; exit 1; }
printf '%s\n' '{"type":"text","part":{"messageID":"m1","text":"===PLAN===\n# stub plan\n===SUMMARY===\nstub summary\n"}}'
printf '{"type":"step_finish","part":{"cost":%s}}\n' "$cost"
STUB
chmod +x "$WORK"/bin/*
printf 'ANTHROPIC_API_KEY=test\nSLACK_READ_TOKEN=test\n' > "$WORK/agent.env"

export SLACK_FIXTURE CALLS PROMPTS COST_FILE FAIL_FILE
PATH="$WORK/bin:$PATH"
export PATH

runs() { wc -l < "$CALLS" | tr -d ' '; }
last_prompt() { cat "$PROMPTS/$(runs).txt"; }

# poll <fixture> — one --slack run whose history returns the messages in
# <fixture>: blocks separated by a "---" line, first line the title, the rest
# the attachment text.
poll() {
    python3 - "$1" "$SLACK_FIXTURE" <<'PY'
import json, sys, time
msgs = []
for i, block in enumerate(open(sys.argv[1]).read().split("\n---\n")):
    block = block.strip("\n")
    if not block:
        continue
    title, _, att = block.partition("\n")
    m = {"ts": "%.6f" % (time.time() + i), "text": title}
    if att:
        m["attachments"] = [{"text": att}]
    msgs.append(m)
json.dump({"ok": True, "messages": msgs}, open(sys.argv[2], "w"))
PY
    "$SH" "$WORK/investigate.sh" --slack > "$WORK/out" 2>&1
}

# sweep_found "<finding>" ... — Tier 1 wrote a CHANGED snapshot, in its exact
# format. The marker is removed rather than racing mtimes; the -nt gate itself
# is pinned by anomaly_dedup_test.sh.
sweep_found() {
    {
        printf '{\n  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "hosts_total": 7,\n  "hosts_reachable": 7,\n'
        printf '  "finding_count": %s,\n  "findings": [\n' "$#"
        _i=0
        for _f in "$@"; do
            _i=$((_i + 1))
            [ "$_i" -gt 1 ] && printf ',\n'
            printf '    "%s"' "$_f"
        done
        printf '\n  ]\n}\n'
    } > "$ANOMALY"
    rm -f "$MARKER"
    "$SH" "$WORK/investigate.sh" > "$WORK/out" 2>&1
}

# expect <n-new-runs> <before> <description>
expect() {
    _got=$(( $(runs) - $2 ))
    if [ "$_got" -eq "$1" ]; then
        pass "$3 ($_got run)"
    else
        fail "$3 — expected $1 run(s), got $_got: $(tail -5 "$WORK/out")"
    fi
}

# age_incident <key> <opened_seconds_ago> <seen_seconds_ago>
age_incident() {
    _now=$(date +%s)
    printf '%s %s -\n' "$((_now - $2))" "$((_now - $3))" > "$INCIDENTS/$1"
}

# ------------------------------------------------------------------
# Real alert texts, 2026-09-13 (long health-check bodies trimmed; the lines
# that identify host and check are verbatim).
# ------------------------------------------------------------------
cat > "$WORK/fx/0007" <<'EOF'
:x: ALERT: Script Failed on hifipi
*Output:*
```==============================
System Health Check
Host: hifipi
OS: debian
Date: Sun 13 Sep 00:02:01 CEST 2026
==============================
=== Critical Services ===
[0;32m✅[0m Service mpd: running
[0;31m❌[0m Service raspotify: not running (4 checks over 36s)
=== Failed systemd Units ===
[0;31m❌[0m 1 failed unit(s)
     - raspotify.service
```
EOF
cat > "$WORK/fx/0107" <<'EOF'
:x: ALERT: Script Failed on hifipi
*Output:*
```❌ Raspotify service is not running - attempting restart
❌ Failed to restart Raspotify service```
Host: hifipi
Script: /home/choco/.scripts/check_raspotify.sh
Status: FAILED
Exit Code: 1
EOF
cat > "$WORK/fx/0207" <<'EOF'
:x: STILL FAILING on hifipi
*Output:*
```:repeat: Unchanged failure — 6 consecutive failing runs over 75 minute(s). Next reminder in 120 minute(s) unless the failure changes or clears.
==============================
System Health Check
Host: hifipi
[0;31m❌[0m Service raspotify: not running (4 checks over 36s)
```
---
:x: STILL FAILING on agent-lxc
*Output:*
```:repeat: Unchanged failure — 2 consecutive failing runs over 60 minute(s).
Fleet check found 1 issue(s) across 7 hosts:
❌ hifipi: 1 failed systemd unit(s): raspotify.service```
Host: agent-lxc
Script: /home/choco/.scripts/fleet_health_check.sh
---
:x: STILL FAILING on hifipi
*Output:*
```:repeat: Unchanged failure — 2 consecutive failing runs over 60 minute(s). Next reminder in 120 minute(s) unless the failure changes or clears.
❌ Raspotify service is not running - attempting restart
❌ Failed to restart Raspotify service```
Host: hifipi
Script: /home/choco/.scripts/check_raspotify.sh
EOF
cat > "$WORK/fx/0307" <<'EOF'
:x: STILL FAILING on hifipi
*Output:*
```:repeat: Unchanged failure — 14 consecutive failing runs over 195 minute(s). Next reminder in 240 minute(s) unless the failure changes or clears.
System Health Check
Host: hifipi
```
EOF
HIFIPI="hifipi: 1 failed systemd unit(s): raspotify.service"
VINYL="vinylstreamer: UNREACHABLE — no response at all (host down, or off the network)"

# ==================================================================
printf "\n── Part 1: replay of 2026-09-12/13 (was 6 runs, \$1.5701)\n"
# ==================================================================

b=$(runs); echo 0.1862 > "$COST_FILE"
poll "$WORK/fx/0007"
expect 1 "$b" "00:07 first alert about hifipi is investigated (was \$0.1862)"
if [ -f "$INCIDENTS/host-hifipi" ]; then
    pass "the investigation opens a host-keyed incident"
else
    fail "no incident recorded — nothing downstream can dedup against it"
fi

b=$(runs); echo 0.2345 > "$COST_FILE"
sweep_found "$HIFIPI"
expect 0 "$b" "00:47 Tier 1 finding on the same host is not re-billed across modes (was \$0.2345)"
if grep -q 'belongs to an open incident' "$WORK/out"; then
    pass "the skip is logged with its reason"
else
    fail "the skip is silent — indistinguishable from a broken cron"
fi

b=$(runs); echo 0.2176 > "$COST_FILE"
poll "$WORK/fx/0107"
expect 0 "$b" "01:07 a DIFFERENT check (check_raspotify) on the same host is the same incident (was \$0.2176)"

b=$(runs); echo 0.2421 > "$COST_FILE"
poll "$WORK/fx/0207"
expect 0 "$b" "02:07 STILL FAILING reminders are the same incident (was \$0.2421)"

b=$(runs)
poll "$WORK/fx/0307"
expect 0 "$b" "03:07 later reminders stay free"

b=$(runs); echo 0.4194 > "$COST_FILE"
sweep_found "$HIFIPI" "$VINYL"
expect 1 "$b" "06:47 a NEW host joining the finding set is investigated (was \$0.4194)"
if last_prompt | grep -q 'vinylstreamer: UNREACHABLE'; then
    pass "the prompt carries the new host's finding"
else
    fail "the new finding is missing from the prompt"
fi
if last_prompt | grep -q '^- hifipi:'; then
    fail "the already-explained host was handed to the agent again"
else
    pass "the already-explained host's finding is not re-investigated"
fi
if last_prompt | grep -q 'also named hifipi'; then
    pass "the agent is told hifipi is already covered, so it can still correlate"
else
    fail "the prompt does not mention the covered host at all"
fi

b=$(runs); echo 0.2703 > "$COST_FILE"
sweep_found "$HIFIPI"
expect 0 "$b" "09:47 a host LEAVING the finding set re-bills nothing (was \$0.2703)"

ledger=$(cat "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)" 2>/dev/null)
if [ "$ledger" = "0.6056" ]; then
    pass "replay spend: 2 runs, \$0.6056 (was 6 runs, \$1.5701) — ledger agrees"
else
    fail "ledger reads '$ledger', expected 0.6056"
fi

# ==================================================================
printf '\n── Part 2: the dedup must still let real signal through\n'
# ==================================================================
echo 0.25 > "$COST_FILE"

cat > "$WORK/fx/cobra" <<'EOF'
:x: ALERT: Script Failed on cobra
*Output:*
```❌ Disk usage 97%```
Host: cobra
EOF
b=$(runs)
poll "$WORK/fx/cobra"
expect 1 "$b" "a different host's alert is investigated"

age_incident host-hifipi 97200 97200   # opened and last named 27h ago
b=$(runs)
poll "$WORK/fx/0307"
expect 1 "$b" "hifipi recurring after the quiet window is re-investigated"

age_incident host-hifipi 90000 90000   # 25h: reminders backed off, not resolved
b=$(runs)
poll "$WORK/fx/0307"
expect 0 "$b" "a reminder 25h into a fault is still the same incident"
seen=$(cut -d' ' -f2 "$INCIDENTS/host-hifipi")
if [ $(( $(date +%s) - seen )) -lt 60 ]; then
    pass "that reminder refreshed the incident's last-seen time"
else
    fail "a reminder did not refresh the incident — it lapses mid-fault and re-bills"
fi

age_incident host-hifipi 691200 3600   # 8 days old, named an hour ago
b=$(runs)
poll "$WORK/fx/0307"
expect 1 "$b" "an incident past max age gets a fresh look even though it never went quiet"

cat > "$WORK/fx/burst" <<'EOF'
:x: ALERT: Script Failed on dockassist
Host: dockassist
---
:x: ALERT: Script Failed on unifi
Host: unifi
EOF
b=$(runs)
poll "$WORK/fx/burst"
expect 1 "$b" "two new hosts in one poll share ONE investigation"
if last_prompt | grep -q 'host-dockassist' && last_prompt | grep -q 'host-unifi'; then
    pass "that one prompt carries both incidents"
else
    fail "an incident was dropped from the batched prompt"
fi
if [ -f "$INCIDENTS/host-dockassist" ] && [ -f "$INCIDENTS/host-unifi" ]; then
    pass "both incidents are opened by the one run"
else
    fail "a batched incident was not opened — it would be re-billed next poll"
fi

cat > "$WORK/fx/ha_vinyl" <<'EOF'
⚠️ vinylstreamer offline 20 min — its plug is switched OFF, which explains it.
EOF
b=$(runs)
poll "$WORK/fx/ha_vinyl"
expect 0 "$b" "an HA alert naming a fleet host joins that host's open incident"

cat > "$WORK/fx/ha_heating" <<'EOF'
:rotating_light: Heating offline — 3 thermostats unavailable
EOF
b=$(runs)
poll "$WORK/fx/ha_heating"
expect 1 "$b" "an alert naming no host is still investigated"
b=$(runs)
poll "$WORK/fx/ha_heating"
expect 0 "$b" "...and deduped against its own repeat"

cat > "$WORK/fx/cwwk" <<'EOF'
:x: ALERT: Script Failed on cwwk
Host: cwwk
EOF
touch "$FAIL_FILE"
b=$(runs)
poll "$WORK/fx/cwwk"
expect 1 "$b" "a failing agent run is attempted"
rm -f "$FAIL_FILE"
if [ -f "$INCIDENTS/host-cwwk" ]; then
    fail "a FAILED run opened the incident — the fault would never be explained"
else
    pass "a failed run leaves the incident unopened"
fi
b=$(runs)
poll "$WORK/fx/cwwk"
expect 1 "$b" "the next alert about it is retried"

# Part 2 has spent past the cap by now; clear it, or the cap refuses this case
# and it passes or fails for a reason that has nothing to do with parsing.
rm -f "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"
sweep_found "no host prefix in this finding"
if grep -q 'investigating new anomaly: unparsed snapshot' "$WORK/out"; then
    pass "a snapshot whose hosts cannot be parsed is investigated, not swallowed"
else
    fail "an unparseable snapshot was swallowed: $(tail -3 "$WORK/out")"
fi

# --- spend cap -------------------------------------------------------
echo 2.0000 > "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"
cat > "$WORK/fx/opnsense" <<'EOF'
:x: ALERT: Script Failed on opnsense
Host: opnsense
EOF
b=$(runs)
poll "$WORK/fx/opnsense"
expect 0 "$b" "at the daily cap a new Slack incident is not investigated"
if grep -q 'daily spend cap' "$WORK/out"; then
    pass "the cap says so in the log"
else
    fail "the cap refused silently"
fi
b=$(runs)
sweep_found "opnsense: disk usage 99%"
expect 0 "$b" "at the daily cap a new anomaly is not investigated"
if [ -f "$MARKER" ]; then
    fail "the capped anomaly was marked handled — it would never be investigated"
else
    pass "the capped anomaly stays pending"
fi
echo 1.0000 > "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"
b=$(runs)
"$SH" "$WORK/investigate.sh" > "$WORK/out" 2>&1
expect 1 "$b" "below the cap, that pending anomaly is investigated"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
