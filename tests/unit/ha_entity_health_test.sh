#!/bin/sh
# Regression test: the HA entity-health check must fire on a real outage and
# stay quiet through a restart.
#
# Runs on the laptop — no container, no Home Assistant, no network. The
# template's embedded Python is extracted and fed hand-written /api/states
# responses and hand-written state files.
#
#   tests/unit/ha_entity_health_test.sh
#
# The bug this exists for (2026-08-17 → 08-22, docs/TODO.md item 15): two Eve
# door sensors sat `unavailable` for five days while every check on the fleet
# reported green. The check written to catch that has two failure modes of its
# own, and both are tested here rather than assumed:
#
#   * it does not fire when it should — the outage stays silent all over again;
#   * it fires on every HA restart — so it gets muted, which is the same
#     five-day silence by a different route.
#
# Every "quiet" assertion below is paired with a "loud" one on the same input
# shape, because a check that is quiet for the wrong reason looks identical to
# a check that is working.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/homeassistant/check_ha_entities.sh.j2"
RENDERER="$REPO_ROOT/tests/lib/render_j2.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── Home Assistant entity health\n'

[ -f "$TEMPLATE" ] || { printf '   ✗ template not found: %s\n' "$TEMPLATE"; exit 1; }

# ------------------------------------------------------------------
# 0. The template must render and be valid shell.
#    This is what keeps the Python-level tests below honest: they exercise the
#    logic, and this exercises the file that actually ships.
# ------------------------------------------------------------------
if python3 "$RENDERER" "$TEMPLATE" "$WORK/check.sh" \
        homeassistant_config_dir=/home/tester/homeassistant \
        ha_entity_health_state_file=/home/tester/.log/ha_entities.json \
        ha_entity_health_grace_seconds=900 \
        ha_entity_health_allowlist='automation.tado_stale_*,sensor.dead_thing' \
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

# The allowlist loop must actually have emitted both patterns, not silently
# expanded to nothing — an empty allowlist still renders and still passes sh -n.
if grep -q 'automation.tado_stale_\*' "$WORK/check.sh" 2>/dev/null &&
   grep -q 'sensor.dead_thing' "$WORK/check.sh" 2>/dev/null; then
    pass "allowlist patterns reached the rendered script"
else
    fail "allowlist patterns missing from the rendered script"
fi

# ------------------------------------------------------------------
# Extract the Python block for behavioural testing.
# ------------------------------------------------------------------
python3 - "$TEMPLATE" "$WORK/check.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
blocks = re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.S)
if len(blocks) != 1:
    sys.exit("expected exactly one PYEOF block, found %d" % len(blocks))
open(sys.argv[2], "w").write(blocks[0])
PY
[ -s "$WORK/check.py" ] || { printf '   ✗ could not extract the Python block\n'; exit 1; }

GRACE=900
ALLOW=""
STATELESS=""
OVERRIDES=""
RC=0
OUT=""

# states <file> <entity=state> ...
states() {
    _f="$1"; shift
    python3 - "$_f" "$@" <<'PY'
import json, sys
out = []
for arg in sys.argv[2:]:
    eid, st = arg.split("=", 1)
    out.append({"entity_id": eid, "state": st, "attributes": {}})
json.dump(out, open(sys.argv[1], "w"))
PY
}

# state <file> <entity:age_seconds> ...   (age = how long it has been bad)
state() {
    _f="$1"; shift
    python3 - "$_f" "$@" <<'PY'
import json, sys, time
now = int(time.time())
ents = {}
for arg in sys.argv[2:]:
    eid, age = arg.rsplit(":", 1)
    ents[eid] = now - int(age)
json.dump({"version": 1, "entities": ents, "api_down_since": None},
          open(sys.argv[1], "w"))
PY
}

# api_down_state <file> <age_seconds>
api_down_state() {
    python3 - "$1" "$2" <<'PY'
import json, sys, time
json.dump({"version": 1, "entities": {"binary_sensor.keeper": int(time.time()) - 7200},
           "api_down_since": int(time.time()) - int(sys.argv[2])},
          open(sys.argv[1], "w"))
PY
}

# run <state_file> <mode> <api_ok> <http> <states_file>
run() {
    OUT=$(HA_ALLOWLIST="$ALLOW" HA_STATELESS_DOMAINS="$STATELESS" HA_GRACE_OVERRIDES="$OVERRIDES" python3 "$WORK/check.py" \
          "$1" "$GRACE" "$2" "$3" "$4" "$5" 2>&1)
    RC=$?
}

