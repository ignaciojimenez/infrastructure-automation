#!/bin/sh
# Regression test: check_presence_health.sh pages when a phone has stopped
# feeding Home Assistant, and only then.
#
# Runs on the laptop — no container, no Home Assistant. The template's embedded
# Python is extracted and pointed at a stub HA on 127.0.0.1 that serves
# /api/states from a fixture file.
#
#   tests/unit/presence_health_test.sh
#
# The rule (2026-11-24, PER-197): a phone is live if ANY of its entities — the
# tracker or a sensor named after the same device — reported within the
# threshold, home or away. Every quiet case has a loud twin: a fix that went
# quiet by never paging would pass the quiet half alone.
#
# History the cases pin:
#   PER-57     a phone indoors for 18–32 h without a location paged as frozen
#   2026-10-04 an HA restart re-stamped every entity and cleared a real page
#   PER-172    a retired phone still attached to a person paged for days
#   2026-11-23 a phone at rest, not charged, silent 30.5 h on every entity

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/homeassistant/check_presence_health.sh.j2"
RENDERER="$REPO_ROOT/tests/lib/render_j2.py"
WORK=$(mktemp -d)
STUB_PID=""
trap '[ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── presence health: page when a phone stops reporting, on any of its entities\n'

[ -f "$TEMPLATE" ] || { printf '   ✗ template not found: %s\n' "$TEMPLATE"; exit 1; }

# ------------------------------------------------------------------
# 0. The shipped file renders and is valid shell.
# ------------------------------------------------------------------
if python3 "$RENDERER" "$TEMPLATE" "$WORK/check.sh" \
        homeassistant_config_dir=/home/tester/homeassistant \
        presence_stale_hours=20 \
        presence_last_seen_state_file=/home/tester/.log/presence_last_seen.json \
        presence_ignore_persons=person.ai_agent \
        homeassistant_container_name=home-assistant \
        2>"$WORK/render.err"; then
    pass "template renders with no unhandled Jinja"
else
    fail "template did not render: $(cat "$WORK/render.err")"
fi

if [ -f "$WORK/check.sh" ] && sh -n "$WORK/check.sh" 2>"$WORK/shn.err"; then
    pass "rendered script is valid POSIX shell (sh -n)"
else
    fail "rendered script is not valid shell: $(cat "$WORK/shn.err" 2>/dev/null)"
fi

python3 - "$TEMPLATE" "$WORK/check.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
blocks = re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.S)
if len(blocks) != 1:
    sys.exit("expected exactly one PYEOF block, found %d" % len(blocks))
# The block is Jinja too (one comment interpolates the threshold); render it.
open(sys.argv[2], "w").write(blocks[0].replace("{{ presence_stale_hours }}", "20"))
PY
[ -s "$WORK/check.py" ] || { printf '   ✗ could not extract the Python block\n'; exit 1; }

# ------------------------------------------------------------------
# Stub Home Assistant: serves $FIX/states.json, re-read on every request.
# ------------------------------------------------------------------
FIX="$WORK/fix"
mkdir -p "$FIX"

cat > "$WORK/stub.py" <<'PY'
import os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIX = sys.argv[1]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/api/states":
            try:
                body = open(os.path.join(FIX, "states.json")).read().encode()
            except OSError:
                body = b"[]"
            self.send_response(200)
        else:
            body = b"{}"
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(FIX, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

python3 "$WORK/stub.py" "$FIX" &
STUB_PID=$!
i=0
while [ ! -s "$FIX/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$FIX/port" ] || { printf '   ✗ stub HA did not start\n'; exit 1; }
HA_URL="http://127.0.0.1:$(cat "$FIX/port")"

STATE="$WORK/last_seen.json"

# world [person_state=home] <entity spec>...
# One person, Candela. Each spec is <entity_id>|<friendly name>|<state>|<hours ago>.
# Every device_tracker in the specs is attached to the person; `|missing` as the
# state attaches a tracker HA does not have.
world() {
    pstate=home
    case "${1-}" in person=*) pstate=${1#person=}; shift ;; esac
    python3 - "$FIX" "$pstate" "$@" <<'PY'
import datetime, json, os, sys
fix, pstate, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
now = datetime.datetime.now(datetime.timezone.utc)
trackers, states = [], []
for spec in specs:
    eid, name, state, *rest = spec.split("|")
    if eid.startswith("device_tracker."):
        trackers.append(eid)
    if state == "missing":
        continue
    stamp = (now - datetime.timedelta(hours=float(rest[0]))).isoformat()
    states.append({"entity_id": eid, "state": state,
                   "attributes": {"friendly_name": name},
                   "last_changed": stamp, "last_reported": stamp, "last_updated": stamp})
states.insert(0, {"entity_id": "person.candela", "state": pstate,
                  "attributes": {"friendly_name": "Candela", "device_trackers": trackers}})
json.dump(states, open(os.path.join(fix, "states.json"), "w"))
PY
}

# restamp <minutes_ago> — HA re-stamps every entity, as it does on restart.
restamp() {
    python3 - "$FIX" "$1" <<'PY'
import datetime, json, os, sys
fix, minutes = sys.argv[1], float(sys.argv[2])
stamp = (datetime.datetime.now(datetime.timezone.utc)
         - datetime.timedelta(minutes=minutes)).isoformat()
states = json.load(open(os.path.join(fix, "states.json")))
for s in states:
    if not s["entity_id"].startswith("person."):
        s["last_reported"] = s["last_updated"] = s["last_changed"] = stamp
json.dump(states, open(os.path.join(fix, "states.json"), "w"))
PY
}

# seen <tracker> <hours_ago> — what a previous run recorded as the last report.
seen() {
    python3 -c 'import datetime, json, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[3]))
json.dump({sys.argv[2]: t.isoformat()}, open(sys.argv[1], "w"))' "$STATE" "$1" "$2"
}

# docker_stamp <minutes_ago> — Docker's StartedAt shape: `Z`, nanoseconds.
docker_stamp() {
    python3 -c 'import datetime, sys
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(sys.argv[1]))
print(t.strftime("%Y-%m-%dT%H:%M:%S.%f") + "123Z")' "$1"
}

