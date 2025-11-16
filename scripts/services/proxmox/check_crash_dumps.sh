#!/bin/bash
# check_crash_dumps.sh
# Check for kernel crash dumps and alert
# Post-crash forensics - alerts when system comes back up after crash

set -euo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

exit_code=$EXIT_OK
issues=()
warnings=()

# State file to track processed crash dumps
STATE_DIR="/var/log/monitoring-state"
STATE_FILE="$STATE_DIR/crash_dumps_processed.txt"
CRASH_DIR="/var/crash"

# Create state directory if it doesn't exist
mkdir -p "$STATE_DIR"

# Create empty state file if it doesn't exist
touch "$STATE_FILE"

# Check if crash directory exists
if [ ! -d "$CRASH_DIR" ]; then
    echo "OK: No crash directory (kdump not configured or no crashes)"
    exit $EXIT_OK
fi

# Find crash dumps
new_crashes=()

for crash_file in "$CRASH_DIR"/*; do
    # Skip if no files
    [ -e "$crash_file" ] || continue
    
    # Skip kdump_lock file (not a real crash dump)
    basename_file=$(basename "$crash_file")
    if [ "$basename_file" = "kdump_lock" ]; then
        continue
    fi
    
    # Skip if already processed
    if grep -q "^$basename_file\$" "$STATE_FILE" 2>/dev/null; then
        continue
    fi
    
    new_crashes+=("$crash_file")
    echo "$basename_file" >> "$STATE_FILE"
done

# Alert on new crashes
if [ ${#new_crashes[@]} -gt 0 ]; then
    issues+=("CRITICAL: Kernel crash dump(s) detected! System recovered from crash.")
    issues+=("New crash files:")
    for crash in "${new_crashes[@]}"; do
        file_info=$(ls -lh "$crash" 2>/dev/null || echo "")
        issues+=("  - $(basename "$crash") ($(echo "$file_info" | awk '{print $5" "$6" "$7" "$8}'))")
    done
    issues+=("")
    issues+=("ACTION REQUIRED: Investigate crash dumps in $CRASH_DIR")
    issues+=("Uptime: $(uptime)")
    exit_code=$EXIT_CRITICAL
fi

# Check for unexpected reboots (uptime less than 1 day + not in business hours)
uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
uptime_hours=$((uptime_seconds / 3600))

if [ "$uptime_hours" -lt 1 ]; then
    # System rebooted less than 1 hour ago
    current_hour=$(date +%H)
    # If not during maintenance window (2-5 AM), flag as potential issue
    if [ "$current_hour" -lt 2 ] || [ "$current_hour" -gt 5 ]; then
        warnings+=("WARNING: System rebooted recently (uptime: $uptime_hours hours)")
        warnings+=("Last reboot: $(who -b | awk '{print $3, $4}')")
        if [ $exit_code -eq $EXIT_OK ]; then
            exit_code=$EXIT_WARNING
        fi
    fi
fi

# Output results
if [ ${#issues[@]} -gt 0 ]; then
    echo "CRASH DUMPS DETECTED:"
    printf '%s\n' "${issues[@]}"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo "WARNINGS:"
    printf '%s\n' "${warnings[@]}"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    echo "OK: No new crash dumps detected"
    echo "Uptime: $(uptime -p)"
fi

exit $exit_code
