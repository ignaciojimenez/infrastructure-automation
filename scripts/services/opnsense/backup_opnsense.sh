#!/bin/sh
# 
# Backup OPNsense configuration to curlbin
# Designed for FreeBSD/OPNsense - uses POSIX sh

set -e
set -u

# Configuration
CONFIG_FILE="/conf/config.xml"
BACKUP_DIR="/tmp"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/opnsense_config_${TIMESTAMP}.tar.gz"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
      log_msg "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$recipient" ]; then
  log_msg "Error: Recipient public key is required"
  usage
  exit 1
fi

if [ "$silent_mode" != "true" ] && { [ -z "$logging_token" ] || [ -z "$alert_token" ]; }; then
  log_msg "Error: Webhook tokens required unless --silent is used"
  usage
  exit 1
fi

# Check config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  log_msg "Error: OPNsense config file not found: $CONFIG_FILE"
  exit 1
fi

log_msg "Starting OPNsense configuration backup"

# Create backup archive with config.xml and version info
cd /conf
tar -czf "$BACKUP_FILE" config.xml 2>/dev/null

# Also include version info if available
if [ -f /usr/local/opnsense/version/opnsense ]; then
  VERSION=$(cat /usr/local/opnsense/version/opnsense)
  echo "$VERSION" > "${BACKUP_DIR}/opnsense_version.txt"
  cd "$BACKUP_DIR"
  tar -rf "${BACKUP_FILE%.gz}" opnsense_version.txt 2>/dev/null || true
  gzip -f "${BACKUP_FILE%.gz}" 2>/dev/null || true
  rm -f "${BACKUP_DIR}/opnsense_version.txt"
fi

log_msg "Created backup archive: $BACKUP_FILE"
log_msg "Archive size: $(ls -lh "$BACKUP_FILE" | awk '{print $5}')"

# Find do_backup script
DO_BACKUP=""
for path in /usr/local/bin/do_backup "$HOME/.scripts/do_backup"; do
  if [ -f "$path" ]; then
    DO_BACKUP="$path"
    break
  fi
done

if [ -z "$DO_BACKUP" ]; then
  log_msg "Error: do_backup script not found"
  rm -f "$BACKUP_FILE"
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

# Cleanup
rm -f "$BACKUP_FILE"

if [ $backup_result -eq 0 ]; then
  log_msg "OPNsense configuration backup completed successfully"
else
  log_msg "OPNsense configuration backup failed with exit code: $backup_result"
fi

exit $backup_result
