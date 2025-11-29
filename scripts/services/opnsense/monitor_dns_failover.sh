#!/bin/sh
#
# DNS Failover Monitoring Script
# Monitors VPN gateway health and switches DNS forwarder accordingly
# Primary: VPN resolver (10.64.0.1) via WireGuard tunnel
# Fallback: Mullvad public DNS (194.242.2.3) when VPN is down

set -eu

# Configuration
VPN_RESOLVER="10.64.0.1"
MULLVAD_PUBLIC="194.242.2.3"
STATE_FILE="/tmp/dns_failover_state"
FAILURE_THRESHOLD=3   # Number of failed checks before switching (3 x 1min = 3min)
RECOVERY_THRESHOLD=3  # Number of successful checks before recovery
CONFIG_FILE="/conf/config.xml"

# Slack webhooks (passed as arguments)
if [ $# -lt 2 ]; then
  echo "Usage: $0 <alert_webhook_id> <log_webhook_id>"
  echo "Example: $0 TTSQU20RH/B01HG8URFQX/xxx TTSQU20RH/B01HX26CGTC/xxx"
  exit 1
fi

ALERT_WEBHOOK="https://hooks.slack.com/services/$1"
LOG_WEBHOOK="https://hooks.slack.com/services/$2"

# Initialize state file if it doesn't exist
if [ ! -f "$STATE_FILE" ]; then
  echo "healthy|0|0|vpn" > "$STATE_FILE"
fi

# Read current state
read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "healthy|0|0|vpn"
  fi
}

# Save state
write_state() {
  echo "$1" > "$STATE_FILE"
}

# Send Slack notification
send_slack() {
  local webhook="$1"
  local message="$2"
  local emoji="${3:-:information_source:}"
  
  curl -s -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "{
      \"text\": \"$emoji *DNS Failover Monitor*\\n$message\"
    }" > /dev/null 2>&1 || true
}

# Check VPN gateway health
# Uses multiple methods: ping, DNS resolution test, and WireGuard interface status
check_vpn_health() {
  # Method 1: Quick ping to VPN resolver
  if ping -c 1 -W 2 "$VPN_RESOLVER" > /dev/null 2>&1; then
    # Method 2: Verify DNS actually works via VPN resolver
    if drill @"$VPN_RESOLVER" mullvad.net A > /dev/null 2>&1; then
      return 0
    fi
  fi
  
  # Method 3: Check if any WireGuard interface has active handshake (< 3 min old)
  if command -v wg > /dev/null 2>&1; then
    latest_handshake=$(wg show all latest-handshakes 2>/dev/null | awk '{print $2}' | sort -rn | head -1)
    if [ -n "$latest_handshake" ]; then
      current_time=$(date +%s)
      handshake_age=$((current_time - latest_handshake))
      # If handshake is less than 180 seconds old, VPN is likely healthy
      if [ "$handshake_age" -lt 180 ]; then
        # Give VPN a moment to stabilize, but consider it recovering
        return 0
      fi
    fi
  fi
  
  return 1
}

# Switch to Mullvad public DNS
switch_to_mullvad() {
  # Backup config (limit backups to avoid clutter)
  cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-failover"
  
  # Replace VPN resolver with Mullvad public DNS
  sed -i '' "s|<server>$VPN_RESOLVER</server>|<server>$MULLVAD_PUBLIC</server>|g" "$CONFIG_FILE"
  
  # Reload Unbound
  /usr/local/sbin/configctl unbound restart > /dev/null 2>&1
  
  return 0
}

# Switch back to VPN resolver
switch_to_vpn() {
  # Backup config
  cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-recovery"
  
  # Replace Mullvad public with VPN resolver
  sed -i '' "s|<server>$MULLVAD_PUBLIC</server>|<server>$VPN_RESOLVER</server>|g" "$CONFIG_FILE"
  
  # Reload Unbound
  /usr/local/sbin/configctl unbound restart > /dev/null 2>&1
  
  return 0
}

# Check which DNS is currently active
get_active_dns() {
  if grep -q "<server>$VPN_RESOLVER</server>" "$CONFIG_FILE"; then
    echo "vpn"
  elif grep -q "<server>$MULLVAD_PUBLIC</server>" "$CONFIG_FILE"; then
    echo "mullvad"
  else
    echo "unknown"
  fi
}

# Main logic
main() {
  local current_state
  local failure_count
  local recovery_count
  local active_dns
  
  current_state=$(read_state)
  IFS='|' read -r state failure_count recovery_count active_dns <<EOF
$current_state
EOF
  
  # Get actual active DNS from config
  local real_active_dns
  real_active_dns=$(get_active_dns)
  
  if check_vpn_health; then
    # VPN is healthy
    recovery_count=$((recovery_count + 1))
    failure_count=0
    
    if [ "$state" = "failed" ] && [ "$recovery_count" -ge "$RECOVERY_THRESHOLD" ]; then
      # VPN recovered - switch back if needed
      if [ "$real_active_dns" = "mullvad" ]; then
        switch_to_vpn
        send_slack "$ALERT_WEBHOOK" "✅ *DNS RECOVERED*\\nVPN gateway is back online. Switched back to VPN resolver.\\n🔒 Full privacy restored (DNS via WireGuard tunnel)." ":white_check_mark:"
        send_slack "$LOG_WEBHOOK" "DNS failover: VPN recovered, switched back from Mullvad public" ":white_check_mark:"
      fi
      state="healthy"
      active_dns="vpn"
      recovery_count=0
    fi
    
    write_state "${state}|0|${recovery_count}|${active_dns}"
    
  else
    # VPN is down
    failure_count=$((failure_count + 1))
    recovery_count=0
    
    if [ "$state" = "healthy" ] && [ "$failure_count" -ge "$FAILURE_THRESHOLD" ]; then
      # VPN has failed - switch to Mullvad public
      if [ "$real_active_dns" = "vpn" ]; then
        switch_to_mullvad
        send_slack "$ALERT_WEBHOOK" "⚠️  *DNS FAILOVER ACTIVE*\\nVPN gateway unreachable. Switched to Mullvad public DNS.\\n❗ Privacy slightly degraded (DNS encrypted but not via VPN tunnel)." ":warning:"
        send_slack "$LOG_WEBHOOK" "DNS failover activated: VPN unreachable, switched to Mullvad public DNS" ":warning:"
      fi
      state="failed"
      active_dns="mullvad"
      failure_count=0
    fi
    
    write_state "${state}|${failure_count}|0|${active_dns}"
  fi
}

main
