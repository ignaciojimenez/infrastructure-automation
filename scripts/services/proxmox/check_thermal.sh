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
# CRIT applies at all times and is unchanged (docs/TODO.md item 35): both have
# 50x+ margin over anything normal, confirmed against the 2026-08-29 CRITICAL
# night (4,017 throttle events) and the 2026-08-07 runaway (94-96C, 9h40m).
THROTTLE_CRIT=500
TEMP_CRIT=95

# WARN is suppressed entirely during the nightly vzdump window (02:55-03:20) --
# that heat is known and accepted, and a uniform WARN below this fired at
# random on a healthy backup (peaks of 66-88C, 0-143 throttle events measured
# over 10 real nights). Outside the window it is tighter than the old uniform
# 20/85, but set from real benign daytime noise, not guessed: a daily
# apt-daily-upgrade.service burst hits 45 throttle events, and this host's own
# monitoring cron heartbeats spike to 80-81C -- both routine, neither a fault.
THROTTLE_WARN=60
TEMP_WARN=85
WINDOW_START="02:55"
WINDOW_END="03:20"

# Override for forced testing only -- production always reads the real clock.
NOW_HM="${CHECK_THERMAL_NOW:-$(date +%H:%M)}"
in_backup_window() {
    [[ ( "$1" > "$WINDOW_START" || "$1" == "$WINDOW_START" ) && ( "$1" < "$WINDOW_END" || "$1" == "$WINDOW_END" ) ]]
}

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
    elif ! in_backup_window "$NOW_HM" && [ "$delta" -ge "$THROTTLE_WARN" ]; then
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
        elif ! in_backup_window "$NOW_HM" && [ "$temp" -ge "$TEMP_WARN" ]; then
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
