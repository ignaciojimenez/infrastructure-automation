#!/bin/sh
# Regression test: check_presence_health.sh must stay quiet for a phone that is
# merely at home, and still page for one that is frozen there.
#
# Runs on the laptop — no container, no Home Assistant. The template's embedded
# Python is extracted and pointed at a stub HA on 127.0.0.1 that serves
# /api/states and /api/services, records every notify call, and — when told to —
# answers a location request the way the Companion App does: by moving the
# tracker's `last_reported`.
#
#   tests/unit/presence_health_test.sh
#
# The bug this exists for (PER-57, 11–16 Sep 2026): Candela stayed home, her
# iPhone had nothing to report, and "stale AND home" paged four times on a
# healthy phone. Case 1 is that exact state and must stay green. Case 2 is the
# same silence from a phone that does NOT answer, and must page — a fix that
# made case 1 quiet by making both quiet would pass case 1 alone.

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

printf '\n── presence health: ask the phone before calling it frozen\n'

[ -f "$TEMPLATE" ] || { printf '   ✗ template not found: %s\n' "$TEMPLATE"; exit 1; }

# ------------------------------------------------------------------
# 0. The shipped file renders and is valid shell.
# ------------------------------------------------------------------
if python3 "$RENDERER" "$TEMPLATE" "$WORK/check.sh" \
        homeassistant_config_dir=/home/tester/homeassistant \
        presence_stale_hours=18 \
        presence_probe_answer_minutes=20 \
        presence_probe_interval_hours=6 \
        presence_probe_state_file=/home/tester/.log/presence_probe.state.json \
        presence_ignore_persons=person.ai_agent \
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
open(sys.argv[2], "w").write(blocks[0])
PY
[ -s "$WORK/check.py" ] || { printf '   ✗ could not extract the Python block\n'; exit 1; }

# ------------------------------------------------------------------
# Stub Home Assistant. Reads $FIX on every request, so a case is set up by
# rewriting fixtures — no restart.
#   $FIX/states.json    /api/states body
#   $FIX/services.json  /api/services body
#   $FIX/phone          answer | silent | error   (how the notify POST behaves)
#   $FIX/calls          one line per notify POST: <service> <message>
# ------------------------------------------------------------------
FIX="$WORK/fix"
mkdir -p "$FIX"

cat > "$WORK/stub.py" <<'PY'
import datetime, json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIX = sys.argv[1]

def read(name, default=""):
    try:
        return open(os.path.join(FIX, name)).read()
    except OSError:
        return default

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/states":
            return self.reply(200, read("states.json", "[]"))
        if self.path == "/api/services":
            return self.reply(200, read("services.json", "[]"))
        self.reply(404, "{}")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self.path.startswith("/api/services/notify/"):
            return self.reply(404, "{}")
        service = self.path.rsplit("/", 1)[1]
        with open(os.path.join(FIX, "calls"), "a") as fh:
            fh.write("%s %s\n" % (service, json.loads(body).get("message")))
        mode = read("phone", "silent").strip()
        if mode == "error":
            return self.reply(500, "{}")
        if mode == "answer":
            states = json.loads(read("states.json", "[]"))
            stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            for s in states:
                if s["entity_id"].startswith("device_tracker."):
                    s["last_reported"] = s["last_updated"] = stamp
            open(os.path.join(FIX, "states.json"), "w").write(json.dumps(states))
        self.reply(200, "[]")

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

STATE="$WORK/probe.state.json"
TRACKER=device_tracker.iphone_de_candela_2
NOTIFY=mobile_app_iphone_de_candela

