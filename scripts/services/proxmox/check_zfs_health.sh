#!/bin/bash
# check_zfs_health.sh
# Monitor ZFS pool health
# Alerts on degraded pools, errors, or scrub issues

set -euo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

exit_code=$EXIT_OK
issues=()
warnings=()

# Check if ZFS is available
if ! command -v zpool >/dev/null 2>&1; then
    echo "ERROR: zpool command not found"
    exit $EXIT_CRITICAL
fi

# Check pool health
pool_health=$(zpool list -H -o health rpool 2>/dev/null)

if [ "$pool_health" != "ONLINE" ]; then
    issues+=("CRITICAL: ZFS rpool health is $pool_health")
    exit_code=$EXIT_CRITICAL
fi

# Check for errors in the errors line at the end of status
errors_line=$(zpool status rpool | grep "^errors:" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}')

if [ -n "$errors_line" ] && ! echo "$errors_line" | grep -q "No known data errors"; then
    issues+=("CRITICAL: ZFS rpool has errors: $errors_line")
    exit_code=$EXIT_CRITICAL
fi

# Check scrub status
last_scrub=$(zpool status rpool | grep "scan:" | head -1)

if echo "$last_scrub" | grep -q "scrub in progress"; then
    warnings+=("INFO: ZFS scrub in progress")
elif echo "$last_scrub" | grep -q "with [1-9]"; then
    # Scrub found errors
    issues+=("CRITICAL: Last ZFS scrub found errors - $last_scrub")
    exit_code=$EXIT_CRITICAL
elif echo "$last_scrub" | grep -q "never"; then
    warnings+=("WARNING: ZFS pool has never been scrubbed")
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
fi

# Check pool capacity (already covered in health check, but show details)
capacity=$(zpool list -H -o capacity rpool | tr -d '%')
if [ "$capacity" -ge 90 ]; then
    issues+=("CRITICAL: ZFS rpool at ${capacity}% capacity")
    exit_code=$EXIT_CRITICAL
elif [ "$capacity" -ge 80 ]; then
    warnings+=("WARNING: ZFS rpool at ${capacity}% capacity")
    if [ $exit_code -eq $EXIT_OK ]; then
        exit_code=$EXIT_WARNING
    fi
fi

# Output results
if [ ${#issues[@]} -gt 0 ]; then
    echo "ZFS CRITICAL ISSUES:"
    printf '%s\n' "${issues[@]}"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo "ZFS WARNINGS:"
    printf '%s\n' "${warnings[@]}"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    echo "OK: ZFS rpool is healthy"
    zpool list rpool
    echo "Status: $pool_health, Capacity: ${capacity}%"
fi

exit $exit_code
