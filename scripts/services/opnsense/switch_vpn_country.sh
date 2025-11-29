#!/bin/sh
# VPN Country Switcher for OPNsense
# Usage: switch-vpn-country.sh [nl|es|us|uk|status] [slack_webhook_id]
#
# Examples:
#   switch-vpn-country.sh nl                    # Switch to Netherlands
#   switch-vpn-country.sh status                # Show current country
#   switch-vpn-country.sh es WEBHOOK/ID/HERE    # Switch to Spain with Slack notification

set -eu

# Configuration - Firewall rule UUIDs for each country
NL_RULE="1a80d8ce-49cf-4a48-8b1e-6239745d6bc8"
ES_RULE="352f80d2-b307-4f33-8d34-c30b8c0c301b"
US_RULE="342fd91c-d5d8-40b1-9994-8f1ed72a8a55"
UK_RULE="8029390a-d41e-4e1d-8f76-92e4d6ff1ace"

# Country names for display
NL_NAME="Netherlands"
ES_NAME="Spain"
US_NAME="United States"
UK_NAME="United Kingdom"

CONFIGCTL=/usr/local/sbin/configctl

usage() {
  printf 'Usage: %s [nl|es|us|uk|status] [slack_webhook_id]\n' "$0" >&2
  printf '\nCommands:\n'
  printf '  nl|es|us|uk  - Switch to specified country\n'
  printf '  status       - Show current VPN country\n'
  exit 1
}

# Send Slack notification
send_slack() {
  local webhook_id="$1"
  local message="$2"
  local emoji="${3:-:globe_with_meridians:}"
  
  if [ -n "$webhook_id" ]; then
    curl -s -X POST "https://hooks.slack.com/services/$webhook_id" \
      -H 'Content-Type: application/json' \
      -d "{\"text\": \"$emoji *VPN Country Switch*\\n$message\"}" \
      > /dev/null 2>&1 || true
  fi
}

# Get WireGuard interface status (which tunnels are up)
get_wg_status() {
  # Get WireGuard endpoint info - shows active tunnels
  local wg_info
  wg_info=$(/usr/local/bin/wg show all endpoints 2>/dev/null || echo "")
  echo "$wg_info"
}

# Get current status - uses active rule since OPNsense traffic doesn't go through VPN
get_current_status() {
  local active_rule
  local wan_ip
  
  active_rule=$(get_active_rule)
  wan_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
  
  # Map active rule to country info
  case "$active_rule" in
    nl) echo "$wan_ip|Netherlands|NL|Amsterdam|nl-rule-active|1" ;;
    es) echo "$wan_ip|Spain|ES|Madrid|es-rule-active|1" ;;
    us) echo "$wan_ip|United States|US|New York|us-rule-active|1" ;;
    uk) echo "$wan_ip|United Kingdom|GB|London|gb-rule-active|1" ;;
    *)  echo "$wan_ip|Unknown|??|Unknown|no-rule-active|0" ;;
  esac
}

# Check which rule is currently enabled
get_active_rule() {
  local enabled_country=""
  
  # Check each rule's status in config.xml
  for country in nl es us uk; do
    case "$country" in
      nl) uuid=$NL_RULE ;;
      es) uuid=$ES_RULE ;;
      us) uuid=$US_RULE ;;
      uk) uuid=$UK_RULE ;;
    esac
    
    # Check if rule is enabled (not disabled)
    if ! grep -A20 "uuid=\"$uuid\"" /conf/config.xml | grep -q "<disabled>1</disabled>"; then
      enabled_country="$country"
      break
    fi
  done
  
  echo "$enabled_country"
}

# Verify switch was successful by checking active rule
verify_switch() {
  local expected_country="$1"
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    sleep 1
    active_rule=$(get_active_rule)
    
    if [ "$active_rule" = "$expected_country" ]; then
      return 0
    fi
    
    attempt=$((attempt + 1))
  done
  
  return 1
}

# Main
if [ "${1:-}" = "" ]; then
  usage
fi

