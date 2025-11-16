#!/bin/sh
# Heartbeat check for PiHole DNS health
# Only sends heartbeat if DNS resolution is working

set -e

# Configuration
HEALTHCHECK_URL="{{ vault_healthcheck_pihole_dns }}"
TEST_DOMAIN="google.com"

# Test DNS resolution locally
if dig @127.0.0.1 "$TEST_DOMAIN" +short +timeout=5 >/dev/null 2>&1; then
    # DNS is working, send heartbeat
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -t 3 -O /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
fi

# Silent success - no output needed for cron
exit 0