expect_rc() {
    if [ "$RC" = "$1" ]; then
        pass "$2 (exit $RC)"
    else
        fail "$2 — expected exit $1, got $RC"
        printf '     | %s\n' "$OUT"
    fi
}

expect_out() {
    if printf '%s' "$OUT" | grep -qF -- "$1"; then
        pass "$2"
    else
        fail "$2 — output missing: $1"
        printf '     | %s\n' "$OUT"
    fi
}

expect_no_out() {
    if printf '%s' "$OUT" | grep -qF -- "$1"; then
        fail "$2 — output unexpectedly contains: $1"
        printf '     | %s\n' "$OUT"
    else
        pass "$2"
    fi
}

printf '\n   ── the outage itself\n'

# ------------------------------------------------------------------
# 1. The five-day outage, replayed. Two door sensors bad well beyond grace.
# ------------------------------------------------------------------
states "$WORK/s1.json" \
    binary_sensor.front_door=unavailable \
    binary_sensor.back_door=unavailable \
    sensor.temperature=21.5 \
    light.kitchen=on
state "$WORK/st1.json" binary_sensor.front_door:432000 binary_sensor.back_door:432000
run "$WORK/st1.json" check 1 200 "$WORK/s1.json"
expect_rc 2 "two sensors down five days page, and the count is the exit status"
expect_out "binary_sensor.front_door" "the failing entity is named"
expect_out "binary_sensor.back_door" "the second failing entity is named"
expect_out "❌" "marked with ❌ so the wrapper's failure signature sees it"

# ------------------------------------------------------------------
# 2. Same entities, first sighting. Must be silent — this is the grace window
#    doing its job, not the check failing to notice.
# ------------------------------------------------------------------
rm -f "$WORK/st2.json"
run "$WORK/st2.json" check 1 200 "$WORK/s1.json"
expect_rc 0 "a just-noticed outage waits out the grace window"
expect_out "inside grace" "and says so rather than claiming health"

# ...and the very same state file, once the clock has run, must page. Without
# this the assertion above is satisfied by a check that can never fire at all.
python3 - "$WORK/st2.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["entities"] = {k: int(time.time()) - 3600 for k in d["entities"]}
json.dump(d, open(sys.argv[1], "w"))
PY
run "$WORK/st2.json" check 1 200 "$WORK/s1.json"
expect_rc 2 "the same entities page once the grace window has passed"

printf '\n   ── the restart that must not page\n'

# ------------------------------------------------------------------
# 3. An HA restart flips EVERY entity through unavailable at once. On a fresh
#    sighting this must be silent. This is the property that decides whether
#    the check survives contact with a deploy or gets muted.
# ------------------------------------------------------------------
python3 - "$WORK/s3.json" <<'PY'
import json, sys
json.dump([{"entity_id": "sensor.e%03d" % i, "state": "unavailable", "attributes": {}}
           for i in range(200)], open(sys.argv[1], "w"))
PY
rm -f "$WORK/st3.json"
run "$WORK/st3.json" check 1 200 "$WORK/s3.json"
expect_rc 0 "200 entities flipping at once during a restart does not page"

# ...but an HA that is still broken an hour later must page. A restart is
# quiet; a restart that never finished is not.
# The split is the point: state() takes one entity:age pair per argument, and
# 200 of them are generated rather than typed. Quoting would pass all 200 as a
# single argument and rsplit(":") would then build one nonsense entity.
# shellcheck disable=SC2046
state "$WORK/st3b.json" $(python3 -c 'print(" ".join("sensor.e%03d:3600" % i for i in range(200)))')
run "$WORK/st3b.json" check 1 200 "$WORK/s3.json"
if [ "$RC" -gt 0 ]; then
    pass "the same 200 entities page once they outlive the grace window (exit $RC)"
else
    fail "200 entities down for an hour did not page"
fi

printf '\n   ── the allowlist\n'

# ------------------------------------------------------------------
# 4. Known-stale entities are excused; everything else still pages.
# ------------------------------------------------------------------
states "$WORK/s4.json" \
    automation.tado_stale_one=unavailable \
    automation.tado_stale_two=unavailable \
    binary_sensor.front_door=unavailable
state "$WORK/st4.json" \
    automation.tado_stale_one:432000 \
    automation.tado_stale_two:432000 \
    binary_sensor.front_door:432000
ALLOW="automation.tado_stale_*"
run "$WORK/st4.json" check 1 200 "$WORK/s4.json"
expect_rc 1 "allowlisted entities are excused, the real fault still pages"
expect_out "binary_sensor.front_door" "the non-allowlisted entity is still named"
expect_no_out "❌ automation.tado_stale_one" "the allowlisted entity does not page"

