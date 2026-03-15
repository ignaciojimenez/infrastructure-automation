#!/bin/sh
# check_wg.sh
# Monitor WireGuard tunnel status for Mullvad VPN
#
# Alert Levels (adjusted for 4-tunnel DNS resilience):
#   OK:       All tunnels active
#   WARNING:  1-2 tunnels down (DNS still has redundancy)
#   CRITICAL: 3+ tunnels down (DNS resilience compromised)
#
# Skips wg1 (server interface for incoming connections)

# Minimum tunnels needed for DNS resilience (we use 4 DNS servers)
MIN_TUNNELS_OK=3      # WARNING if fewer than this
MIN_TUNNELS_CRIT=2    # CRITICAL if fewer than this

# Check if WireGuard is running
if ! wg show > /dev/null 2>&1; then
    echo "CRITICAL: WireGuard not configured or not running"
    echo "  Impact: ALL VPN tunnels down, DNS will failover to Cloudflare"
    exit 2
fi

# Get list of interfaces
interfaces=$(wg show interfaces)

if [ -z "$interfaces" ]; then
    echo "CRITICAL: No WireGuard interfaces found"
    echo "  Impact: ALL VPN tunnels down, DNS will failover to Cloudflare"
    exit 2
fi

# Check each interface (skip wg1 which is server interface)
down_interfaces=""
stale_interfaces=""
active_count=0
total_count=0

for iface in $interfaces; do
    # Skip wg1 (server interface for incoming connections)
    if [ "$iface" = "wg1" ]; then
        continue
    fi
    
    total_count=$((total_count + 1))
    
    # Check if interface has an active handshake
    latest_handshake=$(wg show "$iface" latest-handshakes | awk '{if ($2 > max) max = $2} END {print max}')
    
    if [ -z "$latest_handshake" ] || [ "$latest_handshake" = "0" ]; then
        down_interfaces="$down_interfaces $iface"
    else
        # Check if handshake is recent (within last 5 minutes = 300 seconds)
        current_time=$(date +%s)
        time_since_handshake=$(expr "$current_time" - "$latest_handshake" 2>/dev/null || echo 999)
        
        if [ "$time_since_handshake" -gt 300 ]; then
            stale_interfaces="$stale_interfaces $iface"
        else
            active_count=$((active_count + 1))
        fi
    fi
done

# Determine alert level based on active tunnel count
failed_list=""
[ -n "$down_interfaces" ] && failed_list="down:$down_interfaces"
[ -n "$stale_interfaces" ] && failed_list="$failed_list stale:$stale_interfaces"

if [ "$active_count" -lt "$MIN_TUNNELS_CRIT" ]; then
    echo "CRITICAL: Only ${active_count}/${total_count} VPN tunnels active"
    echo "  Failed:$failed_list"
    echo "  Impact: DNS resilience COMPROMISED - may failover to Cloudflare"
    echo "  Action: Check Mullvad account or tunnel configuration"
    exit 2
elif [ "$active_count" -lt "$MIN_TUNNELS_OK" ]; then
    echo "WARNING: ${active_count}/${total_count} VPN tunnels active (degraded)"
    echo "  Failed:$failed_list"
    echo "  Impact: DNS still works but with reduced redundancy"
    echo "  Action: Investigate failed tunnels when convenient"
    exit 1
fi

echo "OK: ${active_count}/${total_count} VPN tunnels active"
exit 0
