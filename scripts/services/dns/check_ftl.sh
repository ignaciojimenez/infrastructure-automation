#!/bin/bash
set -e

if systemctl is-active --quiet pihole-FTL; then
	echo "✅ Pi-hole FTL service is running"
else
	echo "❌ Pi-hole FTL service is not running - attempting restart"
	sudo systemctl restart pihole-FTL
	sleep 5

	if systemctl is-active --quiet pihole-FTL; then
		echo "✅ Pi-hole FTL service was successfully restarted"
	else
		echo "❌ Failed to restart Pi-hole FTL service"
		exit 1
	fi
fi
