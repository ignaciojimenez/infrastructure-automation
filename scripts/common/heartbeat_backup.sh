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

# Fresh and successful — send heartbeat
if command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
elif command -v fetch >/dev/null 2>&1; then
    # FreeBSD's fetch command
    fetch -q -T 10 -o /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
fi

exit 0
