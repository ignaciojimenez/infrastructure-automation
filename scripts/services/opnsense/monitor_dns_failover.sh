#!/bin/sh
#
# DNS Failover Monitoring Script
# Monitors VPN gateway health and switches DNS forwarder accordingly
# Primary: Multiple VPN resolvers across different WireGuard tunnels for resilience
# Fallback: Cloudflare (1.1.1.1) when ALL VPN tunnels are down
#
# Architecture:
#   Layer 1: Unbound forwards to 4 Mullvad DNS servers (10.64.0.1, .3, .7, .11)
#            Each routes through different tunnel - automatic failover
#   Layer 2: This script - if ALL tunnels down, switch to Cloudflare

set -eu

# Configuration - Multiple VPN DNS servers for resilience
VPN_RESOLVERS="10.64.0.1 10.64.0.3 10.64.0.7 10.64.0.11"
FALLBACK_DNS="1.1.1.1"  # Cloudflare - no VPN route, uses default gateway
STATE_FILE="/tmp/dns_failover_state"
FAILURE_THRESHOLD=3   # Number of failed checks before switching (3 x 1min = 3min)
RECOVERY_THRESHOLD=3  # Number of successful checks before recovery
CONFIG_FILE="/conf/config.xml"

# Local alert log (fallback when Slack unreachable due to DNS issues)
ALERT_LOG="/var/log/dns_failover_alerts.log"
ALERT_FLAG="/tmp/dns_failover_alert_pending"

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

# Log alert locally (always works, even when DNS/Slack down)
log_local() {
  local level="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$ALERT_LOG" 2>/dev/null || true
}

# Create alert flag file (for external monitoring to detect)
set_alert_flag() {
  local status="$1"
  local message="$2"
  echo "$status|$(date +%s)|$message" > "$ALERT_FLAG" 2>/dev/null || true
}

clear_alert_flag() {
  rm -f "$ALERT_FLAG" 2>/dev/null || true
}

# Send Slack notification with local fallback
send_slack() {
  local webhook="$1"
  local message="$2"
  local emoji="${3:-:information_source:}"
  
  # Always log locally first (Slack might be unreachable if DNS is down)
  log_local "SLACK" "$message"
  
  # Try to send to Slack (may fail if DNS down, but that's OK)
  # Use IP-based fallback for hooks.slack.com if DNS failing
  if ! curl -s --max-time 10 -X POST "$webhook" \
    -H 'Content-Type: application/json' \
    -d "{
      \"text\": \"$emoji *DNS Failover Monitor*\\n$message\"
    }" > /dev/null 2>&1; then
    log_local "SLACK_FAILED" "Could not send Slack notification (DNS likely down)"
  fi
}

# Check VPN gateway health - test ALL VPN resolvers
# Returns 0 if ANY resolver works, 1 if ALL fail
check_vpn_health() {
  local working=0
  local failed=0
  
  for resolver in $VPN_RESOLVERS; do
    if drill @"$resolver" mullvad.net A > /dev/null 2>&1; then
      working=$((working + 1))
    else
      failed=$((failed + 1))
    fi
  done
  
  # Log status if some but not all are failing
  if [ "$working" -gt 0 ] && [ "$failed" -gt 0 ]; then
    echo "VPN DNS: $working working, $failed failed" >> /tmp/dns_failover.log 2>/dev/null || true
  fi
  
  # Return success if ANY resolver works
  if [ "$working" -gt 0 ]; then
    return 0
  fi
  
  # ALL resolvers failed
  return 1
}

# Verify fallback DNS is actually reachable (not routed through broken VPN)
check_fallback_reachable() {
  if drill @"$FALLBACK_DNS" cloudflare.com A > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Switch to fallback DNS
switch_to_fallback() {
  # Backup config (limit backups to avoid clutter)
  cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-failover"
  
  # Replace ALL VPN resolvers with fallback DNS (keep first entry only)
  for resolver in $VPN_RESOLVERS; do
    sed -i '' "s|<server>$resolver</server>|<server>$FALLBACK_DNS</server>|g" "$CONFIG_FILE"
  done
  
  # Reload Unbound
  /usr/local/sbin/configctl unbound restart > /dev/null 2>&1
  
  return 0
}

# Switch back to VPN resolvers
switch_to_vpn() {
  # Restore from backup which has all VPN resolvers
  if [ -f "${CONFIG_FILE}.backup-failover" ]; then
    cp "${CONFIG_FILE}.backup-failover" "$CONFIG_FILE"
  fi
  
  # Reload Unbound
  /usr/local/sbin/configctl unbound restart > /dev/null 2>&1
  
  return 0
}

# Check which DNS is currently active
get_active_dns() {
  # Check if any VPN resolver is configured
  for resolver in $VPN_RESOLVERS; do
    if grep -q "<server>$resolver</server>" "$CONFIG_FILE"; then
      echo "vpn"
      return
    fi
  done
  
  if grep -q "<server>$FALLBACK_DNS</server>" "$CONFIG_FILE"; then
    echo "fallback"
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
      if [ "$real_active_dns" = "fallback" ]; then
        switch_to_vpn
        clear_alert_flag
        log_local "RECOVERED" "VPN DNS restored - privacy mode active"
        send_slack "$ALERT_WEBHOOK" "✅ *DNS RECOVERED*\nVPN gateway is back online. Switched back to VPN resolver.\n🔒 Full privacy restored (DNS via WireGuard tunnel)." ":white_check_mark:"
        send_slack "$LOG_WEBHOOK" "DNS failover: VPN recovered, switched back to Mullvad DNS" ":white_check_mark:"
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
      # VPN has failed - switch to fallback DNS only if fallback is reachable
      if [ "$real_active_dns" = "vpn" ]; then
        if check_fallback_reachable; then
          switch_to_fallback
          set_alert_flag "FAILOVER" "Switched to Cloudflare - VPN DNS unreachable"
          log_local "FAILOVER" "ALL 4 VPN resolvers failed - switched to Cloudflare"
          send_slack "$ALERT_WEBHOOK" "⚠️  *DNS FAILOVER ACTIVE*\nAll 4 VPN resolvers unreachable. Switched to Cloudflare DNS.\n❗ Privacy degraded (DNS queries NOT going through VPN).\n\nWhat this means:\n• DNS still works but queries are visible to Cloudflare\n• Check VPN tunnel status: all tunnels may be down\n• Will auto-recover when any VPN tunnel comes back" ":warning:"
          send_slack "$LOG_WEBHOOK" "DNS failover activated: All VPN resolvers down, using Cloudflare" ":warning:"
        else
          set_alert_flag "CRITICAL" "Both VPN and Cloudflare DNS unreachable"
          log_local "CRITICAL" "ALL DNS unreachable - VPN and Cloudflare both failed"
          send_slack "$ALERT_WEBHOOK" "🚨 *DNS CRITICAL*\nVPN resolvers AND Cloudflare fallback both unreachable!\n\nWhat this means:\n• DNS resolution may be failing for all clients\n• Likely a major network/internet outage\n• Manual intervention required" ":rotating_light:"
          send_slack "$LOG_WEBHOOK" "DNS CRITICAL: Both VPN and fallback unreachable" ":rotating_light:"
        fi
      fi
      state="failed"
      active_dns="fallback"
      failure_count=0
    fi
    
    write_state "${state}|${failure_count}|0|${active_dns}"
  fi
}

main
