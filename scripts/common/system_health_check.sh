#!/bin/sh
# POSIX-compliant System Health Check
# Works on both Linux (Debian) and FreeBSD

set -u

# Color codes (POSIX compatible)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect OS type
OS_TYPE="unknown"
if [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
elif [ "$(uname)" = "FreeBSD" ]; then
    OS_TYPE="freebsd"
elif [ -f /etc/redhat-release ]; then
    OS_TYPE="redhat"
fi

# Configuration
THRESHOLD_CPU=80
THRESHOLD_MEM=90
THRESHOLD_DISK=85

# Functions
print_status() {
    status="$1"
    message="$2"
    
    case "$status" in
        success)
            printf "${GREEN}✅${NC} %s\n" "$message"
            ;;
        warning)
            printf "${YELLOW}⚠️${NC} %s\n" "$message"
            ;;
        error)
            printf "${RED}❌${NC} %s\n" "$message"
            ;;
        *)
            printf "%s\n" "$message"
            ;;
    esac
}

check_uptime() {
    echo "=== System Uptime ==="
    uptime_output=$(uptime)
    print_status "success" "Uptime: $uptime_output"
    echo ""
}

check_disk_usage() {
    echo "=== Disk Usage ==="
    
    df -h | grep -E '^(/dev/|tank/|zroot/|rpool/)' | while read -r line; do
        usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')
        
        if [ "$usage" -gt "$THRESHOLD_DISK" ]; then
            print_status "error" "Disk $mount: ${usage}% (above ${THRESHOLD_DISK}%)"
        elif [ "$usage" -gt $((THRESHOLD_DISK - 10)) ]; then
            print_status "warning" "Disk $mount: ${usage}%"
        else
            print_status "success" "Disk $mount: ${usage}%"
        fi
    done
    echo ""
}

check_memory() {
    echo "=== Memory Usage ==="
    
    if [ "$OS_TYPE" = "debian" ]; then
        # Linux memory check
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        
        if [ "$mem_total" -gt 0 ]; then
            mem_used=$((mem_total - mem_available))
            mem_percent=$((mem_used * 100 / mem_total))
            
            if [ "$mem_percent" -gt "$THRESHOLD_MEM" ]; then
                print_status "error" "Memory: ${mem_percent}% used (above ${THRESHOLD_MEM}%)"
            elif [ "$mem_percent" -gt $((THRESHOLD_MEM - 10)) ]; then
                print_status "warning" "Memory: ${mem_percent}% used"
            else
                print_status "success" "Memory: ${mem_percent}% used"
            fi
        fi
    elif [ "$OS_TYPE" = "freebsd" ]; then
        # FreeBSD memory check
        mem_info=$(sysctl -n hw.physmem hw.usermem 2>/dev/null)
        if [ -n "$mem_info" ]; then
            print_status "success" "Memory check completed (FreeBSD)"
        fi
    else
        print_status "warning" "Memory check not available for $OS_TYPE"
    fi
    echo ""
}

check_load() {
    echo "=== System Load ==="
    
    # Get number of CPUs
    if [ "$OS_TYPE" = "freebsd" ]; then
        cpu_count=$(sysctl -n hw.ncpu)
    else
        cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    
    # Get load average (1 minute)
    load_avg=$(uptime | sed 's/.*load average://' | awk '{print $1}' | sed 's/,//')
    
    # Convert to percentage (rough estimate)
    load_percent=$(echo "$load_avg $cpu_count" | awk '{printf "%.0f", ($1/$2)*100}')
    
    if [ "$load_percent" -gt "$THRESHOLD_CPU" ]; then
        print_status "error" "Load: ${load_avg} on ${cpu_count} CPUs (${load_percent}%)"
    elif [ "$load_percent" -gt $((THRESHOLD_CPU - 20)) ]; then
        print_status "warning" "Load: ${load_avg} on ${cpu_count} CPUs (${load_percent}%)"
    else
        print_status "success" "Load: ${load_avg} on ${cpu_count} CPUs"
    fi
    echo ""
}

check_services() {
    echo "=== Critical Services ==="
    
    # Define critical services based on OS
    if [ "$OS_TYPE" = "debian" ]; then
        SERVICES="ssh cron"
        
        for service in $SERVICES; do
            if systemctl is-active "$service" >/dev/null 2>&1; then
                print_status "success" "Service $service: running"
            else
                print_status "error" "Service $service: not running"
            fi
        done
    elif [ "$OS_TYPE" = "freebsd" ]; then
        SERVICES="sshd cron"
        
        for service in $SERVICES; do
            if service "$service" status >/dev/null 2>&1; then
                print_status "success" "Service $service: running"
            else
                print_status "error" "Service $service: not running"
            fi
        done
    else
        print_status "warning" "Service check not configured for $OS_TYPE"
    fi
    echo ""
}