# The allowlist must not be a blanket. A pattern that matches nothing must not
# quietly excuse anything.
ALLOW="automation.nothing_matches_*"
run "$WORK/st4.json" check 1 200 "$WORK/s4.json"
expect_rc 3 "a non-matching allowlist excuses nothing"
ALLOW=""

printf '\n   ── stateless domains\n'

# ------------------------------------------------------------------
# 4b. A button has no state until pressed, so `unknown` is its resting
#     condition, not a fault. Measured on dockassist 2026-08-25: 27 of 296
#     entities were exactly this. Excluding them by DOMAIN — never by a list of
#     ids — is what stops the 28th button from paging the day it is added.
#
#     Both directions are asserted. Excusing `unknown` is only safe if
#     `unavailable` on the very same entity still pages, because that means the
#     device behind the button is genuinely gone.
# ------------------------------------------------------------------
states "$WORK/s4b.json" \
    button.shelly_restart=unknown \
    notify.mobile_app=unknown \
    sensor.real_thing=unknown
state "$WORK/st4b.json" \
    button.shelly_restart:432000 \
    notify.mobile_app:432000 \
    sensor.real_thing:432000
STATELESS="button
notify"
run "$WORK/st4b.json" check 1 200 "$WORK/s4b.json"
expect_rc 1 "a stateless-domain 'unknown' is not a fault; a real sensor's still is"
expect_out "sensor.real_thing" "the non-stateless entity still pages"
expect_no_out "❌ button.shelly_restart" "the button does not page for being unknown"
expect_no_out "❌ notify.mobile_app" "nor does the notify service"

# ...but the same button going UNAVAILABLE means its device is gone, and that
# must still page. Without this, the domain rule is a blanket mute.
states "$WORK/s4c.json" button.shelly_restart=unavailable
state "$WORK/st4c.json" button.shelly_restart:432000
run "$WORK/st4c.json" check 1 200 "$WORK/s4c.json"
expect_rc 1 "the SAME button going unavailable still pages"
expect_out "button.shelly_restart" "and names it"
STATELESS=""

printf '\n   ── per-entity grace windows\n'

# ------------------------------------------------------------------
# 4d. One global window cannot serve a door sensor and a lamp that is switched
#     off nightly. Before overrides existed the only escape was the allowlist,
#     which discards the device's real failures too — light.book_floor_lamp was
#     muted exactly that way after paging for 25 h of ordinary use.
#
#     Both halves are asserted, because a long window that never fires is just
#     an allowlist entry with extra steps.
# ------------------------------------------------------------------
states "$WORK/s4d.json" light.lamp=unavailable binary_sensor.front_door=unavailable
OVERRIDES="light.lamp|345600"

# Half one: a night off must stay silent, while the door sensor beside it pages.
state "$WORK/st4d.json" light.lamp:43200 binary_sensor.front_door:43200
run "$WORK/st4d.json" check 1 200 "$WORK/s4d.json"
expect_rc 1 "a 12h switch-off is silent on its long window; the door sensor still pages"
expect_out "binary_sensor.front_door" "the globally-graced entity still pages"
expect_no_out "❌ light.lamp" "the long-window entity does not"

# Half two: gone for a week is NOT ordinary use, and must page.
state "$WORK/st4e.json" light.lamp:604800 binary_sensor.front_door:43200
run "$WORK/st4e.json" check 1 200 "$WORK/s4d.json"
expect_rc 2 "a week of absence pages even on the long window"
expect_out "❌ light.lamp" "the device that never came back is named"

# An override must not leak onto entities it does not match.
OVERRIDES="light.somethingelse|345600"
run "$WORK/st4d.json" check 1 200 "$WORK/s4d.json"
expect_rc 2 "a non-matching override changes nothing"

# A malformed override must be reported, not silently ignored.
OVERRIDES="light.lamp|notanumber"
run "$WORK/st4d.json" check 1 200 "$WORK/s4d.json"
expect_out "ignoring malformed grace override" "a broken override is announced"
OVERRIDES=""

printf '\n   ── recovery\n'

# ------------------------------------------------------------------
# 5. A recovered entity clears and is reported.
# ------------------------------------------------------------------
states "$WORK/s5.json" binary_sensor.front_door=off binary_sensor.back_door=on
state "$WORK/st5.json" binary_sensor.front_door:432000 binary_sensor.back_door:432000
run "$WORK/st5.json" check 1 200 "$WORK/s5.json"
expect_rc 0 "recovered entities clear the fault"
expect_out "recovered: binary_sensor.front_door" "the recovery is reported"

