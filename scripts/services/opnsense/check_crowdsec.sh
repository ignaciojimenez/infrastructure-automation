#!/bin/sh
# check_crowdsec.sh
# Monitor CrowdSec service status
# Note: Only runs if CrowdSec is installed

# Check if CrowdSec is installed
if ! command -v cscli > /dev/null 2>&1; then
    echo "OK: CrowdSec not installed (skipping check)"
    exit 0
fi

# Check if crowdsec process is actually running (need sudo to see all processes)
if ! sudo pgrep -f "crowdsec -c" > /dev/null 2>&1; then
    echo "CRITICAL: CrowdSec process not running"
    exit 2
fi

# Check if bouncer is running (match full command line)
if ! sudo pgrep -f "crowdsec-firewall-bouncer" > /dev/null 2>&1; then
    echo "WARNING: CrowdSec running but firewall bouncer not running"
    exit 1
fi

# Both main components running - that's sufficient
# (LAPI may use unix socket or different config in OPNsense plugin)
echo "OK: CrowdSec and firewall bouncer running"
exit 0
