#!/bin/bash
#
# Script to detect mount failures
# Simplified version to work with enhanced_monitoring_wrapper
#
# Usage: check_volume_mount.sh mountpoint
# Example: check_volume_mount.sh /mnt/almacenNTFS

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

usage(){
	echo "Usage: $(basename "$0") mountpoint"
	echo "  mountpoint: Directory to check (e.g., /mnt/almacenNTFS)"
}

# Validate arguments
if [ $# -lt 1 ]; then
	usage
	exit 1
fi

mnt=$1

# Check if volume is mounted
if ! grep -qs ${mnt} /proc/mounts; then
	echo "❌ Disk volume $mnt not mounted - attempting to remount"
	
	# Try to remount
	sudo umount -a || true
	sleep 2
	sudo mount -a || true
	
	# Check again
	if ! grep -qs ${mnt} /proc/mounts; then
		echo "❌ Failed to mount $mnt"
		echo ""
		echo "Current mounts:"
		df -aTh
		exit 1
	else
		echo "✅ Volume $mnt successfully remounted"
		exit 0
	fi
else
	echo "✅ Volume $mnt is mounted correctly"
	exit 0
fi