# world <tracker_state> <hours_since_report> [notify services, comma-separated]
# The tracker id carries HA's `_2` re-registration suffix and the notify service
# does not — the real shape on dockassist, and the reason name matching exists.
world() {
    python3 - "$FIX" "$1" "$2" "${3-$NOTIFY}" <<'PY'
import datetime, json, os, sys
fix, tstate, hours, services = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
stamp = (datetime.datetime.now(datetime.timezone.utc)
         - datetime.timedelta(hours=hours)).isoformat()
states = [
    {"entity_id": "person.candela", "state": tstate,
     "attributes": {"friendly_name": "Candela",
                    "device_trackers": ["device_tracker.iphone_de_candela_2"]}},
    {"entity_id": "device_tracker.iphone_de_candela_2", "state": tstate,
     "attributes": {"friendly_name": "iPhone de Candela", "source_type": "gps"},
     "last_changed": stamp, "last_reported": stamp, "last_updated": stamp},
]
json.dump(states, open(os.path.join(fix, "states.json"), "w"))
notify = {s: {} for s in services.split(",") if s}
json.dump([{"domain": "notify", "services": notify},
           {"domain": "light", "services": {"turn_on": {}}}],
          open(os.path.join(fix, "services.json"), "w"))
PY
    : > "$FIX/calls"
}

# asked <minutes_ago> [reported_matches=yes|no]
# Writes an outstanding request as a previous run would have left it.
asked() {
    python3 - "$FIX" "$STATE" "$TRACKER" "$1" "${2:-yes}" <<'PY'
import json, os, sys, time
fix, state, tid, minutes, match = sys.argv[1:6]
tracker = [s for s in json.load(open(os.path.join(fix, "states.json")))
           if s["entity_id"] == tid][0]
reported = tracker["last_reported"] if match == "yes" else "2020-01-01T00:00:00+00:00"
json.dump({tid: {"asked_at": time.time() - float(minutes) * 60, "reported": reported}},
          open(state, "w"))
PY
}

phone() { printf '%s\n' "$1" > "$FIX/phone"; }

run() {
    OUT=$(PRESENCE_IGNORE="" python3 "$WORK/check.py" token "$HA_URL" 18 \
          "${STATE_OVERRIDE:-$STATE}" 20 6 2>&1)
    RC=$?
}

pushes() { grep -c "request_location_update" "$FIX/calls" 2>/dev/null || true; }

# ------------------------------------------------------------------
# 1. PER-57: quiet 32 h at home, phone healthy. Must never page.
# ------------------------------------------------------------------
rm -f "$STATE"; world home 32; phone answer
run
if [ "$RC" -eq 0 ]; then
    pass "1a. first run asks instead of paging (exit 0)"
else
    fail "1a. PER-57 state paged on the first run (rc=$RC): $OUT"
fi
if grep -q "^$NOTIFY request_location_update$" "$FIX/calls"; then
    pass "1b. request went to notify.$NOTIFY despite the _2 tracker id"
else
    fail "1b. no request_location_update to $NOTIFY: $(cat "$FIX/calls")"
fi
if grep -q "$TRACKER" "$STATE" 2>/dev/null; then
    pass "1c. the outstanding request was recorded"
else
    fail "1c. no probe state written"
fi

: > "$FIX/calls"
run
if [ "$RC" -eq 0 ]; then
    pass "1d. next run: phone answered, still exit 0"
else
    fail "1d. answered phone paged (rc=$RC): $OUT"
fi
if [ "$(pushes)" -eq 0 ]; then
    pass "1e. no second push to a phone that answered"
else
    fail "1e. pushed again after an answer"
fi
if grep -q "$TRACKER" "$STATE" 2>/dev/null; then
    fail "1f. answered request left in state"
else
    pass "1f. answered request cleared from state"
fi

# ------------------------------------------------------------------
# 2. Same silence, phone does NOT answer. Must page — case 1's loud twin.
# ------------------------------------------------------------------
rm -f "$STATE"; world home 32; phone silent
run
if [ "$RC" -eq 0 ]; then
    pass "2a. first run asks and waits (exit 0)"
else
    fail "2a. paged before the phone had a chance to answer (rc=$RC): $OUT"
