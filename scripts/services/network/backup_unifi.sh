#!/bin/bash
# 
# Script to backup Unifi Controller configuration

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_msg() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Parse command line arguments
silent_mode=false
logging_token=""
alert_token=""
email=""

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --logging=TOKEN   Slack webhook token for success notifications"
  echo "  --alert=TOKEN     Slack webhook token for failure notifications"
  echo "  --email=ADDRESS   Email address for GPG encryption (REQUIRED)"
  echo "  --silent          Run in silent mode (no notifications, for use with monitoring wrapper)"
  echo "  --help            Show this help message"
  echo ""
  echo "For backward compatibility: $0 <logging_token> <alert_token> <upload_service> <email>"
}

# Check if using the old argument format (for backward compatibility)
if [ "$#" -ge 4 ] && [[ $1 == T* ]] && [[ $2 == T* ]]; then
  # Old format
  logging_token="$1"
  alert_token="$2"
  # Ignore upload_service parameter as we now use curlbin.ignacio.systems
  email="$4"
else
  # New format with named options
  while [ $# -gt 0 ]; do
    case "$1" in
      --logging=*)
        logging_token="${1#--logging=}"
        shift
        ;;
      --alert=*)
        alert_token="${1#--alert=}"
        shift
        ;;
      --email=*)
        email="${1#--email=}"
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
fi

# Fix webhook tokens if they still contain the option prefix
if [[ $logging_token == --logging=* ]]; then
  logging_token=${logging_token#--logging=}
fi

if [[ $alert_token == --alert=* ]]; then
  alert_token=${alert_token#--alert=}
fi

# Validate required arguments if not in silent mode
if [ "$silent_mode" != "true" ] && ([ -z "$logging_token" ] || [ -z "$alert_token" ] || [ -z "$email" ]); then
  log_msg "${RED}Error: Missing required arguments${NC}"
  usage
  exit 1
elif [ "$silent_mode" == "true" ] && [ -z "$email" ]; then
  log_msg "${RED}Error: Email address is required even in silent mode${NC}"
  usage
  exit 1
fi

UNIFI_BACKUP_DIR="/var/lib/unifi/backup/autobackup"
TEMP_DIR="/tmp/unifi_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="/tmp/unifi_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

# Check if backup directory exists and is accessible (may need sudo)
if ! sudo test -d "${UNIFI_BACKUP_DIR}"; then
  log_msg "${RED}Error: Unifi backup directory not found or not accessible: ${UNIFI_BACKUP_DIR}${NC}"
  exit 1
fi

# Create temp directory for backup
mkdir -p "${TEMP_DIR}" || {
  log_msg "${RED}Error: Failed to create temp directory: ${TEMP_DIR}${NC}"
  exit 1
}

# Find the most recent backup file (using sudo since files are owned by unifi user)
LATEST_BACKUP=$(sudo find "${UNIFI_BACKUP_DIR}" -name "*.unf" -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | awk '{print $2}')

if [ -z "${LATEST_BACKUP}" ]; then
  log_msg "${RED}Error: No backup files found in ${UNIFI_BACKUP_DIR}${NC}"
  exit 1
fi

# Also copy the meta file which contains information about all backups
META_FILE="${UNIFI_BACKUP_DIR}/autobackup_meta.json"

log_msg "${GREEN}Found latest backup: $(basename "${LATEST_BACKUP}")${NC}"

# Copy files to temp directory (using sudo since files are owned by unifi user)
sudo cp "${LATEST_BACKUP}" "${TEMP_DIR}/" || {
  log_msg "${RED}Error: Failed to copy backup file to temp directory${NC}"
  exit 1
}

if sudo test -f "${META_FILE}"; then
  sudo cp "${META_FILE}" "${TEMP_DIR}/" || {
    log_msg "${YELLOW}Warning: Failed to copy meta file to temp directory${NC}"
    # Continue anyway as this is not critical
  }
fi

# Change ownership and permissions so that ansible user can read/write the files
sudo chown -R $(whoami):$(whoami) "${TEMP_DIR}" || {
  log_msg "${YELLOW}Warning: Failed to change ownership of temp directory${NC}"
  # Continue anyway, but use sudo for tar command
}

# Create archive (may need sudo if ownership change failed)
if [ -w "${TEMP_DIR}" ]; then
  tar -czf "${BACKUP_FILE}" -C "${TEMP_DIR}" . || {
    log_msg "${RED}Error: Failed to create archive${NC}"
    exit 1
  }
else
  # Fallback to using sudo for tar if ownership change failed
  sudo tar -czf "${BACKUP_FILE}" -C "${TEMP_DIR}" . || {
    log_msg "${RED}Error: Failed to create archive${NC}"
    exit 1
  }
  # Ensure ansible user can read the archive
  sudo chown $(whoami):$(whoami) "${BACKUP_FILE}" || {
    log_msg "${YELLOW}Warning: Failed to change ownership of backup file${NC}"
    # Continue anyway
  }
fi

log_msg "Created backup archive: ${BACKUP_FILE}"

# Look for do_backup script in common locations
DO_BACKUP_SCRIPT=""
for path in "/home/$(whoami)/.scripts/do_backup" "/usr/local/bin/do_backup" "$(dirname "$0")/../common_scripts/do_backup"; do
  if [ -f "$path" ]; then
    DO_BACKUP_SCRIPT="$path"
    break
  fi
done

# If do_backup script not found, try to find it in the repository structure
if [ -z "$DO_BACKUP_SCRIPT" ]; then
  # Try to find it relative to this script
  repo_root=$(dirname "$(dirname "$0")")
  if [ -f "$repo_root/common_scripts/do_backup" ]; then
    DO_BACKUP_SCRIPT="$repo_root/common_scripts/do_backup"
  fi
fi

# Require do_backup script to be available
if [ -z "$DO_BACKUP_SCRIPT" ]; then
  log_msg "${RED}ERROR: do_backup script not found. This script requires do_backup to be available.${NC}"
  log_msg "${YELLOW}Please ensure do_backup is installed in one of the following locations:${NC}"
  log_msg "  - /home/$(whoami)/.scripts/do_backup"
  log_msg "  - /usr/local/bin/do_backup"
  log_msg "  - $(dirname "$0")/../common_scripts/do_backup"
  exit 1
fi

log_msg "${GREEN}Using do_backup script: $DO_BACKUP_SCRIPT${NC}"

# Use the appropriate do_backup command based on silent mode
if [ "$silent_mode" == "true" ]; then
  # In silent mode, we only need to pass the file and recipient
  log_msg "Running do_backup in silent mode"
  "$DO_BACKUP_SCRIPT" --silent "$BACKUP_FILE" "$email"
else
  # When not in silent mode, we need to provide the webhook tokens
  log_msg "Running do_backup with notifications"
  "$DO_BACKUP_SCRIPT" --logging="$logging_token" --alert="$alert_token" "$BACKUP_FILE" "$email"
fi
backup_exit_code=$?

if [ $backup_exit_code -eq 0 ]; then
  log_msg "${GREEN}Unifi configuration backup completed successfully${NC}"
else
  log_msg "${RED}Unifi configuration backup failed with exit code: ${backup_exit_code}${NC}"
  exit $backup_exit_code
fi

# Clean up
log_msg "Cleaning up temporary files"
sudo rm -rf "${TEMP_DIR}" "${BACKUP_FILE}"

exit 0
