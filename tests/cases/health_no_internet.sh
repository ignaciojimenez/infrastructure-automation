#!/bin/sh
# Loss of internet connectivity must produce a non-zero exit.
#
# This is the check that would have caught the 2026-08-03 CrowdSec cutoff
# within 15 minutes, had it been capable of failing.
#
# Connectivity is broken by pointing DNS at TEST-NET-1 (RFC 5737, guaranteed
# unroutable) rather than by removing the default route. Removing the route
# would also kill the SSH session running this test, so `cleanup` would never
# run and the container would be left unreachable.

. "$(dirname "$0")/../lib/harness.sh"

RESOLV_BACKUP=/var/tmp/resolv.conf.testbak

describe "unreachable internet fails the check"

cleanup() {
    if [ -f "$RESOLV_BACKUP" ]; then
        cat "$RESOLV_BACKUP" > /etc/resolv.conf
        rm -f "$RESOLV_BACKUP"
    fi
}

cat /etc/resolv.conf > "$RESOLV_BACKUP"
printf 'nameserver 192.0.2.1\noptions timeout:1 attempts:1\n' > /etc/resolv.conf

assert_precondition "google.com no longer resolves" sh -c '! ping -c1 -W2 google.com >/dev/null 2>&1'

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "Internet: unreachable"

finish
