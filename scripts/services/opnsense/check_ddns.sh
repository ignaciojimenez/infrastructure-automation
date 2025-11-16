#!/bin/sh
# check_ddns.sh
# Verify that DDNS updates your freemyip.com record properly
# Ported from opnsense-monitoring repo

HOST="chocohome.freemyip.com"
WAN_IP=$(curl -s https://api.ipify.org)

if [ -z "$WAN_IP" ]; then
  echo "CRITICAL: Could not fetch current WAN IP"
  exit 2
fi

DNS_IP=$(host -4 "$HOST" | awk '/has address/ {print $4}' | tail -n1)

if [ -z "$DNS_IP" ]; then
  echo "CRITICAL: DNS lookup for $HOST failed"
  exit 2
fi

if [ "$WAN_IP" != "$DNS_IP" ]; then
  echo "CRITICAL: IP mismatch - WAN is $WAN_IP but $HOST resolves to $DNS_IP"
  exit 2
fi

echo "OK: DDNS is up to date - $HOST resolves to $WAN_IP"
exit 0
