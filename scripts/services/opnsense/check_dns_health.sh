#!/bin/sh
# check_dns_health.sh
# Independent DNS resolution health check
#
# Alert Levels:
#   OK:       DNS resolving via VPN (privacy preserved)
#   WARNING:  DNS resolving via Cloudflare fallback (privacy degraded)
#   CRITICAL: DNS resolution completely failing
#
# This check is independent of the failover script - it verifies
# DNS is actually working from an end-user perspective.

# Test domains - use reliable, always-available domains
TEST_DOMAINS="google.com cloudflare.com"

# VPN DNS servers (same as failover script)
VPN_RESOLVERS="10.64.0.1 10.64.0.3 10.64.0.7 10.64.0.11"
FALLBACK_DNS="1.1.1.1"

# Local alert log (for when Slack is unreachable)
ALERT_LOG="/var/log/dns_health_alerts.log"

# Check if we can resolve via local Unbound (what clients use)
check_local_dns() {
    for domain in $TEST_DOMAINS; do
        if drill @127.0.0.1 "$domain" A > /dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# Check which resolver is currently active
check_active_resolver() {
    vpn_working=0
    fallback_working=0
    
    # Test VPN resolvers
    for resolver in $VPN_RESOLVERS; do
        if drill @"$resolver" mullvad.net A > /dev/null 2>&1; then
            vpn_working=$((vpn_working + 1))
        fi
    done
    
    # Test fallback
    if drill @"$FALLBACK_DNS" cloudflare.com A > /dev/null 2>&1; then
        fallback_working=1
    fi
    
    if [ "$vpn_working" -gt 0 ]; then
        echo "vpn:$vpn_working"
    elif [ "$fallback_working" -eq 1 ]; then
        echo "fallback"
    else
        echo "none"
    fi
}

# Log alert locally (fallback when Slack unreachable)
log_local_alert() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$ALERT_LOG"
}

# Main check
main() {
    # First, verify local DNS works at all
    if ! check_local_dns; then
        log_local_alert "CRITICAL" "DNS resolution completely failing"
        echo "CRITICAL: DNS resolution failing"
        echo "  Test: drill @127.0.0.1 google.com - FAILED"
        echo "  Impact: Clients cannot resolve any domains"
        echo "  Action: Check Unbound service and network connectivity"
        exit 2
    fi
    
    # DNS works - check which path it's using
    resolver_status=$(check_active_resolver)
    resolver_type=$(echo "$resolver_status" | cut -d: -f1)
    
    case "$resolver_type" in
        vpn)
            vpn_count=$(echo "$resolver_status" | cut -d: -f2)
            if [ "$vpn_count" -ge 3 ]; then
                echo "OK: DNS resolving via VPN ($vpn_count/4 resolvers active)"
                exit 0
            else
                echo "OK: DNS resolving via VPN ($vpn_count/4 resolvers - degraded)"
                exit 0
            fi
            ;;
        fallback)
            log_local_alert "WARNING" "DNS using Cloudflare fallback - VPN resolvers down"
            echo "WARNING: DNS resolving via Cloudflare fallback"
            echo "  Status: All VPN resolvers unreachable"
            echo "  Impact: DNS queries NOT private (not via VPN)"
            echo "  Action: Check VPN tunnel status"
            exit 1
            ;;
        none)
            # This shouldn't happen if local DNS works, but handle it
            log_local_alert "WARNING" "DNS working but resolver path unclear"
            echo "WARNING: DNS working but resolver status unclear"
            echo "  Action: Manual investigation recommended"
            exit 1
            ;;
    esac
}

main
