#!/bin/sh
# Runner for the laptop-side unit tests.
#
#   tests/run_unit_tests.sh            # all of them
#   tests/run_unit_tests.sh sweep      # only names matching "sweep"
#
# Separate from run_tests.sh on purpose. That one stages the repo onto a
# disposable LXC and connects as root to force real faults; these need no
# container, no network and no privilege — they render a .j2 and feed the result
# hand-written input. Merging them would blur a contract that is deliberately
# narrow.
#
# ⚠️ This exists because nothing ran tests/unit/ at all. Four of the eleven had
# been failing since 6cfa1f0 added five variables to fleet_health_check.sh.j2
# without updating the tests that render it — red for eleven days, and the only
# reason anyone noticed was running the suite by hand before adding to it. A
# regression suite nobody executes is not a regression suite. See TODO item 17.
set -u

CDPATH=''
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
FILTER="${1:-}"

pass=0
fail=0
failed=""

for t in "$ROOT"/unit/*_test.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t" _test.sh)
    case "$name" in
        *"$FILTER"*) ;;
        *) continue ;;
    esac

    # Captured, not streamed: a passing suite should be one line each. The full
    # output is printed only for failures, which is when it is worth reading.
    out=$(sh "$t" 2>&1)
    if [ $? -eq 0 ]; then
        pass=$((pass + 1))
        printf '  ✅ %s\n' "$name"
    else
        fail=$((fail + 1))
        failed="$failed $name"
        printf '  ❌ %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/       /'
    fi
done

total=$((pass + fail))
printf '\n'
if [ "$total" -eq 0 ]; then
    # Not "nothing to do" — a filter that matches nothing, or a moved directory,
    # would otherwise exit 0 and read as success.
    printf '❌ no unit tests matched%s\n' "${FILTER:+ \"$FILTER\"}"
    exit 1
fi
if [ "$fail" -eq 0 ]; then
    printf '✅ %s/%s unit suites passed\n' "$pass" "$total"
    exit 0
fi
printf '❌ %s of %s unit suites FAILED:%s\n' "$fail" "$total" "$failed"
exit 1
