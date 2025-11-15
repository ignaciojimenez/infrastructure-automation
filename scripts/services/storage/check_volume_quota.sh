#!/bin/bash
#
# Volume quota check script
# Simplified version to work with enhanced_monitoring_wrapper
#
# Usage: check_volume_quota.sh dir threshold
# Example: check_volume_quota.sh / 60

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

usage(){
	echo "Usage: $(basename "$0") dir threshold"
	echo "  dir: Directory to check (e.g., /)"
	echo "  threshold: Percentage threshold (e.g., 60)"
}

# Validate arguments
if [ $# -lt 2 ]; then
	usage
	exit 1
fi

dir=$1
threshold=$2

# Validate threshold is a number
if ! [[ $threshold =~ ^[0-9]+$ ]]; then
	echo "Error: Threshold must be a number. Received: $threshold"
	usage
	exit 1
fi

# Get current disk usage
CURRENT=$(df $dir | grep -v Filesystem | awk '{ print $5}' | sed 's/%//g')

if [ "$CURRENT" -gt "$threshold" ]; then
	echo "❌ Disk volume $dir is at ${CURRENT}% capacity (threshold: ${threshold}%)"
	echo ""
	echo "Disk usage details:"
	df -h
	exit 1
else
	echo "✅ Disk volume $dir is at ${CURRENT}% capacity (threshold: ${threshold}%)"
	exit 0
fi
