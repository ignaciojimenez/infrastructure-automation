#!/bin/sh
# check_gateway.sh
# Check if WAN gateway is reachable
# Ported from opnsense-monitoring repo

# Try to ping common reliable hosts
if ! ping -c 2 -W 3 1.1.1.1 > /dev/null 2>&1; then
    if ! ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1; then
        echo "CRITICAL: WAN gateway unreachable (cannot ping 1.1.1.1 or 8.8.8.8)"
        exit 2
    fi
fi

echo "OK: WAN gateway is reachable"
exit 0
