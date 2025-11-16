#!/bin/sh
# check_wg.sh
# Monitor WireGuard tunnel status
# Only checks client tunnels (wg0, wg2-12), ignores server interface (wg1)

# Check if WireGuard is running
if ! wg show > /dev/null 2>&1; then
    echo "CRITICAL: WireGuard not configured or not running"
    exit 2
fi

# Get list of interfaces
interfaces=$(wg show interfaces)

if [ -z "$interfaces" ]; then
    echo "WARNING: No WireGuard interfaces found"
    exit 1
fi

# Check each interface (skip wg1 which is server interface)
all_ok=1
down_interfaces=""
active_count=0
total_count=0

for iface in $interfaces; do
    # Skip wg1 (server interface for incoming connections)
    if [ "$iface" = "wg1" ]; then
        continue
    fi
    
    total_count=$((total_count + 1))
    
    # Check if interface has an active handshake
    # Get the most recent handshake for this interface
    latest_handshake=$(wg show "$iface" latest-handshakes | awk '{if ($2 > max) max = $2} END {print max}')
    
    if [ -z "$latest_handshake" ] || [ "$latest_handshake" = "0" ]; then
        all_ok=0
        down_interfaces="$down_interfaces $iface"
    else
        # Check if handshake is recent (within last 5 minutes = 300 seconds)
        # Use expr for arithmetic (POSIX-compliant)
        current_time=$(date +%s)
        time_since_handshake=$(expr "$current_time" - "$latest_handshake" 2>/dev/null || echo 999)
        
        if [ "$time_since_handshake" -gt 300 ]; then
            all_ok=0
            down_interfaces="$down_interfaces $iface(stale)"
        else
            active_count=$((active_count + 1))
        fi
    fi
done

if [ $all_ok -eq 0 ]; then
    echo "CRITICAL: WireGuard tunnels down or stale:$down_interfaces (${active_count}/${total_count} active)"
    exit 2
fi

echo "OK: All WireGuard client tunnels have recent handshakes (${active_count}/${total_count})"
exit 0
