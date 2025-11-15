#!/bin/bash
set -e

if dig +short +timeout=5 +tries=1 @127.0.0.1 google.com > /dev/null; then
	echo "✅ DNS resolution working correctly"
else
	echo "❌ DNS resolution failed - attempting to restart Pi-hole FTL"
	sudo systemctl restart pihole-FTL
	sleep 5
	if dig +short +timeout=5 +tries=1 @127.0.0.1 google.com > /dev/null; then
		echo "✅ DNS resolution fixed after restarting Pi-hole FTL"
	else
		echo "❌ DNS resolution still failing after restart"
		exit 1
	fi
fi
