#!/bin/sh
# A healthy host must exit 0.
#
# This is the case that stops the exit-code fix from being a lobotomy in the
# other direction: a script rewritten to `exit 1` unconditionally would pass
# every failure case in this suite and be just as useless.

. "$(dirname "$0")/../lib/harness.sh"

UU_LOG=/var/log/unattended-upgrades/unattended-upgrades.log
UU_BACKUP=/var/tmp/uu.log.testbak

describe "healthy host exits 0"

cleanup() {
    if [ -f "$UU_BACKUP" ]; then
        cat "$UU_BACKUP" > "$UU_LOG"
        rm -f "$UU_BACKUP"
    else
        rm -f "$UU_LOG"
    fi
}

# A container installed minutes ago has never run unattended-upgrades, so
# check_auto_upgrades correctly reports a missing log and the host is not in
# fact healthy. Arrange the healthy state rather than weaken the assertion:
# a freshly dated run entry is what a host that upgraded today would have.
mkdir -p "$(dirname "$UU_LOG")"
[ -f "$UU_LOG" ] && cat "$UU_LOG" > "$UU_BACKUP"
printf '%s Starting unattended upgrades script\n' "$(date '+%Y-%m-%d %H:%M:%S,000')" > "$UU_LOG"

assert_precondition "cron is running" systemctl is-active --quiet cron
# shellcheck disable=SC2016  # deliberately unexpanded — evaluated by the inner shell
assert_precondition "no failed units" sh -c '[ "$(systemctl list-units --failed --no-legend | wc -l)" -eq 0 ]'

run_uut scripts/common/system_health_check.sh

assert_exit_zero
assert_output_contains "System Health Check"
assert_output_not_contains "not running"

finish
