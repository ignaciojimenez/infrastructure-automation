#!/bin/bash
# Heartbeat check for Home Assistant
# Only sends heartbeat if Docker is running, HA container is up, and web API responds

set -e

# Configuration
HEALTHCHECK_URL="{{ vault_healthcheck_ha }}"

# Check Docker service
if ! systemctl is-active --quiet docker; then
    exit 0
fi

# Check HA container is running
if ! docker inspect --format='{{ '{{' }}.State.Running{{ '}}' }}' home-assistant 2>/dev/null | grep -q true; then
    exit 0
fi

# Check HA web API responds
if ! curl -s -f -o /dev/null --max-time 10 http://localhost:8123; then
    exit 0
fi

# All checks pass, send heartbeat
curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true

exit 0
