#!/bin/sh
# Backup freshness heartbeat — {{ backup_heartbeat_name }}
# Pings healthchecks.io only if the last backup succeeded recently
# Follows the same pattern as heartbeat_ha.sh, heartbeat_dns.sh, etc.

set -e

# Configuration (injected by Ansible template)
HEALTHCHECK_URL="{{ backup_healthcheck_url }}"
STATE_FILE="{{ backup_state_file }}"
MAX_AGE_MINUTES={{ backup_max_age_minutes }}

# State file must exist
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

# State file must be recent (mtime within MAX_AGE_MINUTES)
if ! find "$STATE_FILE" -mmin -"$MAX_AGE_MINUTES" 2>/dev/null | grep -q .; then
    exit 0
fi

# Last backup must have succeeded
if ! jq -e '.last_status == "success"' "$STATE_FILE" >/dev/null 2>&1; then
    exit 0
fi

# Fresh and successful — send heartbeat.
#
# ⚠️ The exit status is captured and reported. It used to be `|| true` with
# stderr discarded, which makes this the one thing a dead-man's switch must
# never be: unable to say that its OWN ping failed. The failure it produces is
# indistinguishable from the failure it exists to detect — healthchecks.io goes
# DOWN either way, and nothing on this side records which. That ambiguity is a
# live question right now: backup_homeassistant / backup_unifi / backup_opnsense
# all go DOWN then UP overnight, across three independent hosts, and the reason
# this script left no trace is why it is still unresolved (see docs/TODO.md F3).
#
# Still exits 0 regardless. A heartbeat script that fails the cron job because
# hc-ping.com was briefly unreachable would turn an unreliable network into a
# Slack alert, which is the opposite of the point. Report, do not escalate.
# `|| ping_status=$?` rather than a bare assignment: this file runs under
# `set -e`, and a plain `var=$(failing_cmd)` aborts the script on the spot — so
# the status would never be captured and the report below would never run. The
# `||` list suppresses that, which is the entire reason for the shape.
ping_status=0
ping_err=""
if command -v curl >/dev/null 2>&1; then
    ping_err=$(curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" 2>&1 >/dev/null) || ping_status=$?
elif command -v fetch >/dev/null 2>&1; then
    # FreeBSD's fetch command
    ping_err=$(fetch -q -T 10 -o /dev/null "$HEALTHCHECK_URL" 2>&1 >/dev/null) || ping_status=$?
else
    echo "heartbeat: no curl or fetch available - heartbeat NOT sent" >&2
    exit 0
fi

if [ "$ping_status" -ne 0 ]; then
    echo "heartbeat: ping FAILED (exit ${ping_status}): ${ping_err}" >&2
fi

exit 0