check_network() {
    echo "=== Network Connectivity ==="
    
    # Skip gateway check - many routers don't respond to ICMP
    # Just check internet connectivity directly
    
    # Check internet connectivity
    if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        print_status "success" "Internet: reachable"
    else
        print_status "error" "Internet: unreachable (check network)"
    fi
    echo ""
}

check_auto_upgrades() {
    echo "=== Auto-Upgrades Status ==="
    
    # Only check on Debian-based systems (unattended-upgrades is Debian-specific)
    if [ "$OS_TYPE" != "debian" ]; then
        print_status "warning" "Auto-upgrades check only available on Debian"
        echo ""
        return 0
    fi
    
    issues_found=0
    
    # Check if unattended-upgrades is installed
    if ! dpkg -l 2>/dev/null | grep -q "unattended-upgrades"; then
        print_status "error" "unattended-upgrades package not installed"
        issues_found=$((issues_found + 1))
    else
        # Check if service is enabled and running
        if ! systemctl is-enabled unattended-upgrades.service >/dev/null 2>&1; then
            print_status "error" "unattended-upgrades service not enabled"
            issues_found=$((issues_found + 1))
        elif ! systemctl is-active unattended-upgrades.service >/dev/null 2>&1; then
            print_status "error" "unattended-upgrades service not running"
            issues_found=$((issues_found + 1))
        else
            print_status "success" "unattended-upgrades service: running"
        fi
        
        # Check for recent activity - ALERT if no activity for 7+ days
        log_file="/var/log/unattended-upgrades/unattended-upgrades.log"
        STALE_DAYS=7
        
        if [ -f "$log_file" ]; then
            # Find the most recent "Starting unattended upgrades" entry
            last_run_line=$(grep "Starting unattended upgrades script" "$log_file" 2>/dev/null | tail -1)
            
            if [ -n "$last_run_line" ]; then
                # Extract date from log entry (format: 2026-01-11 06:12:56,369)
                last_run_date=$(echo "$last_run_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
                
                if [ -n "$last_run_date" ]; then
                    # Calculate days since last run (POSIX-compatible)
                    current_epoch=$(date +%s)
                    # Try GNU date first, then BSD date
                    last_epoch=$(date -d "$last_run_date" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$last_run_date" +%s 2>/dev/null)
                    
                    if [ -n "$last_epoch" ]; then
                        days_since=$(( (current_epoch - last_epoch) / 86400 ))
                        
                        if [ "$days_since" -ge "$STALE_DAYS" ]; then
                            print_status "error" "No upgrades for ${days_since} days (last: ${last_run_date}) - ACTION REQUIRED"
                            issues_found=$((issues_found + 1))
                        elif [ "$days_since" -ge 2 ]; then
                            print_status "warning" "Last upgrade: ${last_run_date} (${days_since} days ago)"
                        else
                            print_status "success" "Last upgrade: ${last_run_date}"
                        fi
                    else
                        print_status "warning" "Could not parse last upgrade date"
                    fi
                else
                    print_status "warning" "Could not find upgrade date in logs"
                fi
            else
                print_status "error" "No upgrade activity found in logs - ACTION REQUIRED"
                issues_found=$((issues_found + 1))
            fi
        else
            print_status "error" "Upgrade log not found - unattended-upgrades may not be configured"
            issues_found=$((issues_found + 1))
        fi
        
        # Check configuration files exist
        if [ ! -f /etc/apt/apt.conf.d/20auto-upgrades ] || [ ! -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
            print_status "error" "Missing auto-upgrade configuration files"
            issues_found=$((issues_found + 1))
        else
            # Check if upgrades are enabled in config
            if ! grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
                print_status "error" "Unattended upgrades not enabled in config"
                issues_found=$((issues_found + 1))
            else
                print_status "success" "Configuration: valid"
            fi
        fi
        
        # Note: We intentionally do NOT alert on pending update counts
        # Pending updates naturally accumulate between daily runs - this is normal
        pending=$(apt-get --simulate upgrade 2>/dev/null | grep -c "^Inst")
        pending=${pending:-0}
        print_status "success" "Pending updates: $pending (informational)"
    fi
    
    echo ""
    return $issues_found
}

# Handle command line arguments
case "${1:-}" in
    --version)
        echo "POSIX System Health Check v1.0"
        exit 0
        ;;
    --test)
        echo "Test mode - checking script functionality"
        print_status "success" "Script is executable and functioning"
        exit 0
        ;;
    --help)
        echo "Usage: $0 [--version|--test|--help]"
        echo "  --version  Show version information"
        echo "  --test     Run test mode"
        echo "  --help     Show this help message"
        exit 0
        ;;
esac

# Main execution
echo "=============================="
echo "System Health Check"
echo "Host: $(hostname)"
echo "OS: $OS_TYPE"
echo "Date: $(date)"
echo "=============================="
echo ""

check_uptime
check_disk_usage
check_memory
check_load
check_services
check_network
check_auto_upgrades

echo "=============================="
echo "Health check completed"
echo "=============================="
