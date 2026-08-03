#!/bin/sh
# A disk above THRESHOLD_DISK must produce a non-zero exit.
#
# This case earns its keep twice over. Beyond the missing final `exit`, the
# disk check evaluates its per-filesystem loop inside a `df | grep | while`
# pipeline — which POSIX runs in a subshell. Any counter incremented in there
# is discarded when the subshell ends, so the naive fix (add increments,
# aggregate at the end) leaves *this* check, the one most likely to fire, still
# silently passing. Nothing but forcing a genuinely full disk catches that.
#
# Ballast is written from /dev/urandom, not /dev/zero: rpool has compression
# enabled, and a zero-filled file compresses to nothing without moving the
# usage percentage at all.

. "$(dirname "$0")/../lib/harness.sh"

BALLAST=/var/tmp/.test_ballast
MAX_FILL_MB=3072

describe "disk above threshold fails the check"

cleanup() {
    rm -f "$BALLAST"
}

# Work out how much to write to push / just past 85%.
_blocks_total=$(df -P / | awk 'NR==2 {print $2}')
_blocks_used=$(df -P / | awk 'NR==2 {print $3}')
_blocks_target=$(( _blocks_total * 88 / 100 ))
_fill_mb=$(( (_blocks_target - _blocks_used) / 1024 ))

if [ "$_fill_mb" -le 0 ]; then
    note "disk already above target; no ballast needed"
    _fill_mb=0
elif [ "$_fill_mb" -gt "$MAX_FILL_MB" ]; then
    _fail "would need ${_fill_mb}MB of ballast (cap ${MAX_FILL_MB}MB) — is this a test container?"
    finish
fi

if [ "$_fill_mb" -gt 0 ]; then
    note "writing ${_fill_mb}MB of incompressible ballast to $BALLAST"
    dd if=/dev/urandom of="$BALLAST" bs=1M count="$_fill_mb" 2>/dev/null
    sync
fi

_usage=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
note "root filesystem now at ${_usage}%"
assert_precondition "root filesystem is above 85%" sh -c "[ ${_usage} -gt 85 ]"

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "above 85%"

finish
