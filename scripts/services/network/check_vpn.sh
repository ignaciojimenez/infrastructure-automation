#!/bin/bash
# 
# Script to check VPN connection status

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <vpn_gateway>"
  exit 1
fi

VPN_GATEWAY="$1"

# 3 packets, 2 s each, success on ANY reply. A single `ping -c 1` pages the
# watched channel on one dropped packet — which is normal behaviour for ICMP
# inside a UDP-encapsulated WireGuard tunnel, not a fault. Observed 2026-08-23
# 09:00: one lost packet, the default 10 s linger expired (the alert's
# "Duration: 10 seconds"), and a re-check moments later showed 0% loss.
# Mirrors binary_sensor.vinylstreamer_online, which already probes this way.
if ping -c 3 -W 2 "$VPN_GATEWAY" > /dev/null 2>&1; then
  echo "✅ VPN connection is active (gateway $VPN_GATEWAY is reachable)"
  exit 0
else
  echo "❌ VPN connection is down (gateway $VPN_GATEWAY is not reachable)"
  exit 1
fi
