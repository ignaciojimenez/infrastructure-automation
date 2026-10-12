#!/bin/sh
# check_runaway.sh against a fake ps and a fake clock (PER-10).
#
#   tests/unit/runaway_check_test.sh
#   SH=dash tests/unit/runaway_check_test.sh
#
# What it pins: three hot intervals page and two do not; a dip resets the
# count; ignored names (spaces included) never page; a recycled pid does not
# inherit a streak; a multi-core process counts; FreeBSD's MM:SS.ss parses; a
# rerun inside 60 s changes nothing; a broken ps fails loudly instead of
# reading as healthy.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
CHECK="$REPO_ROOT/scripts/common/check_runaway.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

T0=1760000000
STEP=600   # the cron interval: every 10 minutes

# sample <epoch> <ps lines...> — one cron run.
sample() {
    _t=$1; shift
    printf '%s\n' "$@" > "$WORK/ps"
    RUNAWAY_PS="cat $WORK/ps" RUNAWAY_NOW=$_t RUNAWAY_STATE="$WORK/state" \
        RUNAWAY_IGNORE_FILE="$WORK/ignore" "$SH" "$CHECK" > "$WORK/out" 2>&1
    RC=$?
}
reset() { rm -f "$WORK/state"; printf '%s\n' "kvm" "Plex Transcoder" > "$WORK/ignore"; }

printf '\n── A process holding a core is flagged after three intervals, not before\n'
reset
sample $T0                  "100 1000 grep" "200 50 sshd"
if [ "$RC" -eq 0 ] && grep -q "first sample" "$WORK/out"; then pass "first run records, flags nothing"; else fail "first run: rc=$RC $(cat "$WORK/out")"; fi
sample $((T0 + STEP))       "100 1600 grep" "200 51 sshd"
r1=$RC
sample $((T0 + 2 * STEP))   "100 2200 grep" "200 52 sshd"
r2=$RC
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; then pass "one and two hot intervals: no page"; else fail "paged early: $r1 $r2 $(cat "$WORK/out")"; fi
sample $((T0 + 3 * STEP))   "100 2800 grep" "200 53 sshd"
if [ "$RC" -eq 1 ] && head -1 "$WORK/out" | grep -q "^❌ runaway process: grep (pid 100) used 100% of a core in each of the last 3 samples (~30 min)"; then
    pass "third hot interval: exit 1, and the finding leads the output"
else
    fail "third interval: rc=$RC $(cat "$WORK/out")"
fi
if ! grep -q "sshd" "$WORK/out" || grep -q "✅.*busiest process grep" "$WORK/out"; then pass "an idle process is never named as runaway"; else fail "$(cat "$WORK/out")"; fi

printf '\n── A dip below the threshold starts the count again\n'
reset
sample $T0                 "100 0 grep"
sample $((T0 + STEP))      "100 600 grep"
sample $((T0 + 2 * STEP))  "100 900 grep"     # 50%: resets
sample $((T0 + 3 * STEP))  "100 1500 grep"
sample $((T0 + 4 * STEP))  "100 2100 grep"
if [ "$RC" -eq 0 ]; then pass "hot, hot, cool, hot, hot: no page"; else fail "dip ignored: $(cat "$WORK/out")"; fi
sample $((T0 + 5 * STEP))  "100 2700 grep"
if [ "$RC" -eq 1 ]; then pass "the third hot interval after the dip pages"; else fail "no page after dip: $(cat "$WORK/out")"; fi

printf '\n── Ignored names never page, names with spaces included\n'
reset
i=0
while [ $i -le 4 ]; do
    sample $((T0 + i * STEP)) "300 $((i * 600)) kvm" "400 $((i * 600)) Plex Transcoder" "500 $((i * 600)) Plex Media Scan"
    i=$((i + 1))
done
if [ "$RC" -eq 1 ] && grep -q "Plex Media Scan (pid 500)" "$WORK/out" && ! grep -q "^❌.*kvm\|^❌.*Plex Transcoder" "$WORK/out"; then
    pass "kvm and 'Plex Transcoder' ignored; 'Plex Media Scan' (not listed) still pages"
else
    fail "ignore list: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── A recycled pid does not inherit a streak\n'
reset
sample $T0                 "100 0 grep"
sample $((T0 + STEP))      "100 600 grep"
sample $((T0 + 2 * STEP))  "100 1200 grep"
sample $((T0 + 3 * STEP))  "100 1800 find"    # same pid, new process
if [ "$RC" -eq 0 ]; then pass "same pid, different name: counted afresh"; else fail "inherited: $(cat "$WORK/out")"; fi

printf '\n── A process using several cores counts\n'
reset
sample $T0                 "100 0 zstd"
sample $((T0 + STEP))      "100 1500 zstd"
sample $((T0 + 2 * STEP))  "100 3000 zstd"
sample $((T0 + 3 * STEP))  "100 4500 zstd"
if [ "$RC" -eq 1 ] && grep -q "zstd (pid 100) used 250%" "$WORK/out"; then pass "250% of a core pages"; else fail "multi-core: $(cat "$WORK/out")"; fi

printf '\n── FreeBSD accumulated time (MM:SS.ss) parses\n'
reset
sample $T0                 "100 0:00.50 grep"
sample $((T0 + STEP))      "100 10:00.50 grep"
sample $((T0 + 2 * STEP))  "100 20:00.50 grep"
sample $((T0 + 3 * STEP))  "100 30:00.50 grep"
if [ "$RC" -eq 1 ] && grep -q "grep (pid 100) used 100%" "$WORK/out"; then pass "MM:SS.ss read as seconds"; else fail "FreeBSD time: $(cat "$WORK/out")"; fi

printf '\n── A rerun inside 60 s changes nothing\n'
reset
sample $T0                 "100 0 grep"
cp "$WORK/state" "$WORK/state.before"
sample $((T0 + 30))        "100 30 grep"
if [ "$RC" -eq 0 ] && cmp -s "$WORK/state" "$WORK/state.before" && grep -q "not resampled" "$WORK/out"; then
    pass "state untouched, exit 0"
else
    fail "early rerun: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── A broken ps fails loudly, never reads as healthy\n'
reset
RUNAWAY_PS="false" RUNAWAY_NOW=$T0 RUNAWAY_STATE="$WORK/state" RUNAWAY_IGNORE_FILE="$WORK/ignore" "$SH" "$CHECK" > "$WORK/out" 2>&1
r_fail=$?
RUNAWAY_PS="true" RUNAWAY_NOW=$T0 RUNAWAY_STATE="$WORK/state" RUNAWAY_IGNORE_FILE="$WORK/ignore" "$SH" "$CHECK" > "$WORK/out2" 2>&1
r_empty=$?
if [ "$r_fail" -eq 1 ] && [ "$r_empty" -eq 1 ] && grep -q "ps failed" "$WORK/out" && grep -q "no processes" "$WORK/out2"; then
    pass "ps failing or printing nothing: exit 1"
else
    fail "ps failure: $r_fail $r_empty $(cat "$WORK/out" "$WORK/out2")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ runaway_check: all checks passed\n'
    exit 0
fi
printf '❌ runaway_check: %s check(s) failed\n' "$failures"
exit 1
