#!/bin/bash
# check_kernel_errors.sh
# Monitor kernel ring buffer for errors and warnings
# Early detection system for hardware/driver issues

set -euo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

exit_code=$EXIT_OK
issues=()
warnings=()

# State file to track seen errors
STATE_DIR="/var/log/monitoring-state"
STATE_FILE="$STATE_DIR/kernel_errors_seen.txt"

# Create state directory if it doesn't exist
mkdir -p "$STATE_DIR"

# Initialize seen errors file if doesn't exist
touch "$STATE_FILE"

# Check for critical kernel messages since last check
# Look for: panics, oom, segfaults, hardware errors, PCI errors
CRITICAL_PATTERNS=(
    "kernel panic"
    "Out of memory"
    "oom-kill"
    "segfault"
    "Machine Check Exception"
    "Hardware Error"
    "PCI.*error"
    "I/O error"
    "EXT4-fs error"
    "ZFS.*error"
)

WARNING_PATTERNS=(
    "WARNING"
    "VFIO"
    "temperature above threshold"
    "hung task"
)

# Function to check dmesg for patterns
check_dmesg() {
    local pattern=$1
    local severity=$2
    local matches
    
    # Get recent kernel messages (last 500 lines to keep it manageable)
    # Use sudo since dmesg requires privileges
    matches=$(sudo dmesg -T 2>/dev/null | tail -500 | grep -i "$pattern" || true)
    
    if [ -n "$matches" ]; then
        # Check each match to see if we've already reported it
        local new_matches=""
        while IFS= read -r line; do
            # Create a signature (hash) of this error to track if we've seen it
            signature=$(echo "$line" | md5sum | awk '{print $1}')
            
            # Check if we've seen this exact error before
            if ! grep -q "$signature" "$STATE_FILE" 2>/dev/null; then
                # New error - add to report and mark as seen
                new_matches="${new_matches}${line}\n"
                echo "$signature" >> "$STATE_FILE"
            fi
        done <<< "$matches"
        
        # Only report if there are new matches
        if [ -n "$new_matches" ]; then
            if [ "$severity" = "critical" ]; then
                issues+=("CRITICAL kernel message: $pattern")
                issues+=("$(echo -e "$new_matches" | head -5)")
                exit_code=$EXIT_CRITICAL
            else
                warnings+=("WARNING kernel message: $pattern")
                warnings+=("$(echo -e "$new_matches" | head -5)")
                if [ $exit_code -eq $EXIT_OK ]; then
                    exit_code=$EXIT_WARNING
                fi
            fi
        fi
    fi
}

# Check for critical patterns
for pattern in "${CRITICAL_PATTERNS[@]}"; do
    check_dmesg "$pattern" "critical"
done

# Check for warning patterns (only if no critical issues)
if [ $exit_code -ne $EXIT_CRITICAL ]; then
    for pattern in "${WARNING_PATTERNS[@]}"; do
        check_dmesg "$pattern" "warning"
    done
fi

# Clean up old signatures (keep last 1000 to prevent file from growing indefinitely)
if [ -f "$STATE_FILE" ]; then
    tail -1000 "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# Output results
if [ ${#issues[@]} -gt 0 ]; then
    echo "CRITICAL KERNEL ISSUES DETECTED:"
    printf '%s\n' "${issues[@]}"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo "KERNEL WARNINGS:"
    printf '%s\n' "${warnings[@]}"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    echo "OK: No critical kernel errors detected in recent logs"
fi

exit $exit_code
