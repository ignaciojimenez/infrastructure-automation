#!/bin/sh
# Regression test: one fault buys one Tier 2 investigation, not one per message —
# and a DIFFERENT fault on the same host is still investigated.
#
# Runs on the laptop — no container, no Slack, no network, no spend. The real
# investigate.sh is rendered and driven against stubbed Slack and opencode.
#
#   tests/unit/incident_dedup_test.sh
#   TEMPLATE=<other investigate.sh.j2> tests/unit/incident_dedup_test.sh   # control
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
# Keying on the host alone fixed that night and broke something else: a second,
# unrelated fault on hifipi would have paged with no plan. So incidents are keyed
# (host, subject), and Part 1b forces exactly that case.
#
# Part 1 replays that night, in order, with real-shaped messages (title in
# `text`, Output in the attachment text, Host/Script in attachment fields).
# Part 2 forces the failures a dedup is most likely to introduce — silence is
# not a fix, so every "did not run" below is paired with a "still runs".

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE=${TEMPLATE:-"$REPO_ROOT/scripts/services/agent/investigate.sh.j2"}
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
    agent_incident_subjects_py="$REPO_ROOT/scripts/services/agent/incident_subjects.py" \
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
    agent_model_run="$WORK/bin/opencode" || exit 1

# ------------------------------------------------------------------
# Stubs. flock: macOS does not ship it and it is not under test.
# curl answers the history poll from a fixture; webhooks are unset, so no
# post ever reaches it. opencode records each call and bills what COST_FILE
# says, so the ledger can be checked against real numbers.
# ------------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/flock"
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
has_incident() { ls "$INCIDENTS/$1".* >/dev/null 2>&1; }
incident_list() {
    for _f in "$INCIDENTS"/*; do
        [ -f "$_f" ] && printf '%s ' "${_f##*/}"
    done
}

