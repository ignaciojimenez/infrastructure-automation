#!/bin/bash
#
# Sync vzdump snapshots to USB recovery drive
# Thin wrapper around usb_recovery_helper (root-owned)

set -e
set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_msg() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --mount-point=PATH   USB mount point (default: /mnt/usb-recovery)"
    echo "  --guest-ids=IDS      Comma-separated guest IDs (default: 100,101)"
    echo "  --silent             Run in silent mode (for use with monitoring wrapper)"
    echo "  --help               Show this help message"
}

# Defaults
mount_point="/mnt/usb-recovery"
guest_ids="100,101"
silent_mode=false

while [ $# -gt 0 ]; do
    case "$1" in
        --mount-point=*)
            mount_point="${1#--mount-point=}"
            shift
            ;;
        --guest-ids=*)
            guest_ids="${1#--guest-ids=}"
            shift
            ;;
        --silent)
            silent_mode=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_msg "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECOVERY_TXT="${SCRIPT_DIR}/RECOVERY.txt"

# Build helper arguments
helper_args="sync --mount-point=${mount_point} --guest-ids=${guest_ids}"
if [ -f "$RECOVERY_TXT" ]; then
    helper_args="${helper_args} --recovery-txt=${RECOVERY_TXT}"
fi

log_msg "Starting USB recovery sync..."
log_msg "  Mount point: $mount_point"
log_msg "  Guest IDs: $guest_ids"

if sudo /usr/local/bin/usb_recovery_helper $helper_args; then
    log_msg "${GREEN}USB recovery sync completed successfully${NC}"
else
    result=$?
    log_msg "${RED}USB recovery sync failed with exit code: $result${NC}"
    exit $result
fi
