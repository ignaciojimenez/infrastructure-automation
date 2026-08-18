#!/bin/sh
# Loss of connectivity must produce a non-zero exit — and must say WHICH layer
# is broken.
#
# This is the check that would have caught the 2026-08-03 CrowdSec cutoff
# within 15 minutes, had it been capable of failing.
#
# ⚠️ This case was stale from 2026-08-13 until 2026-08-18 and is the reason the
# suite was red. It blocked only the NAME and asserted "Internet: unreachable",
# but check_network had been rewritten to probe a name AND an IP literal
# precisely so it could tell a dead resolver apart from a dead link. Blocking
# the name alone now yields the resolver branch, correctly. The check got
# smarter; the case was never updated. **The check was right and the test was
# wrong** — worth naming, because the reflex is to "fix" the script until the
# old assertion passes again, which would undo a real improvement.
#
# So both branches are exercised now, in the order that makes the second one
# meaningful:
#
#   name blocked, IP reachable  → resolver problem, exit non-zero
#   name blocked, IP blocked    → genuine outage,   exit non-zero
#
# Asserting the WORDING and not just the exit status is not decoration. Before
# the 2026-08-18 fixes this case "satisfied" assert_exit_nonzero while the
# network was fine — an unrelated stale-upgrade failure was supplying the
# non-zero exit. A case that asserts only on exit status passes for any reason
# at all, including the ones it was written to rule out.
#
# The two faults are arranged differently because the two targets resolve
# differently:
#
#   NAME — an /etc/hosts entry pointing it at TEST-NET-1 (RFC 5737, guaranteed
#   unroutable). nsswitch.conf is `files dns`, so the override wins without
#   touching the resolver, the routing table, or anything the SSH session
#   running this test depends on.
#
#   IP LITERAL — a blackhole route for that address alone. /etc/hosts cannot
#   touch an IP literal, and the two alternatives are both worse: removing the
#   default route severs the SSH session, so `cleanup` never runs and the
#   container is left unreachable; and pointing resolv.conf at an unroutable
#   nameserver does nothing on this network, because OPNsense transparently
#   redirects outbound port 53 to Unbound (verified 2026-08-04 — ICMP to
#   192.0.2.1 is dropped while DNS to it returns a valid answer). A /32
#   blackhole is surgical: the test host stays reachable on 10.30.40.0/24.

. "$(dirname "$0")/../lib/harness.sh"

UUT=scripts/common/system_health_check.sh
HOSTS_BACKUP=/var/tmp/hosts.testbak

describe "a dead resolver and a dead link fail the check, and are told apart"

# The probed targets are read out of the script under test rather than restated
# here. A case that hardcodes 1.1.1.1 keeps testing 1.1.1.1 long after the
# script has moved on, and reports green while covering nothing.
#
# Deliberately no `\|` alternation — that is a GNU sed extension, and this file
# is meant to stay readable to anyone porting the rig to a BSD target.
_probe_default() {
    sed -n "s/^NETWORK_PROBE_$1=\"\${NETWORK_PROBE_$1:-\([^}]*\)}\"/\1/p" "$UUT_ROOT/$UUT"
}
PROBE_IP=$(_probe_default IP)
PROBE_NAME=$(_probe_default NAME)

route_added=no

cleanup() {
    if [ -f "$HOSTS_BACKUP" ]; then
        cat "$HOSTS_BACKUP" > /etc/hosts
        rm -f "$HOSTS_BACKUP"
    fi
    [ "$route_added" = yes ] && ip route del blackhole "$PROBE_IP/32" >/dev/null 2>&1
    return 0
}

# Assert what the parse YIELDED, not that it ran. An empty PROBE_IP would make
# every arrangement below a no-op and every assertion below vacuous.
assert_precondition "the script's probe targets were parsed out of it" \
    sh -c "[ -n '$PROBE_IP' ] && [ -n '$PROBE_NAME' ]"
note "probing name=$PROBE_NAME ip=$PROBE_IP (read from $UUT)"

# ------------------------------------------------------------------
# 1. Name unreachable, IP fine — a resolver fault, not an outage
# ------------------------------------------------------------------
cat /etc/hosts > "$HOSTS_BACKUP"
printf '192.0.2.1 %s\n' "$PROBE_NAME" >> /etc/hosts

assert_precondition "$PROBE_NAME is unreachable" \
    sh -c "! ping -c1 -W2 $PROBE_NAME >/dev/null 2>&1"
assert_precondition "$PROBE_IP is still reachable" \
    sh -c "ping -c1 -W2 $PROBE_IP >/dev/null 2>&1"

run_uut_as "$INFRA_USER" "$UUT"

assert_exit_nonzero
assert_output_contains "resolver problem, not connectivity"
# The distinction is the whole point of probing two targets. If this branch
# ever reported a plain outage again, the operator would be sent to look at
# the link instead of at Unbound.
assert_output_not_contains "Internet: unreachable"

# ------------------------------------------------------------------
# 2. Both unreachable — a genuine outage
# ------------------------------------------------------------------
ip route add blackhole "$PROBE_IP/32" >/dev/null 2>&1 && route_added=yes

assert_precondition "the blackhole route took effect" \
    sh -c "! ping -c1 -W2 $PROBE_IP >/dev/null 2>&1"

run_uut_as "$INFRA_USER" "$UUT"

assert_exit_nonzero
assert_output_contains "Internet: unreachable"

finish