if python3 -c "
import json,sys
d=json.load(open('$WORK/st5.json'))
sys.exit(0 if d['entities']=={} else 1)"; then
    pass "recovered entities are dropped from the state file"
else
    fail "state file still holds recovered entities — ages would never reset"
fi

printf '\n   ── a check that cannot see is not a check that is happy\n'

# ------------------------------------------------------------------
# 6. Every way the API can fail to answer must be a failure, never a green.
#    This is the exact class of bug item 15 was: silence read as health.
# ------------------------------------------------------------------
printf 'not json at all' > "$WORK/s6.json"
rm -f "$WORK/st6.json"
run "$WORK/st6.json" check 1 200 "$WORK/s6.json"
expect_rc 1 "unparseable JSON is a failure, not an absence of faults"

printf '[]' > "$WORK/s7.json"
rm -f "$WORK/st7.json"
run "$WORK/st7.json" check 1 200 "$WORK/s7.json"
expect_rc 1 "zero entities is a failure — HA always has entities"

printf '{"message":"Invalid access token"}' > "$WORK/s8.json"
rm -f "$WORK/st8.json"
run "$WORK/st8.json" check 1 200 "$WORK/s8.json"
expect_rc 1 "an auth error object is a failure"
expect_out "Invalid access token" "and the reason HA gave is surfaced"

# ------------------------------------------------------------------
# 7. API unreachable: quiet briefly (restart), loud when sustained.
# ------------------------------------------------------------------
rm -f "$WORK/st9.json"
run "$WORK/st9.json" check 0 000 "$WORK/missing.json"
expect_rc 0 "a momentarily unreachable API waits out the grace window"

api_down_state "$WORK/st10.json" 3600
run "$WORK/st10.json" check 0 000 "$WORK/missing.json"
expect_rc 1 "an API unreachable for an hour pages"
expect_out "UNKNOWN, not healthy" "and refuses to call unknown health"

# An outage must not hand every broken entity a fresh grace window on recovery.
if python3 -c "
import json,sys,time
d=json.load(open('$WORK/st10.json'))
age=time.time()-d['entities']['binary_sensor.keeper']
sys.exit(0 if age > 7000 else 1)"; then
    pass "entity ages survive an API outage — no free grace window on recovery"
else
    fail "entity ages were reset by the API outage"
fi

# ------------------------------------------------------------------
# 8. A corrupt state file loses ages, so it must say so rather than restart
#    every clock in silence.
# ------------------------------------------------------------------
printf 'this is not json' > "$WORK/st11.json"
run "$WORK/st11.json" check 1 200 "$WORK/s1.json"
expect_rc 1 "a corrupt state file is reported"
expect_out "was unreadable and has been rebuilt" "and explains what was lost"

printf '\n   ── report mode\n'

# ------------------------------------------------------------------
# 9. Report mode is for tuning the allowlist, so it must never page.
# ------------------------------------------------------------------
state "$WORK/st12.json" binary_sensor.front_door:432000 binary_sensor.back_door:432000
run "$WORK/st12.json" report 1 200 "$WORK/s1.json"
expect_rc 0 "report mode never exits non-zero, even with live faults"
expect_out "ALERTING" "but it does show what would have paged"

printf '\n   ── cron reality\n'

# ------------------------------------------------------------------
# 10. cron runs with no LANG. The ❌ markers must survive that.
#
#     Scope, measured rather than assumed (dockassist, Python 3.11.2,
#     2026-08-23): PEP 540 already forces UTF-8 mode under an empty environment
#     and under LC_ALL=C, so the template's PYTHONIOENCODING is defence rather
#     than a rescue — no reachable locale on that host produced ASCII stdout.
#     Both are asserted: that the pin is present, and that the check genuinely
#     runs in a stripped environment WITHOUT relying on the pin.
# ------------------------------------------------------------------
if grep -q 'PYTHONIOENCODING=utf-8' "$TEMPLATE"; then
    pass "template pins PYTHONIOENCODING"
else
    fail "template no longer pins PYTHONIOENCODING"
fi

state "$WORK/st13.json" binary_sensor.front_door:432000 binary_sensor.back_door:432000
OUT=$(env -i HA_ALLOWLIST="" LC_ALL=C \
      "$(command -v python3)" "$WORK/check.py" "$WORK/st13.json" "$GRACE" check 1 200 "$WORK/s1.json" 2>&1)
RC=$?
expect_rc 2 "the check runs in a stripped, cron-like environment"
expect_out "binary_sensor.front_door" "and still names the failing entity"
expect_out "❌" "and the ❌ marker survives an ASCII locale"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