# poll <fixture> — one --slack run whose history returns the messages in
# <fixture>: blocks separated by a "---" line, first line the title, the rest
# the attachment. Lines AFTER the Output block's closing ``` that look like
# "Host: …" / "Script: …" become attachment FIELDS, as the wrapper sends them;
# a "Host:" inside the Output (system_health_check prints one) stays text.
poll() {
    python3 - "$1" "$SLACK_FIXTURE" <<'PY'
import json, re, sys, time
FIELD = re.compile(r"^(Host|Script|Started|Duration|Status|Exit Code): (.*)$")
msgs = []
for i, block in enumerate(open(sys.argv[1]).read().split("\n---\n")):
    block = block.strip("\n")
    if not block:
        continue
    title, _, att = block.partition("\n")
    m = {"ts": "%.6f" % (time.time() + i), "text": title}
    if att:
        cut = att.rfind("```")
        head, tail = (att[:cut + 3], att[cut + 3:]) if cut >= 0 else ("", att)
        text_lines, fields = [], []
        for line in tail.split("\n"):
            f = FIELD.match(line)
            if f:
                fields.append({"title": f.group(1), "value": f.group(2), "short": True})
            elif line:
                text_lines.append(line)
        a = {"text": "\n".join([head] + text_lines).strip("\n")}
        if fields:
            a["fields"] = fields
        m["attachments"] = [a]
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
# Real-shaped alerts, 2026-09-13 (long health-check bodies trimmed; the lines
# that identify host, check and unit are verbatim, ANSI colour codes included).
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
Host: hifipi
Script: /home/choco/.scripts/system_health_check.sh
Status: FAILED
Exit Code: 1
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
Host: hifipi
Script: /home/choco/.scripts/system_health_check.sh
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
# The wrapper cuts Output at 1500 chars, which lands inside the failed-unit
# list on a real health check (seen 01:17: "- raspo..."). The cut line must be
# ignored, not keyed as a bogus subject called "raspo".
cat > "$WORK/fx/0307" <<'EOF'
:x: STILL FAILING on hifipi
*Output:*
```:repeat: Unchanged failure — 14 consecutive failing runs over 195 minute(s). Next reminder in 240 minute(s) unless the failure changes or clears.
System Health Check
Host: hifipi
[0;32m✅[0m Service shairport-sync: running
[0;31m❌[0m Service raspotify: not running (4 checks over 36s)
=== Failed systemd Units ===
[0;31m❌[0m 1 failed unit(s)
     - raspo...
```
Host: hifipi
Script: /home/choco/.scripts/system_health_check.sh
EOF
HIFIPI="hifipi: 1 failed systemd unit(s): raspotify.service"
VINYL="vinylstreamer: UNREACHABLE — no response at all (host down, or off the network)"

# ==================================================================
printf "\n── Part 1: replay of 2026-09-12/13 (was 6 runs, \$1.5701)\n"
# ==================================================================

b=$(runs); echo 0.1862 > "$COST_FILE"
poll "$WORK/fx/0007"
expect 1 "$b" "00:07 first alert about hifipi is investigated (was \$0.1862)"
if [ -f "$INCIDENTS/hifipi.raspotify" ]; then
    pass "the health check's named unit opens incident hifipi.raspotify"
else
    fail "no hifipi.raspotify incident: $(incident_list)"
fi

b=$(runs); echo 0.2345 > "$COST_FILE"
sweep_found "$HIFIPI"
expect 0 "$b" "00:47 Tier 1 finding naming the same unit is not re-billed across modes (was \$0.2345)"
if grep -q 'belongs to an open incident' "$WORK/out"; then
    pass "the skip is logged with its reason"
else
    fail "the skip is silent — indistinguishable from a broken cron"
fi

b=$(runs); echo 0.2176 > "$COST_FILE"
poll "$WORK/fx/0107"
expect 0 "$b" "01:07 check_raspotify is the same subject as the health check's raspotify.service (was \$0.2176)"

b=$(runs); echo 0.2421 > "$COST_FILE"
poll "$WORK/fx/0207"
expect 0 "$b" "02:07 STILL FAILING reminders are the same incident (was \$0.2421)"

b=$(runs)
poll "$WORK/fx/0307"
expect 0 "$b" "03:07 a reminder whose unit list was truncated stays free"
if [ -f "$INCIDENTS/hifipi.raspo" ]; then
    fail "the truncated '- raspo...' line was keyed as a subject"
else
    pass "the truncated unit line is ignored, not keyed"
fi

b=$(runs); echo 0.4194 > "$COST_FILE"
sweep_found "$HIFIPI" "$VINYL"
expect 1 "$b" "06:47 a NEW host joining the finding set is investigated (was \$0.4194)"
if last_prompt | grep -q 'vinylstreamer: UNREACHABLE'; then
    pass "the prompt carries the new host's finding"
else
    fail "the new finding is missing from the prompt"
fi
if last_prompt | grep -q '^- hifipi:'; then
    fail "the already-explained finding was handed to the agent again"
else
    pass "the already-explained finding is not re-investigated"
fi
if last_prompt | grep -q 'hifipi.raspotify — plan: '; then
    pass "the agent is told hifipi.raspotify is already covered, with its plan, so it can still correlate"
else
    fail "the prompt does not list the covered incident"
fi
if [ -f "$INCIDENTS/vinylstreamer.reachability" ]; then
    pass "the unreachable finding opens vinylstreamer.reachability"
else
    fail "no vinylstreamer.reachability incident: $(incident_list)"
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
printf '\n── Part 1b: a DIFFERENT fault on the same host is not hidden\n'
# ==================================================================
# hifipi.raspotify is open from Part 1. Each case below is a fault on hifipi
# that has nothing to do with raspotify, and must buy its own plan.
echo 0.25 > "$COST_FILE"

cat > "$WORK/fx/mpd" <<'EOF'
:x: ALERT: Script Failed on hifipi
*Output:*
```❌ MPD is not running - attempting restart```
Host: hifipi
Script: /home/choco/.scripts/check_mpd.sh
EOF
b=$(runs)
poll "$WORK/fx/mpd"
expect 1 "$b" "an UNRELATED check failing on hifipi while hifipi.raspotify is open is investigated"
if last_prompt | grep -q 'hifipi.raspotify — plan: '; then
    pass "its prompt lists the open raspotify incident and plan, so a shared cause can still be named"
else
    fail "the prompt does not mention the host's open incident"
fi
if last_prompt | grep -q 'hifipi.mpd — plan'; then
    fail "the new incident was listed as already covered"
else
    pass "the new incident is not listed as covered"
fi
if [ -f "$INCIDENTS/hifipi.mpd" ]; then
    pass "it opens hifipi.mpd"
else
    fail "no hifipi.mpd incident"
fi

cat > "$WORK/fx/shairport" <<'EOF'
:x: ALERT: Script Failed on hifipi
*Output:*
```System Health Check
Host: hifipi
[0;31m❌[0m Service raspotify: not running (4 checks over 36s)
[0;31m❌[0m Service shairport-sync: not running (4 checks over 36s)
=== Failed systemd Units ===
[0;31m❌[0m 2 failed unit(s)
     - raspotify.service
     - shairport-sync.service
```
Host: hifipi
Script: /home/choco/.scripts/system_health_check.sh
EOF
b=$(runs)
poll "$WORK/fx/shairport"
expect 1 "$b" "a health check adding a second failed unit to hifipi investigates the new unit"
if last_prompt | grep -q '\[hifipi.shairport-sync\]'; then
    pass "that run is about hifipi.shairport-sync"
else
    fail "the new unit's incident is not what was investigated"
fi
if last_prompt | grep -q '\[hifipi.raspotify\]'; then
    fail "the already-open raspotify unit was re-investigated alongside it"
else
    pass "the already-open raspotify unit is not re-investigated alongside it"
fi

b=$(runs)
poll "$WORK/fx/shairport"
expect 0 "$b" "...and its repeat, naming both open units, is free"
b=$(runs)
sweep_found "hifipi: 2 failed systemd unit(s): raspotify.service shairport-sync.service"
expect 0 "$b" "...as is a Tier 1 finding naming both units"

cat > "$WORK/fx/disk" <<'EOF'
:x: ALERT: Script Failed on hifipi
*Output:*
```System Health Check
Host: hifipi
[0;31m❌[0m Disk /: 97%
```
Host: hifipi
Script: /home/choco/.scripts/system_health_check.sh
EOF
b=$(runs)
poll "$WORK/fx/disk"
expect 1 "$b" "a health check failing on something that is not a unit (disk) is its own incident"

# Part 1b spent past what Part 2 assumes; start Part 2 from an empty ledger.
rm -f "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"

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

age_incident hifipi.raspotify 97200 97200   # opened and last named 27h ago
b=$(runs)
poll "$WORK/fx/0307"
expect 1 "$b" "hifipi.raspotify recurring after the quiet window is re-investigated"

age_incident hifipi.raspotify 90000 90000   # 25h: reminders backed off, not resolved
b=$(runs)
poll "$WORK/fx/0307"
expect 0 "$b" "a reminder 25h into a fault is still the same incident"
seen=$(cut -d' ' -f2 "$INCIDENTS/hifipi.raspotify")
if [ $(( $(date +%s) - seen )) -lt 60 ]; then
    pass "that reminder refreshed the incident's last-seen time"
else
    fail "a reminder did not refresh the incident — it lapses mid-fault and re-bills"
fi

age_incident hifipi.raspotify 691200 3600   # 8 days old, named an hour ago
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
if last_prompt | grep -q '\[dockassist\.' && last_prompt | grep -q '\[unifi\.'; then
    pass "that one prompt carries both incidents"
else
    fail "an incident was dropped from the batched prompt"
fi
if has_incident dockassist && has_incident unifi; then
    pass "both incidents are opened by the one run"
else
    fail "a batched incident was not opened — it would be re-billed next poll"
fi

cat > "$WORK/fx/ha_vinyl" <<'EOF'
⚠️ vinylstreamer offline 20 min — its plug is switched OFF, which explains it.
EOF
b=$(runs)
poll "$WORK/fx/ha_vinyl"
expect 0 "$b" "an HA 'offline' alert joins Tier 1's open vinylstreamer.reachability incident"

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
if has_incident cwwk; then
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

# ==================================================================
printf "\n── Part 3: replay of 2026-09-21 (was 2 runs, \$1.1712) — PER-58\n"
# ==================================================================
# One radiator went unavailable and two senders said so an hour of polls
# apart: HA's own automation at 15:02 (in the 15:07 poll) and the wrapper
# around check_ha_entities at 15:10:07, just after that poll had read the
# channel (so in the 16:07 one). HA's text named no host and keyed "alert-…";
# the wrapper keyed dockassist.ha-entities. The fix is at the sender: the
# automations that overlap that check now carry a tag naming its incident.
#
# Since PER-184 that incident is the DEVICE: the check ends each alert line
# "— device: <name>", and the tag is an HA Jinja expression that names the
# same device. The expression is read from the template itself and "rendered"
# here by substituting the device name, so a fixture cannot keep passing after
# the real message has changed. HA's own rendering is proven live.
rm -f "$INCIDENTS"/* "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"
AUTOMATIONS="$REPO_ROOT/ansible/roles/services/homeassistant/templates/automations.yaml.j2"
TAG_EXPR=$(sed -n 's/^{% set ha_entities_incident = "\(.*\)" %}$/\1/p' "$AUTOMATIONS" \
    | sed 's/" ~ inventory_hostname ~ "/dockassist/')
# The device is picked in the order the check picks it (user-given name, else
# HA's own, else the entity id). Different orders would key one fault twice.
DEVICE_EXPR="(device_attr(trigger.entity_id, 'name_by_user') or device_attr(trigger.entity_id, 'name') or trigger.entity_id)"
case "$TAG_EXPR" in
    *"Host: dockassist"*"Subject: ha-' ~ $DEVICE_EXPR ~ ')'") pass "automations.yaml.j2 tags the incident by device: $TAG_EXPR" ;;
    *) fail "no usable ha_entities_incident tag in automations.yaml.j2: '$TAG_EXPR'" ;;
esac
# tag_for <device name> — the text HA renders for that device.
tag_for() {
    python3 - "$TAG_EXPR" "$DEVICE_EXPR" "$1" <<'PY'
import sys
expr, dev, name = sys.argv[1:4]
expr = expr.replace(dev, "'" + name + "'").replace("' ~ '", "")
print(expr.strip().strip("'"))
PY
}
RADIATOR="tado° Smart Radiator Thermostat VA0612513536"
TAG=$(tag_for "$RADIATOR")

# Verbatim from #home-alerts, ts 1789995739 and 1789996207, plus the tag and
# the device tail. The device name is the shape HomeKit gives a tado head;
# the live replay uses the real one.
printf ':warning: Heating offline: Bathroom Radiator%s\n' "$TAG" > "$WORK/fx/ha_radiator"
cat > "$WORK/fx/ha_entities" <<EOF
:x: ALERT: Script Failed on dockassist
*Output:*
\`\`\`=== Home Assistant entity health ===
299 entities; 67 unavailable/unknown (63 allowlisted, 0 inside grace)
❌ climate.tado_smart_radiator_thermostat_va0612513536 = unavailable for 20 min (past its 15 min grace) — device: $RADIATOR
❌ select.tado_smart_radiator_thermostat_va0612513536_temperature_display_units = unavailable for 20 min (past its 15 min grace) — device: $RADIATOR
❌ sensor.tado_smart_radiator_thermostat_va0612513536_current_humidity = unavailable for 20 min (past its 15 min grace) — device: $RADIATOR
❌ sensor.tado_smart_radiator_thermostat_va0612513536_current_temperature = unavailable for 20 min (past its 15 min grace) — device: $RADIATOR\`\`\`
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
Started: 2026-09-21 15:10:04
Duration: 1 seconds
Status: FAILED
Exit Code: 4
Enhanced Monitoring Wrapper • 2026-09-21 15:10:05
EOF

b=$(runs); echo 0.6926 > "$COST_FILE"
poll "$WORK/fx/ha_radiator"
expect 1 "$b" "15:07 HA's 'Heating offline' is investigated (was \$0.6926)"
RADIATOR_KEY=dockassist.ha-tado-smart-radiator-thermostat-va0612513536
if [ -f "$INCIDENTS/$RADIATOR_KEY" ]; then
    pass "it opens the device's incident, $RADIATOR_KEY"
else
    fail "HA's alert did not key to $RADIATOR_KEY: $(incident_list)"
fi
if [ -f "$INCIDENTS/dockassist.reachability" ]; then
    fail "a device going offline was keyed as dockassist itself being unreachable"
else
    pass "a device going offline is not keyed as the host being unreachable"
fi

b=$(runs); echo 0.4786 > "$COST_FILE"
poll "$WORK/fx/ha_entities"
expect 0 "$b" "16:07 check_ha_entities on the same radiator is not re-billed (was \$0.4786)"

ledger=$(cat "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)" 2>/dev/null)
if [ "$ledger" = "0.6926" ]; then
    pass "replay spend: 1 run, \$0.6926 (was 2 runs, \$1.1712) — ledger agrees"
else
    fail "ledger reads '$ledger', expected 0.6926"
fi

# The other order: the check pages first, HA's alert follows.
rm -f "$INCIDENTS"/*
echo 0.25 > "$COST_FILE"
b=$(runs)
poll "$WORK/fx/ha_entities"
poll "$WORK/fx/ha_radiator"
expect 1 "$b" "check first, HA's alert second: still one run"

# The other two automations carrying the tag. Each joins the incident the
# check opened for ITS device, and is not swallowed by the radiator's.
SMOKE="Hallway Smoke"
printf ':warning: Smoke detector OFFLINE (not reporting) — Hallway%s\n' "$(tag_for "$SMOKE")" > "$WORK/fx/ha_smoke"
cat > "$WORK/fx/ha_entities_smoke" <<EOF
:x: ALERT: Script Failed on dockassist
*Output:*
\`\`\`❌ binary_sensor.shellyplussmoke_3076f523fd68_smoke = unavailable for 1560 min (past its 1560 min grace) — device: $SMOKE\`\`\`
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
b=$(runs)
poll "$WORK/fx/ha_smoke"
expect 1 "$b" "a smoke detector gone unavailable while the radiator's incident is open is investigated (PER-184)"
b=$(runs)
poll "$WORK/fx/ha_entities_smoke"
expect 0 "$b" "the check's alert for that smoke detector joins the incident HA's alert opened"
GAS="shellygas-8c4f0059f510"
cat > "$WORK/fx/ha_entities_gas" <<EOF
:x: ALERT: Script Failed on dockassist
*Output:*
\`\`\`❌ sensor.shellygas_8c4f0059f510_operation = unavailable for 20 min (past its 15 min grace) — device: $GAS\`\`\`
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
printf ':warning: Gas detector FAULT/OFFLINE — Kitchen (state: unavailable)%s\n' "$(tag_for "$GAS")" > "$WORK/fx/ha_gas_gone"
b=$(runs)
poll "$WORK/fx/ha_entities_gas"
poll "$WORK/fx/ha_gas_gone"
expect 1 "$b" "check first, then HA's gas alert for the same device: one run"

# ...and what the tag must NOT swallow.
printf ':warning: Gas detector FAULT/OFFLINE — Kitchen (state: fault)\n' > "$WORK/fx/ha_gas_fault"
b=$(runs)
poll "$WORK/fx/ha_gas_fault"
expect 1 "$b" "a gas detector reporting FAULT (untagged: the check cannot see it) is still investigated"
cat > "$WORK/fx/ha_web" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```❌ Home Assistant web UI not responding```
Host: dockassist
Script: /home/choco/.scripts/check_ha_web.sh
EOF
b=$(runs)
poll "$WORK/fx/ha_web"
expect 1 "$b" "a different check failing on dockassist while HA device incidents are open is investigated"
cat > "$WORK/fx/openssl" <<'EOF'
:x: ALERT: Script Failed on cobra
*Output:*
```❌ certificate expired
        Subject: cn = cobra.local```
Host: cobra
Script: /home/choco/.scripts/check_cert.sh
EOF
poll "$WORK/fx/openssl"
if [ -f "$INCIDENTS/cobra.cert" ] && [ ! -f "$INCIDENTS/cobra.cn" ]; then
    pass "a 'Subject:' inside a check's output is not taken as the incident subject"
else
    fail "a check's output chose the subject: $(incident_list)"
fi

# ==================================================================
printf "\n── Part 4: replay of 2026-11-10/11 (was 1 run, the door never looked at) — PER-184\n"
# ==================================================================
# check_ha_entities keyed every alert by its own name, dockassist.ha-entities.
# The 11-11 Eve door drop arrived inside the quiet window of the 11-10 Shelly
# bulb incident and was never investigated. Both bodies are verbatim from
# #home-alerts (ts 1794268811 and 1794421207). They predate the device tail,
# so they key by entity id; the tagged shape is forced after them.
rm -f "$INCIDENTS"/* "$AGENT_DIR/spend/$(date -u +%Y-%m-%d)"
echo 0.30 > "$COST_FILE"
cat > "$WORK/fx/shelly_1110" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```=== Home Assistant entity health ===
262 entities; 43 unavailable/unknown (38 allowlisted, 0 inside grace)
❌ button.shellyduobulbg3_48f6eebd40d4_restart = unavailable for 20 min (past its 15 min grace)
❌ light.floor_lamp_new = unavailable for 20 min (past its 15 min grace)
❌ sensor.shellyduobulbg3_48f6eebd40d4_energy = unavailable for 20 min (past its 15 min grace)
❌ sensor.shellyduobulbg3_48f6eebd40d4_power = unavailable for 20 min (past its 15 min grace)
❌ update.shellyduobulbg3_48f6eebd40d4_firmware = unavailable for 20 min (past its 15 min grace)```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
Started: 2026-11-10 01:00:08
Duration: 1 seconds
Status: FAILED
Exit Code: 5
EOF
cat > "$WORK/fx/eve_1111" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```=== Home Assistant entity health ===
266 entities; 41 unavailable/unknown (35 allowlisted, 5 inside grace)
⚠️  binary_sensor.eve_door_20ebn9901_door_2 = unavailable for 19 min (grace 1440 min)
⚠️  button.eve_door_20ebn9901_identify_2 = unavailable for 19 min (grace 1440 min)
⚠️  sensor.eve_door_20ebn9901_battery_2 = unavailable for 19 min (grace 1440 min)
⚠️  sensor.eve_door_20ebn9901_battery_voltage_2 = unavailable for 19 min (grace 1440 min)
⚠️  update.eve_door_20ebn9901_firmware_2 = unavailable for 19 min (grace 1440 min)
❌ binary_sensor.entrance_door_battery = unavailable for 19 min (past its 15 min grace)```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
Started: 2026-11-11 19:20:05
Duration: 0 seconds
Status: FAILED
Exit Code: 1
EOF
b=$(runs)
poll "$WORK/fx/shelly_1110"
expect 1 "$b" "11-10 01:00 the Shelly bulb is investigated"
b=$(runs)
poll "$WORK/fx/eve_1111"
expect 1 "$b" "11-11 19:20 the Eve door, a different device under the same check, is investigated (was skipped)"
if [ -f "$INCIDENTS/dockassist.ha-binary-sensor-entrance-door-battery" ]; then
    pass "the door keys by what failed: dockassist.ha-binary-sensor-entrance-door-battery"
else
    fail "the door did not key by its entity: $(incident_list)"
fi
if [ -f "$INCIDENTS/dockassist.ha-entities" ]; then
    fail "an entity alert still keyed by the script name: $(incident_list)"
else
    pass "no entity alert keys as dockassist.ha-entities any more"
fi
b=$(runs)
printf ':x: STILL FAILING on dockassist\n%s\n' "$(sed 1d "$WORK/fx/eve_1111")" > "$WORK/fx/eve_repeat"
poll "$WORK/fx/eve_repeat"
expect 0 "$b" "the door failing again: no new run (fleet-investigation-duplicates-one-root-cause)"
# Not asserted: replayed untagged, the bulb is five entity keys, and one run
# takes at most agent_slack_max_per_run (3) new keys, so its repeat buys a
# second run for the other two. The device tail below is what makes it one
# key. Entities with no device, or a failed device lookup, still key per
# entity, with that same cost.

# The tagged shape: one bulb is one incident, whichever entities it loses and
# whichever bad state they sit in.
rm -f "$INCIDENTS"/*
cat > "$WORK/fx/bulb_a" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```❌ button.shellyduobulbg3_48f6eebd40d4_restart = unavailable for 20 min (past its 15 min grace) — device: Floor Lamp
❌ light.floor_lamp_new = unavailable for 20 min (past its 15 min grace) — device: Floor Lamp
❌ sensor.shellyduobulbg3_48f6eebd40d4_power = unavailable for 20 min (past its 15 min grace) — device: Floor Lamp```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
cat > "$WORK/fx/bulb_b" <<'EOF'
:x: STILL FAILING on dockassist
*Output:*
```device grace 1440 min for 'Eve Door 20EBN9901': 12 entities
❌ light.floor_lamp_new = unknown for 80 min (past its 15 min grace) — device: Floor Lamp
❌ update.shellyduobulbg3_48f6eebd40d4_firmware = unavailable for 80 min (past its 15 min grace) — device: Floor Lamp```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
b=$(runs)
poll "$WORK/fx/bulb_a"
poll "$WORK/fx/bulb_b"
expect 1 "$b" "one bulb, five entities, unavailable then unknown: one run"
if [ "$(incident_list)" = "dockassist.ha-floor-lamp " ]; then
    pass "its only incident is dockassist.ha-floor-lamp (the device grace line keys nothing)"
else
    fail "the bulb opened: $(incident_list)"
fi

# The check's own failures key to fixed subjects, never to their error text.
cat > "$WORK/fx/lookup_a" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```❌ device lookup failed (HTTP 500 from /api/template) — device-scoped grace windows NOT applied```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
sed 's#HTTP 500 from /api/template#/api/template mapped no entity to a device#' "$WORK/fx/lookup_a" > "$WORK/fx/lookup_b"
b=$(runs)
poll "$WORK/fx/lookup_a"
poll "$WORK/fx/lookup_b"
expect 1 "$b" "a device lookup failing two different ways: one run"
if [ -f "$INCIDENTS/dockassist.ha-device-lookup" ]; then
    pass "it keys as dockassist.ha-device-lookup"
else
    fail "the lookup failure keyed as: $(incident_list)"
fi
cat > "$WORK/fx/ha_api" <<'EOF'
:x: ALERT: Script Failed on dockassist
*Output:*
```❌ Home Assistant API unreachable for 22 min (HTTP 000) — entity health is UNKNOWN, not healthy```
Host: dockassist
Script: /home/choco/.scripts/check_ha_entities.sh
EOF
poll "$WORK/fx/ha_api"
if [ -f "$INCIDENTS/dockassist.ha-api" ] && [ ! -f "$INCIDENTS/dockassist.reachability" ]; then
    pass "HA's API down keys as dockassist.ha-api, not as dockassist itself unreachable"
else
    fail "HA's API down keyed as: $(incident_list)"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
