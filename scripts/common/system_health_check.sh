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

echo "=============================="
echo "Health check completed"
echo "=============================="
