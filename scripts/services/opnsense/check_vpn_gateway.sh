#!/bin/sh
# check_vpn_gateway.sh
# Track VPN gateway changes and notify on automatic failovers
# Monitors Mullvad gateway changes, WAN IP changes, and manual switches

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

STATE_DIR="/var/run/monitoring-state"
STATE_FILE="$STATE_DIR/vpn_gateway_state.json"

# Create state directory
mkdir -p "$STATE_DIR"

# Get current WAN IP
current_wan_ip=$(curl -s --max-time 5 https://api.ipify.org || echo "unknown")

# Get current WireGuard gateway (if active)
current_wg_gateway=""
current_wg_endpoint=""
if wg show > /dev/null 2>&1; then
    # Get the first WireGuard interface's endpoint
    current_wg_endpoint=$(wg show all endpoints | head -1 | awk '{print $2}' | cut -d: -f1)
fi

# Get routing gateway
current_route_gateway=$(netstat -rn | grep '^default' | head -1 | awk '{print $2}')

# Read previous state
if [ -f "$STATE_FILE" ]; then
    prev_wan_ip=$(grep 'wan_ip' "$STATE_FILE" | cut -d'"' -f4)
    prev_wg_endpoint=$(grep 'wg_endpoint' "$STATE_FILE" | cut -d'"' -f4)
    prev_route_gateway=$(grep 'route_gateway' "$STATE_FILE" | cut -d'"' -f4)
else
    # First run - just record state
    printf '{\n  "wan_ip": "%s",\n  "wg_endpoint": "%s",\n  "route_gateway": "%s",\n  "timestamp": "%s"\n}\n' \
        "$current_wan_ip" "$current_wg_endpoint" "$current_route_gateway" "$(date +%s)" > "$STATE_FILE"
    echo "OK: VPN gateway state recorded (first run)"
    exit $EXIT_OK
fi

# Compare states and determine what changed
changes=""
change_type="info"

if [ "$current_wan_ip" != "$prev_wan_ip" ] && [ -n "$prev_wan_ip" ]; then
    changes="${changes}WAN IP changed: $prev_wan_ip -> $current_wan_ip\n"
    change_type="info"
fi

if [ "$current_wg_endpoint" != "$prev_wg_endpoint" ] && [ -n "$prev_wg_endpoint" ]; then
    changes="${changes}WireGuard endpoint changed: $prev_wg_endpoint -> $current_wg_endpoint\n"
    # This is likely an automatic Mullvad failover - alert
    change_type="alert"
fi

if [ "$current_route_gateway" != "$prev_route_gateway" ] && [ -n "$prev_route_gateway" ]; then
    changes="${changes}Default gateway changed: $prev_route_gateway -> $current_route_gateway\n"
    change_type="alert"
fi

# Update state file
printf '{\n  "wan_ip": "%s",\n  "wg_endpoint": "%s",\n  "route_gateway": "%s",\n  "timestamp": "%s"\n}\n' \
    "$current_wan_ip" "$current_wg_endpoint" "$current_route_gateway" "$(date +%s)" > "$STATE_FILE"

# Output results
if [ -n "$changes" ]; then
    if [ "$change_type" = "alert" ]; then
        printf "ALERT: VPN Gateway Failover Detected\n"
        printf "%b" "$changes"
        printf "\nCurrent state:\n"
        printf "  WAN IP: %s\n" "$current_wan_ip"
        printf "  WireGuard endpoint: %s\n" "$current_wg_endpoint"
        printf "  Default gateway: %s\n" "$current_route_gateway"
        exit $EXIT_WARNING  # Return warning to trigger alert notification
    else
        printf "INFO: Network configuration changed\n"
        printf "%b" "$changes"
        exit $EXIT_OK
    fi
else
    # No changes - quiet success
    exit $EXIT_OK
fi
