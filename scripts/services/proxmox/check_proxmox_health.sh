#!/bin/bash
# check_proxmox_health.sh
# Comprehensive health check for Proxmox hypervisor
# Monitors: memory, CPU, disk, swap, temperature
# Early warning system to prevent crashes

set -euo pipefail

# Exit codes
EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

# Thresholds
MEMORY_WARNING=80
MEMORY_CRITICAL=90
SWAP_WARNING=50
SWAP_CRITICAL=80
CPU_WARNING=80
CPU_CRITICAL=95
DISK_WARNING=80
DISK_CRITICAL=90
TEMP_WARNING=70
TEMP_CRITICAL=85

# Color output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

exit_code=$EXIT_OK
issues=()
warnings=()

# Function to add issue
add_issue() {
    issues+=("$1")
    exit_code=$EXIT_CRITICAL
}

# Function to add warning
add_warning() {
    warnings+=("$1")
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
}

# Check memory usage
check_memory() {
    local mem_total mem_used mem_percent
    
    mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    mem_used=$(free -m | awk '/^Mem:/ {print $3}')
    mem_percent=$((mem_used * 100 / mem_total))
    
    if [ "$mem_percent" -ge "$MEMORY_CRITICAL" ]; then
        add_issue "CRITICAL: Memory usage at ${mem_percent}% (${mem_used}MB/${mem_total}MB)"
    elif [ "$mem_percent" -ge "$MEMORY_WARNING" ]; then
        add_warning "WARNING: Memory usage at ${mem_percent}% (${mem_used}MB/${mem_total}MB)"
    fi
}

# Check swap usage
check_swap() {
    local swap_total swap_used swap_percent
    
    swap_total=$(free -m | awk '/^Swap:/ {print $2}')
    
    if [ "$swap_total" -eq 0 ]; then
        add_issue "CRITICAL: No swap configured!"
        return
    fi
    
    swap_used=$(free -m | awk '/^Swap:/ {print $3}')
    
    if [ "$swap_used" -gt 0 ]; then
        swap_percent=$((swap_used * 100 / swap_total))
        
        if [ "$swap_percent" -ge "$SWAP_CRITICAL" ]; then
            add_issue "CRITICAL: Swap usage at ${swap_percent}% (${swap_used}MB/${swap_total}MB) - memory pressure!"
        elif [ "$swap_percent" -ge "$SWAP_WARNING" ]; then
            add_warning "WARNING: Swap in use at ${swap_percent}% (${swap_used}MB/${swap_total}MB)"
        fi
    fi
}

# Check CPU load
check_cpu() {
    local cpu_count load_1min load_percent
    
    cpu_count=$(nproc)
    load_1min=$(awk '{print $1}' /proc/loadavg)
    load_percent=$(awk -v load="$load_1min" -v cpus="$cpu_count" 'BEGIN {printf "%.0f", (load / cpus) * 100}')
    
    if [ "$load_percent" -ge "$CPU_CRITICAL" ]; then
        add_issue "CRITICAL: CPU load at ${load_percent}% (${load_1min}/${cpu_count} cores)"
    elif [ "$load_percent" -ge "$CPU_WARNING" ]; then
        add_warning "WARNING: CPU load at ${load_percent}% (${load_1min}/${cpu_count} cores)"
    fi
}

# Check disk space (ZFS rpool)
check_disk() {
    local disk_usage
    
    if command -v zpool >/dev/null 2>&1; then
        disk_usage=$(zpool list -H -o capacity rpool 2>/dev/null | tr -d '%')
        
        if [ -n "$disk_usage" ]; then
            if [ "$disk_usage" -ge "$DISK_CRITICAL" ]; then
                add_issue "CRITICAL: ZFS rpool at ${disk_usage}% capacity"
            elif [ "$disk_usage" -ge "$DISK_WARNING" ]; then
                add_warning "WARNING: ZFS rpool at ${disk_usage}% capacity"
            fi
        fi
    fi
    
    # Also check root filesystem
    local root_usage
    root_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    
    if [ "$root_usage" -ge "$DISK_CRITICAL" ]; then
        add_issue "CRITICAL: Root filesystem at ${root_usage}%"
    elif [ "$root_usage" -ge "$DISK_WARNING" ]; then
        add_warning "WARNING: Root filesystem at ${root_usage}%"
    fi
}

# Check temperature (if sensors available)
check_temperature() {
    if ! command -v sensors >/dev/null 2>&1; then
        return
    fi
    
    # Get CPU package temperature
    local temp
    temp=$(sensors 2>/dev/null | grep -i 'package\|core 0' | head -1 | awk '{print $3}' | tr -d '+°C' | cut -d. -f1)
    
    # Validate temp is a number
    if [ -n "$temp" ] && [ "$temp" -eq "$temp" ] 2>/dev/null && [ "$temp" -gt 0 ]; then
        if [ "$temp" -ge "$TEMP_CRITICAL" ]; then
            add_issue "CRITICAL: CPU temperature at ${temp}°C"
        elif [ "$temp" -ge "$TEMP_WARNING" ]; then
            add_warning "WARNING: CPU temperature at ${temp}°C"
        fi
    fi
}

# Run all checks
check_memory
check_swap
check_cpu
check_disk
check_temperature

# Output results
if [ ${#issues[@]} -gt 0 ]; then
    echo -e "${RED}CRITICAL ISSUES DETECTED:${NC}"
    printf '%s\n' "${issues[@]}"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo -e "${YELLOW}WARNINGS:${NC}"
    printf '%s\n' "${warnings[@]}"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    echo -e "${GREEN}OK: All health checks passed${NC}"
    # Show current stats for reference
    mem_percent=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')
    load=$(awk '{print $1}' /proc/loadavg)
    echo "Memory: ${mem_percent}%, Load: ${load}, Uptime: $(uptime -p)"
fi

exit $exit_code
