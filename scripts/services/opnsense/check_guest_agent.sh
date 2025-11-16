#!/bin/sh
# check_guest_agent.sh
# Monitor QEMU guest agent status
# Critical for graceful VM shutdowns and monitoring from Proxmox

# Check if process is actually running (need sudo to see root processes)
if ! sudo pgrep -q qemu-ga; then
    echo "CRITICAL: QEMU guest agent process not running"
    exit 2
fi

# Process is running - that's sufficient
# (Log errors at startup are common and don't mean the agent isn't working)
echo "OK: QEMU guest agent running"
exit 0