fi
asked 25   # the next cron run, 25 min later; tracker never moved
: > "$FIX/calls"
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "FROZEN.*did not answer"; then
    pass "2b. unanswered after 25 min pages as FROZEN"
else
    fail "2b. frozen phone did NOT page (rc=$RC): $OUT"
fi
if [ "$(pushes)" -eq 0 ]; then
    pass "2c. no re-ask inside the rate-limit interval"
else
    fail "2c. re-asked within the interval ($(pushes) pushes)"
fi

# ------------------------------------------------------------------
# 3. Inside the answer window: wait, do not page, do not re-ask.
# ------------------------------------------------------------------
world home 32; phone silent; asked 5
run
if [ "$RC" -eq 0 ] && [ "$(pushes)" -eq 0 ]; then
    pass "3. asked 5 min ago: waits quietly, no second push"
else
    fail "3. did not wait for the answer (rc=$RC, pushes=$(pushes)): $OUT"
fi

# ------------------------------------------------------------------
# 4. Unanswered for a whole interval: re-ask, and keep paging meanwhile.
# ------------------------------------------------------------------
world home 40; phone silent; asked 420
run
if [ "$RC" -ne 0 ] && [ "$(pushes)" -eq 1 ]; then
    pass "4. unanswered 7 h: asks again and still pages"
else
    fail "4. expected re-ask + page (rc=$RC, pushes=$(pushes)): $OUT"
fi

# ------------------------------------------------------------------
# 5. Answered earlier, quiet again: a new silence, so ask — do not page on
#    the old request.
# ------------------------------------------------------------------
world home 20; phone silent; asked 120 no
run
if [ "$RC" -eq 0 ] && [ "$(pushes)" -eq 1 ]; then
    pass "5. an old answered request does not count against a new silence"
else
    fail "5. stale request misread (rc=$RC, pushes=$(pushes)): $OUT"
fi

# ------------------------------------------------------------------
# 6. Cannot ask → page. Unable to verify is not evidence of health.
# ------------------------------------------------------------------
rm -f "$STATE"; world home 32 "mobile_app_someone_else"; phone answer
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "could not be asked" \
   && [ "$(pushes)" -eq 0 ]; then
    pass "6a. no matching notify service pages, pushes nothing"
else
    fail "6a. unmatched service did not page cleanly (rc=$RC, pushes=$(pushes)): $OUT"
fi

rm -f "$STATE"; world home 32; phone error
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "could not be asked"; then
    pass "6b. notify call failing (HTTP 500) pages"
else
    fail "6b. failed notify call did not page (rc=$RC): $OUT"
fi

STATE_OVERRIDE="$WORK/no/such/dir/state.json"
rm -f "$STATE"; world home 32; phone silent
run
unset STATE_OVERRIDE
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "cannot write probe state"; then
    pass "6c. unwritable state pages — otherwise it would ask forever and never page"
else
    fail "6c. unwritable state was silent (rc=$RC): $OUT"
fi

# ------------------------------------------------------------------
# 7. Paths that must not ask at all.
# ------------------------------------------------------------------
rm -f "$STATE"; world not_home 40; phone answer
run
if [ "$RC" -eq 0 ] && [ "$(pushes)" -eq 0 ]; then
    pass "7a. stale + not_home: benign, no push"
else
    fail "7a. away phone was asked or paged (rc=$RC, pushes=$(pushes)): $OUT"
fi

world home 2; phone answer; asked 10
run
if [ "$RC" -eq 0 ] && [ "$(pushes)" -eq 0 ] && ! grep -q "$TRACKER" "$STATE"; then
    pass "7b. fresh + home: no push, leftover request cleared"
else
    fail "7b. fresh tracker mishandled (rc=$RC, pushes=$(pushes)): $OUT"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ presence health: all cases passed\n'
    exit 0
fi
printf '❌ presence health: %s failure(s)\n' "$failures"
exit 1
