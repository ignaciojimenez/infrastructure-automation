#!/bin/sh
# check_system_health.sh
# Monitor OPNsense system health: memory, disk, CPU
# FreeBSD-specific implementation

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

exit_code=$EXIT_OK
issues=""
warnings=""

# Memory check
mem_usage=$(top -d 1 | grep "^Mem:" | awk '{print $2}' | tr -d 'M')
mem_total=$(sysctl -n hw.physmem | awk '{print int($1/1024/1024)}')
mem_percent=$(awk -v used="$mem_usage" -v total="$mem_total" 'BEGIN {printf "%.0f", (used/total)*100}')

if [ "$mem_percent" -ge 90 ]; then
    issues="${issues}CRITICAL: Memory at ${mem_percent}% (${mem_usage}MB/${mem_total}MB)\n"
    exit_code=$EXIT_CRITICAL
elif [ "$mem_percent" -ge 80 ]; then
    warnings="${warnings}WARNING: Memory at ${mem_percent}% (${mem_usage}MB/${mem_total}MB)\n"
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
fi

# Disk space check (root filesystem)
disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$disk_usage" -ge 90 ]; then
    issues="${issues}CRITICAL: Root filesystem at ${disk_usage}%\n"
    exit_code=$EXIT_CRITICAL
elif [ "$disk_usage" -ge 85 ]; then
    warnings="${warnings}WARNING: Root filesystem at ${disk_usage}%\n"
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
fi

# CPU load check
cpu_count=$(sysctl -n hw.ncpu)
load_1min=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
load_percent=$(awk -v load="$load_1min" -v cpus="$cpu_count" 'BEGIN {printf "%.0f", (load / cpus) * 100}')

if [ "$load_percent" -ge 90 ]; then
    issues="${issues}CRITICAL: CPU load at ${load_percent}% (${load_1min}/${cpu_count} cores)\n"
    exit_code=$EXIT_CRITICAL
elif [ "$load_percent" -ge 80 ]; then
    warnings="${warnings}WARNING: CPU load at ${load_percent}% (${load_1min}/${cpu_count} cores)\n"
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
fi

# Output results
if [ -n "$issues" ]; then
    printf "CRITICAL ISSUES:\n%b" "$issues"
fi

if [ -n "$warnings" ]; then
    printf "WARNINGS:\n%b" "$warnings"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    printf "OK: System health normal\n"
    printf "Memory: %s%%, Disk: %s%%, Load: %s\n" "$mem_percent" "$disk_usage" "$load_1min"
fi

exit $exit_code
