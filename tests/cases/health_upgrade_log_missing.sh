#!/bin/sh
# The other direction of health_upgrade_log_unreadable: a genuinely absent
# upgrade log must still fail the run, for the same unprivileged user.
#
# Softening the unreadable case is only a fix if this still fires. "The error
# stopped" is satisfied equally by a fix and by a lobotomy.

. "$(dirname "$0")/../lib/harness.sh"

LOG_DIR=/var/log/unattended-upgrades
MOVED="$LOG_DIR.moved-by-test"

describe "genuinely missing upgrade log still fails the check"

cleanup() {
    [ -d "$MOVED" ] && mv "$MOVED" "$LOG_DIR"
    return 0
}

assert_precondition "a test user exists" test -n "$INFRA_USER"

[ -d "$LOG_DIR" ] && mv "$LOG_DIR" "$MOVED"
assert_precondition "the upgrade log directory is gone" test ! -d "$LOG_DIR"

run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "may not be configured"

finish
