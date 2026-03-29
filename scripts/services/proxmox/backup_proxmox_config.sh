#!/bin/bash
# 
# Backup Proxmox configuration to curlbin
# Backs up /etc/pve/ (VM configs, storage, network, cluster settings)

set -e
set -u
set -o pipefail

# Configuration
BACKUP_DIR="/tmp"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/proxmox_config_${TIMESTAMP}.tar.gz"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_msg() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

usage() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --logging=TOKEN   Slack webhook token for success notifications"
  echo "  --alert=TOKEN     Slack webhook token for failure notifications"
  echo "  --recipient=KEY   age public key for encryption (REQUIRED)"
  echo "  --silent          Run in silent mode (for use with monitoring wrapper)"
  echo "  --help            Show this help message"
}

# Parse arguments
silent_mode=false
logging_token=""
alert_token=""
recipient=""

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
    --recipient=*)
      recipient="${1#--recipient=}"
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

# Validate required arguments
if [ -z "$recipient" ]; then
  log_msg "${RED}Error: Recipient public key is required${NC}"
  usage
  exit 1
fi

if [ "$silent_mode" != "true" ] && { [ -z "$logging_token" ] || [ -z "$alert_token" ]; }; then
  log_msg "${RED}Error: Webhook tokens required unless --silent is used${NC}"
  usage
  exit 1
fi

# Check /etc/pve exists
if [ ! -d /etc/pve ]; then
  log_msg "${RED}Error: /etc/pve not found - is this a Proxmox host?${NC}"
  exit 1
fi

log_msg "Starting Proxmox configuration backup"

# Create temp directory for collecting configs
TEMP_DIR=$(mktemp -d)
trap 'case "$TEMP_DIR" in /tmp/tmp.*) sudo rm -rf "$TEMP_DIR" 2>/dev/null;; esac; rm -f "$BACKUP_FILE" 2>/dev/null' EXIT

# Collect Proxmox configs
log_msg "Collecting /etc/pve/ configurations..."
mkdir -p "$TEMP_DIR/pve"

# Copy /etc/pve via privileged helper (avoids glob expansion in sudoers)
if sudo /usr/local/bin/pve_backup_helper "$TEMP_DIR/pve/"; then
  log_msg "  - /etc/pve/ copied"
else
  log_msg "${RED}Error: Failed to copy /etc/pve/ - check permissions${NC}"
  exit 1
fi

# Also backup important host configs
mkdir -p "$TEMP_DIR/host"

# Network configuration
if [ -f /etc/network/interfaces ]; then
  cp /etc/network/interfaces "$TEMP_DIR/host/"
  log_msg "  - Network interfaces copied"
fi

# Storage configuration (outside pve)
if [ -f /etc/fstab ]; then
  cp /etc/fstab "$TEMP_DIR/host/"
  log_msg "  - fstab copied"
fi

# ZFS pool list (if ZFS is used)
if command -v zpool &>/dev/null; then
  zpool list -v > "$TEMP_DIR/host/zpool_list.txt" 2>/dev/null || true
  zpool status > "$TEMP_DIR/host/zpool_status.txt" 2>/dev/null || true
  log_msg "  - ZFS pool info captured"
fi

# Proxmox version
pveversion > "$TEMP_DIR/host/pve_version.txt" 2>/dev/null || true

# Crontabs
crontab -l > "$TEMP_DIR/host/crontab_user.txt" 2>/dev/null || true
sudo crontab -l > "$TEMP_DIR/host/crontab_root.txt" 2>/dev/null || true

# Create archive
log_msg "Creating backup archive..."
tar -czf "$BACKUP_FILE" -C "$TEMP_DIR" . 2>/dev/null

log_msg "${GREEN}Created backup archive: $BACKUP_FILE${NC}"
log_msg "Archive size: $(ls -lh "$BACKUP_FILE" | awk '{print $5}')"

# Find do_backup script
DO_BACKUP=""
for path in "$HOME/.scripts/do_backup" /usr/local/bin/do_backup; do
  if [ -f "$path" ]; then
    DO_BACKUP="$path"
    break
  fi
done

if [ -z "$DO_BACKUP" ]; then
  log_msg "${RED}Error: do_backup script not found${NC}"
  exit 1
fi

log_msg "Using do_backup: $DO_BACKUP"

# Run backup
if [ "$silent_mode" = "true" ]; then
  "$DO_BACKUP" --silent "$BACKUP_FILE" "$recipient"
else
  "$DO_BACKUP" --logging="$logging_token" --alert="$alert_token" "$BACKUP_FILE" "$recipient"
fi
backup_result=$?

if [ $backup_result -eq 0 ]; then
  log_msg "${GREEN}Proxmox configuration backup completed successfully${NC}"
else
  log_msg "${RED}Proxmox configuration backup failed with exit code: $backup_result${NC}"
fi

exit $backup_result
