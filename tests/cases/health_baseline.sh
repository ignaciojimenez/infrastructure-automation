#!/bin/sh
# A healthy host must exit 0.
#
# This is the case that stops the exit-code fix from being a lobotomy in the
# other direction: a script rewritten to `exit 1` unconditionally would pass
# every failure case in this suite and be just as useless.

. "$(dirname "$0")/../lib/harness.sh"

describe "healthy host exits 0"

assert_precondition "cron is running" systemctl is-active --quiet cron
# shellcheck disable=SC2016  # deliberately unexpanded — evaluated by the inner shell
assert_precondition "no failed units" sh -c '[ "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0 ]'

run_uut scripts/common/system_health_check.sh

assert_exit_zero
assert_output_contains "System Health Check"
assert_output_not_contains "not running"

finish
