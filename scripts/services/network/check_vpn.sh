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

if ping -c 1 $VPN_GATEWAY > /dev/null; then
  echo "✅ VPN connection is active (gateway $VPN_GATEWAY is reachable)"
  exit 0
else
  echo "❌ VPN connection is down (gateway $VPN_GATEWAY is not reachable)"
  exit 1
fi
