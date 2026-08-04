#!/bin/sh
# A stopped critical service must produce a non-zero exit.
#
# Before the 2026-08 fix this printed "❌ Service cron: not running" and exited
# 0, so the wrapper recorded SUCCESS and nobody was told.

. "$(dirname "$0")/../lib/harness.sh"

describe "stopped cron service fails the check"

cleanup() {
    systemctl start cron >/dev/null 2>&1 || true
}

systemctl stop cron >/dev/null 2>&1
assert_precondition "cron is stopped" sh -c '! systemctl is-active --quiet cron'

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "Service cron: not running"

finish
