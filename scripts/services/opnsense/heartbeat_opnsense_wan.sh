#!/bin/sh
# Heartbeat check for OPNsense WAN connectivity
# Only sends heartbeat if WAN gateway is reachable

set -e

# Configuration
HEALTHCHECK_URL="{{ vault_healthcheck_opnsense_wan }}"

# Get default gateway
GATEWAY=$(route -n get default 2>/dev/null | grep 'gateway:' | awk '{print $2}')

if [ -z "$GATEWAY" ]; then
    # No default gateway, can't check
    exit 0
fi

# Test gateway reachability
if ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
    # Gateway is reachable, send heartbeat
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    elif command -v fetch >/dev/null 2>&1; then
        # FreeBSD's fetch command
        fetch -q -T 10 -o /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
fi

# Silent success - no output needed for cron
exit 0