COMMAND=$1
SLACK_WEBHOOK="${2:-}"

# Handle status command
if [ "$COMMAND" = "status" ]; then
  active_rule=$(get_active_rule)
  
  # Map rule to country name
  case "$active_rule" in
    nl) active_name="Netherlands" ;;
    es) active_name="Spain" ;;
    us) active_name="United States" ;;
    uk) active_name="United Kingdom" ;;
    *)  active_name="Unknown" ;;
  esac
  
  echo "VPN Country Status:"
  echo "  Active: ${active_rule:-none} ($active_name)"
  
  # Show WireGuard tunnel status
  wg_status=$(/usr/local/bin/wg show all latest-handshakes 2>/dev/null | head -5)
  if [ -n "$wg_status" ]; then
    echo "  WireGuard: Active"
  else
    echo "  WireGuard: Unknown"
  fi
  exit 0
fi

# Validate country
case "$COMMAND" in
  nl|es|us|uk) COUNTRY=$COMMAND ;;
  *)
    usage
    ;;
esac

# Check prerequisites
if ! command -v "$CONFIGCTL" >/dev/null 2>&1; then
  echo "Error: configctl not found. Run on OPNsense as root." >&2
  exit 1
fi

if [ "$(id -u)" != "0" ]; then
  echo "Error: must be run as root." >&2
  exit 1
fi

# Get country name and UUID
case "$COUNTRY" in
  nl) TARGET_UUID=$NL_RULE; TARGET_NAME=$NL_NAME ;;
  es) TARGET_UUID=$ES_RULE; TARGET_NAME=$ES_NAME ;;
  us) TARGET_UUID=$US_RULE; TARGET_NAME=$US_NAME ;;
  uk) TARGET_UUID=$UK_RULE; TARGET_NAME=$UK_NAME ;;
esac

# Get current status before switch
old_rule=$(get_active_rule)
case "$old_rule" in
  nl) old_name="Netherlands" ;;
  es) old_name="Spain" ;;
  us) old_name="United States" ;;
  uk) old_name="United Kingdom" ;;
  *)  old_name="Unknown" ;;
esac

echo "Switching VPN from $old_name to $TARGET_NAME..."

# Backup config
cp /conf/config.xml /conf/config.xml.vpn-switch-backup

# Disable all VPN country rules (add <disabled>1</disabled> if not present)
for RULE in $NL_RULE $ES_RULE $US_RULE $UK_RULE; do
  # Check if rule has disabled tag
  if grep -A30 "uuid=\"$RULE\"" /conf/config.xml | grep -q "<disabled>"; then
    # Update existing disabled tag to 1
    sed -i '' "/<rule uuid=\"$RULE\">/,/<\/rule>/ s|<disabled>[01]</disabled>|<disabled>1</disabled>|" /conf/config.xml
  else
    # Add disabled tag after the uuid line
    sed -i '' "/<rule uuid=\"$RULE\">/a\\
      <disabled>1</disabled>
" /conf/config.xml
  fi
done

# Enable target rule (set disabled to 0 or remove it)
sed -i '' "/<rule uuid=\"$TARGET_UUID\">/,/<\/rule>/ s|<disabled>1</disabled>|<disabled>0</disabled>|" /conf/config.xml

# Apply changes
"$CONFIGCTL" filter reload
/usr/local/opnsense/scripts/filter/kill_states.py 2>/dev/null || "$CONFIGCTL" filter kill_states 2>/dev/null || true

echo "Verifying switch..."

# Verify the switch worked
if verify_switch "$COUNTRY"; then
  echo "✅ Successfully switched to $TARGET_NAME"
  send_slack "$SLACK_WEBHOOK" "✅ VPN switched from *$old_name* → *$TARGET_NAME*" ":white_check_mark:"
  exit 0
else
  echo "❌ Switch failed - rule not enabled correctly"
  send_slack "$SLACK_WEBHOOK" "❌ VPN switch to *$TARGET_NAME* failed" ":x:"
  exit 1
fi