# HA_STARTED is what Docker reports; empty = Docker could not say. Default:
# started long ago, so no stamp is a restore.
HA_STARTED_DEFAULT=2026-01-01T00:00:00.000000000Z
run() {
    OUT=$(PRESENCE_IGNORE="" python3 "$WORK/check.py" token "$HA_URL" 20 \
          "${STATE_OVERRIDE:-$STATE}" "${HA_STARTED-$HA_STARTED_DEFAULT}" 2>&1)
    RC=$?
}

T=device_tracker.iphone_de_candela_2026
N="iPhone de Candela 2026"

# ------------------------------------------------------------------
# 1. Any entity counts. The tracker alone was the PER-57 mistake.
# ------------------------------------------------------------------
rm -f "$STATE"
world "$T|$N|home|30" "sensor.iphone_de_candela_2026_battery_state|$N Battery State|Charging|2"
run
if [ "$RC" -eq 0 ]; then
    pass "1a. tracker quiet 30 h, battery sensor 2 h ago: live"
else
    fail "1a. a sensor report did not count (rc=$RC): $OUT"
fi

rm -f "$STATE"
world "$T|$N|home|30" "sensor.iphone_de_candela_2026_battery_state|$N Battery State|Charging|25"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "no report from the phone in 25 h"; then
    pass "1b. its twin: every entity quiet, newest 25 h: pages, naming the newest"
else
    fail "1b. a phone silent on every entity did not page (rc=$RC): $OUT"
fi

# ------------------------------------------------------------------
# 2. The threshold, both sides, home and away alike.
# ------------------------------------------------------------------
rm -f "$STATE"; world "$T|$N|home|19"
run
if [ "$RC" -eq 0 ]; then pass "2a. 19 h at home: live"
else fail "2a. 19 h paged (rc=$RC): $OUT"; fi

rm -f "$STATE"; world "$T|$N|home|21"
run
if [ "$RC" -ne 0 ]; then pass "2b. 21 h at home: pages"
else fail "2b. 21 h at home did not page (rc=$RC): $OUT"; fi

rm -f "$STATE"; world person=not_home "$T|$N|not_home|21"
run
if [ "$RC" -ne 0 ]; then pass "2c. 21 h away: pages too — location does not excuse silence"
else fail "2c. 21 h away did not page (rc=$RC): $OUT"; fi

# The 2026-11-23 shape: home, not charged, every entity silent 30.5 h. Under
# 20 h this pages, by choice — pinned so a change to it is a decision.
rm -f "$STATE"
world "$T|$N|home|30.5" "sensor.iphone_de_candela_2026_battery_level|$N Battery Level|95|30.5"
run
if [ "$RC" -ne 0 ]; then pass "2d. 2026-11-23 (30.5 h, uncharged): pages at 20 h, as chosen"
else fail "2d. 30.5 h silence did not page at 20 h (rc=$RC): $OUT"; fi

# ------------------------------------------------------------------
# 3. What is NOT the phone speaking.
# ------------------------------------------------------------------
# notify.<phone> moves when HA pushes TO the phone. Live it is named exactly
# the device name, so the name rule already drops it (3a); 3c names it the way
# a sensor would be, to pin the domain rule on its own.
rm -f "$STATE"
world "$T|$N|home|25" "notify.iphone_de_candela_2026|$N|2026-11-23T17:30:08|0.1"
run
if [ "$RC" -ne 0 ]; then pass "3a. a fresh notify entity does not count as a report"
else fail "3a. HA's own push read as the phone reporting (rc=$RC): $OUT"; fi

rm -f "$STATE"
world "$T|$N|home|25" "notify.iphone_de_candela_2026_push|$N Push|2026-11-23T17:30:08|0.1"
run
if [ "$RC" -ne 0 ]; then pass "3c. nor does one named like a sensor — only phone domains count"
else fail "3c. a notify entity was credited to the phone (rc=$RC): $OUT"; fi

