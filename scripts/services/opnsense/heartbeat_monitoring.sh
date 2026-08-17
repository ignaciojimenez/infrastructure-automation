#!/bin/sh
# Heartbeat asserting that opnsense's own monitoring still RUNS.
#
# ⚠️ Pings UNCONDITIONALLY, and that is the entire point of this file.
#
# The two heartbeats beside it are deliberately conditional — heartbeat_opnsense_wan.sh
# pings only when the default gateway answers, heartbeat_dns.sh only when Unbound
# resolves. That is correct for what they assert (WAN health, DNS health), and it
# makes both of them useless for the question asked here.
#
# Because if the ping is gated on the checked thing being healthy, then a stale
# check means "the WAN is down" OR "cron stopped running" OR "the script broke" —
# and those are exactly the states that must be told apart. A monitoring system
# that cannot distinguish "the observer died" from "the observed is unwell" is
# the failure mode this fleet keeps rediscovering.
#
# So this one asserts one narrow, honest thing: **cron is alive on this host and
# it is still executing monitoring scripts.** It deliberately checks nothing,
# because anything it checked would become a reason not to ping.
#
# Same reasoning as the dead-man's switch in the agent-lxc fleet sweep, which
# pings even when it has findings, and the opposite of heartbeat_backup.sh, which
# pings only on recent success because it asserts freshness of a backup rather
# than existence of a run.
#
# Why this host needs its own file at all: FreeBSD's cron does not log job
# executions to syslog, unlike Debian's, so the fleet sweep's journal-based
# check_wrapper_freshness has no FreeBSD analogue. opnsense was the one host in
# the fleet whose monitoring could stop silently. Measured 2026-08-17: the
# firewall's entire system log contained five cron lines, all of them the service
# starting at boot, months apart.

set -e

HEALTHCHECK_URL="{{ vault_healthcheck_opnsense_monitoring }}"

[ -n "$HEALTHCHECK_URL" ] || exit 0

if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
elif command -v fetch >/dev/null 2>&1; then
    # FreeBSD base; curl is not guaranteed present.
    fetch -q -T 10 -o /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
fi

# Never fails. A heartbeat that can fail the cron it rides on is a liability,
# and hc-ping.com being unreachable is healthchecks.io's problem to alert on.
exit 0
