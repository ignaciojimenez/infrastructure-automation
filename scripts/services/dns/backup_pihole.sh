#!/bin/bash
# 
# Script to backup pihole configuration using the official Pi-hole Teleporter

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

# Validate required arguments
if [ -z "$email" ]; then
  log_msg "${RED}Error: Email address is required${NC}"
  usage
  exit 1
fi

# If not in silent mode, webhook tokens are required
if [ "$silent_mode" != "true" ] && ([ -z "$logging_token" ] || [ -z "$alert_token" ]); then
  log_msg "${RED}Error: Webhook tokens are required unless --silent is used${NC}"
  usage
  exit 1
fi

# We're using a different approach now, but keeping the same naming convention for compatibility
BACKUP_FILE="/tmp/pihole_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

# No need to create a temp directory anymore as the teleporter command handles this

# Create backup using Pi-hole's official teleporter command
log_msg "${GREEN}Creating Pi-hole backup using teleporter${NC}"
TELEPORTER_OUTPUT=$(sudo pihole-FTL --teleporter 2>&1) || {
  log_msg "${RED}Error: Failed to create teleporter backup${NC}"
  log_msg "${RED}Error details: ${TELEPORTER_OUTPUT}${NC}"
  exit 1
}

# Extract the backup filename from the command output
BACKUP_FILENAME=$(echo "$TELEPORTER_OUTPUT" | grep -E 'pi-hole.*\.zip$' | tr -d '[:space:]')
if [ -z "$BACKUP_FILENAME" ]; then
  log_msg "${RED}Error: Could not determine teleporter backup filename${NC}"
  log_msg "${RED}Output was: ${TELEPORTER_OUTPUT}${NC}"
  exit 1
fi

# Check if the backup file exists and is readable
if [ ! -f "$BACKUP_FILENAME" ]; then
  log_msg "${RED}Error: Teleporter backup file not found: ${BACKUP_FILENAME}${NC}"
  exit 1
fi

# Move the teleporter backup to our standard location
log_msg "Moving teleporter backup to ${BACKUP_FILE}"
mv "$BACKUP_FILENAME" "${BACKUP_FILE}" || {
  log_msg "${RED}Error: Failed to move teleporter backup${NC}"
  exit 1
}

# Ensure ansible user can read the archive
sudo chown $(whoami):$(whoami) "${BACKUP_FILE}" || {
  log_msg "${YELLOW}Warning: Failed to change ownership of backup file${NC}"
  # Continue anyway
}

log_msg "${GREEN}Created backup archive: ${BACKUP_FILE}${NC}"

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
  log_msg "${GREEN}Pihole configuration backup completed successfully${NC}"
else
  log_msg "${RED}Pihole configuration backup failed with exit code: ${backup_exit_code}${NC}"
  exit $backup_exit_code
fi

# Clean up
log_msg "Cleaning up temporary files"
sudo rm -f "${BACKUP_FILE}"