# Another device whose name merely starts the same way, without the space.
rm -f "$STATE"
world "$T|$N|home|25" "sensor.iphone_de_candela_2026b_battery|${N}b Battery Level|50|0.1"
run
if [ "$RC" -ne 0 ]; then pass "3b. a different device's sensor does not count"
else fail "3b. another device's sensor was credited to this phone (rc=$RC): $OUT"; fi

# ------------------------------------------------------------------
# 4. A Home Assistant restart is not a report (2026-10-04).
# ------------------------------------------------------------------
# Silent 25 h, recorded by an earlier run; HA restarts and re-stamps everything.
world "$T|$N|home|25" "sensor.iphone_de_candela_2026_battery_level|$N Battery Level|80|25"
seen "$T" 25
restamp 9.5; HA_STARTED=$(docker_stamp 10)
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "in 25 h"; then
    pass "4a. restart during a silence: still pages, from the recorded report"
else
    fail "4a. HA's restore stamp read as a report (rc=$RC): $OUT"
fi

# Twin: a real report after the restore window clears it and is recorded.
restamp 2; HA_STARTED=$(docker_stamp 30)
run
if [ "$RC" -eq 0 ] && python3 -c 'import datetime, json, sys
t = datetime.datetime.fromisoformat(json.load(open(sys.argv[1]))[sys.argv[2]])
sys.exit(0 if (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() < 3 * 3600 else 1)' \
        "$STATE" "$T"; then
    pass "4b. a real report after the restart clears it and is recorded"
else
    fail "4b. real report after restart not taken (rc=$RC): $OUT / $(cat "$STATE")"
fi

# Restart with nothing recorded yet: count from the restart, say so.
rm -f "$STATE"; world "$T|$N|home|0"; restamp 1; HA_STARTED=$(docker_stamp 1.5)
run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "counting from it" && [ -s "$STATE" ]; then
    pass "4c. restart, no record: live, counted from the restart, recorded"
else
    fail "4c. restart with no record mishandled (rc=$RC): $OUT"
fi

# Docker could not say when HA started: run, but say so.
HA_STARTED=""
run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "cannot read Home Assistant's start time"; then
    pass "4d. unknown start time is reported, not hidden"
else
    fail "4d. missing start time was silent (rc=$RC): $OUT"
fi
unset HA_STARTED

# A stale record never hides a newer real report.
world "$T|$N|home|1"; seen "$T" 40
run
if [ "$RC" -eq 0 ]; then pass "4e. an old record loses to a newer real report"
else fail "4e. old record outweighed a fresh report (rc=$RC): $OUT"; fi

# Without the record a restart resets every clock: that must page.
STATE_OVERRIDE="$WORK/no/such/dir/state.json"
world "$T|$N|home|1"
run
unset STATE_OVERRIDE
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "cannot write"; then
    pass "4f. unwritable record pages"
else
    fail "4f. unwritable record was silent (rc=$RC): $OUT"
fi

# ------------------------------------------------------------------
# 5. A person is as live as their freshest phone (PER-172).
# ------------------------------------------------------------------
rm -f "$STATE"
world "$T|$N|home|1" "device_tracker.old_phone|Old Phone|home|97"
run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "old_phone.*not judged.*$T"; then
    pass "5a. retired phone beside a live one: a note, not a page"
else
    fail "5a. retired phone paged although the person is live (rc=$RC): $OUT"
fi

rm -f "$STATE"
world "$T|$N|home|25" "device_tracker.old_phone|Old Phone|home|97"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "$N: no report"; then
    pass "5b. its twin: no phone live: pages"
else
    fail "5b. a person with no live phone did not page (rc=$RC): $OUT"
fi

rm -f "$STATE"; world "$T|$N|home|1" "device_tracker.old_phone|Old Phone|missing"
run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "old_phone is missing from HA"; then
    pass "5c. deleted tracker beside a live one: a note"
else
    fail "5c. deleted tracker paged although the person is live (rc=$RC): $OUT"
fi

rm -f "$STATE"; world "device_tracker.old_phone|Old Phone|missing"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "does not exist"; then
    pass "5d. the only tracker deleted: pages"
else
    fail "5d. a person with no tracker left did not page (rc=$RC): $OUT"
fi

# ------------------------------------------------------------------
# 6. Broken without waiting for the threshold.
# ------------------------------------------------------------------
rm -f "$STATE"; world "$T|$N|unavailable|0"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "tracker is unavailable"; then
    pass "6a. tracker unavailable: pages at once"
else
    fail "6a. unavailable tracker did not page (rc=$RC): $OUT"
fi

rm -f "$STATE"; world person=unknown "$T|$N|home|1"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "person entity is unknown"; then
    pass "6b. person unknown: pages"
else
    fail "6b. unknown person did not page (rc=$RC): $OUT"
fi

rm -f "$STATE"; world
run
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "no device_trackers attached"; then
    pass "6c. person with no trackers: a note"
else
    fail "6c. person with no trackers mishandled (rc=$RC): $OUT"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ presence health: all cases passed\n'
    exit 0
fi
printf '❌ presence health: %s failure(s)\n' "$failures"
exit 1
