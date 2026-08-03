#!/bin/sh
# Loss of internet connectivity must produce a non-zero exit.
#
# This is the check that would have caught the 2026-08-03 CrowdSec cutoff
# within 15 minutes, had it been capable of failing.
#
# The fault is arranged with an /etc/hosts entry pointing the probed name at
# TEST-NET-1 (RFC 5737, guaranteed unroutable). nsswitch.conf is `files dns`,
# so the override wins without touching the resolver, the routing table, or
# anything the SSH session running this test depends on.
#
# Two approaches were tried first and do not work here:
#
#   - Removing the default route would sever the SSH session, so `cleanup`
#     would never run and the container would be left unreachable.
#
#   - Pointing resolv.conf at an unroutable nameserver does nothing on this
#     network: OPNsense transparently redirects outbound port 53 to Unbound,
#     so a query to 192.0.2.1 is answered anyway (verified 2026-08-04 — ICMP
#     to that address is dropped while DNS to it returns a valid answer). No
#     host on this LAN can be isolated from DNS by editing its own config.

. "$(dirname "$0")/../lib/harness.sh"

HOSTS_BACKUP=/var/tmp/hosts.testbak

describe "unreachable internet fails the check"

cleanup() {
    if [ -f "$HOSTS_BACKUP" ]; then
        cat "$HOSTS_BACKUP" > /etc/hosts
        rm -f "$HOSTS_BACKUP"
    fi
}

cat /etc/hosts > "$HOSTS_BACKUP"
printf '192.0.2.1 google.com\n' >> /etc/hosts

assert_precondition "google.com is unreachable" sh -c '! ping -c1 -W2 google.com >/dev/null 2>&1'

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "Internet: unreachable"

finish
