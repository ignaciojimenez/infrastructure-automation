#!/bin/bash
# check_thermal.sh
# Dedicated CPU thermal + throttle alert for the Proxmox host.
#
# Instantaneous temperature is a weak signal on the N355: it reads a calm ~56C
# *between* throttle cycles, and the kernel suppresses the "temperature above
# threshold" log line that check_kernel_errors.sh greps for. The reliable signal is
# the hardware throttle COUNTER -- any increase means the CPU is hitting Tjmax (105C),
# the precursor to a silent THERMTRIP. We alert on the counter's delta since the
# previous run, with instantaneous temperature as a backstop.
#
# Designed to run under enhanced_monitoring_wrapper (state-tracked Slack alerts).

set -euo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

# Thresholds (throttle events since last run; instantaneous package temp in C).
# Under the RAPL PL1 cap with working airflow this box should throttle ~0, so any
# sustained increase is a genuine early warning that cooling margin is gone.
THROTTLE_WARN=20
THROTTLE_CRIT=500
TEMP_WARN=85
TEMP_CRIT=95

THROTTLE_NODE=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
# STATE_DIR is overridable (CHECK_THERMAL_STATE_DIR) only to allow testing without
# write access to the production state dir; the cron uses the default.
STATE_DIR="${CHECK_THERMAL_STATE_DIR:-/var/log/monitoring-state}"
STATE_FILE="$STATE_DIR/thermal_throttle.prev"
mkdir -p "$STATE_DIR"

exit_code=$EXIT_OK
issues=()
warnings=()

# --- Throttle counter delta since last check ---
throttle_now=""
[ -r "$THROTTLE_NODE" ] && throttle_now=$(cat "$THROTTLE_NODE")

if [ -n "$throttle_now" ]; then
    delta=0
    if [ -f "$STATE_FILE" ]; then
        prev=$(cat "$STATE_FILE" 2>/dev/null || echo "")
        if [[ "$prev" =~ ^[0-9]+$ ]]; then
            delta=$(( throttle_now - prev ))
            # Counter resets to 0 on reboot -> negative delta; treat as fresh baseline.
            [ "$delta" -lt 0 ] && delta=0
        fi
    fi
    echo "$throttle_now" > "$STATE_FILE"

    if [ "$delta" -ge "$THROTTLE_CRIT" ]; then
        issues+=("CRITICAL: CPU throttled ${delta} times since last check — approaching thermal shutdown (check fan/airflow)")
        exit_code=$EXIT_CRITICAL
    elif [ "$delta" -ge "$THROTTLE_WARN" ]; then
        warnings+=("WARNING: CPU throttling detected (${delta} events since last check) — cooling margin reduced")
        [ $exit_code -eq $EXIT_OK ] && exit_code=$EXIT_WARNING
    fi
fi

# --- Instantaneous temperature backstop ---
temp=""
if command -v sensors >/dev/null 2>&1; then
    temp=$(sensors 2>/dev/null | awk '/^Package id 0:/ {v=$4; gsub(/[^0-9.]/,"",v); print int(v); exit}')
    if [[ "${temp:-}" =~ ^[0-9]+$ ]]; then
        if [ "$temp" -ge "$TEMP_CRIT" ]; then
            issues+=("CRITICAL: CPU package temperature ${temp}°C")
            exit_code=$EXIT_CRITICAL
        elif [ "$temp" -ge "$TEMP_WARN" ]; then
            warnings+=("WARNING: CPU package temperature ${temp}°C")
            [ $exit_code -eq $EXIT_OK ] && exit_code=$EXIT_WARNING
        fi
    fi
fi

# --- Output ---
if [ ${#issues[@]} -gt 0 ]; then
    printf '%s\n' "${issues[@]}"
fi
if [ ${#warnings[@]} -gt 0 ]; then
    printf '%s\n' "${warnings[@]}"
fi
if [ $exit_code -eq $EXIT_OK ]; then
    echo "OK: thermal nominal (package ${temp:-NA}°C, throttle count ${throttle_now:-NA})"
fi

exit $exit_code
