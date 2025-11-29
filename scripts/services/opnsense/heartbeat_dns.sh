#!/bin/sh
# Heartbeat check for OPNsense Unbound DNS health
# Sends heartbeat only if DNS resolution is working
# Replaces old PiHole DNS heartbeat

set -e

# Configuration - uses Ansible vault variable (template)
HEALTHCHECK_URL="{{ vault_healthcheck_pihole_dns }}"
TEST_DOMAIN="mullvad.net"

# Test DNS resolution via Unbound
if drill @127.0.0.1 "$TEST_DOMAIN" A > /dev/null 2>&1; then
    # DNS is working, send heartbeat
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    elif command -v fetch >/dev/null 2>&1; then
        # FreeBSD's fetch command
        fetch -q -T 10 -o /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
fi

# Silent success - no output needed for cron
exit 0
