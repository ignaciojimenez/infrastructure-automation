#!/bin/sh
# An upgrade log the user cannot READ must not be reported as a log that does
# not EXIST — and must not fail the run.
#
# `/var/log/unattended-upgrades` is `root:adm 0750` and the infrastructure user
# is not in `adm` on any host bootstrap created (cwwk, unifi-lxc, agent-lxc —
# measured). `[ -f ]` on the log is then false because the directory cannot be
# traversed, so the check reported "may not be configured" and, once
# system_health_check.sh could fail at all, would have paged three healthy
# hosts every 15 minutes.
#
# This case must run as the unprivileged user: as root the log is readable and
# the fault does not exist. That is the whole reason run_uut_as exists.

. "$(dirname "$0")/../lib/harness.sh"

TEST_USER="${TEST_USER:-$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)}"
LOG_DIR=/var/log/unattended-upgrades
LOG_FILE="$LOG_DIR/unattended-upgrades.log"

describe "unreadable upgrade log warns, and does not fail the run"

cleanup() {
    chown root:adm "$LOG_DIR" 2>/dev/null || true
    chmod 0750 "$LOG_DIR" 2>/dev/null || true
}

[ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
[ -f "$LOG_FILE" ] || printf '%s INFO Starting unattended upgrades script\n' \
    "$(date '+%Y-%m-%d %H:%M:%S,000')" > "$LOG_FILE"
chown root:adm "$LOG_DIR"
chmod 0750 "$LOG_DIR"

assert_precondition "a test user exists" test -n "$TEST_USER"
assert_precondition "$TEST_USER is not in adm" \
    sh -c "! id -nG '$TEST_USER' | tr ' ' '\n' | grep -qx adm"
assert_precondition "the log exists and is unreadable to $TEST_USER" \
    sh -c "[ -f '$LOG_FILE' ] && ! su -s /bin/sh '$TEST_USER' -c '[ -r \"$LOG_FILE\" ]'"

run_uut_as "$TEST_USER" scripts/common/system_health_check.sh

assert_exit_zero
assert_output_contains "cannot verify freshness"
assert_output_not_contains "may not be configured"

finish
