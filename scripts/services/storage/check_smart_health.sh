#!/bin/bash
# check_smart_health.sh
# SMART health alert for the flash storage that has no other early-warning signal.
#
# Scope is the two drives whose failure means data loss with no redundancy:
#   - proxmox: /dev/nvme0n1 — rpool, the single storage layer under every VM/CT
#   - cobra:   /dev/sda     — the Samsung T7 media drive (Plex library)
# Both are NVMe. The T7 is an NVMe SSD behind an ASMedia USB bridge, so it is
# reached with `-d sntasmedia`; smartctl's auto-detect and `-d sat` both fail to
# pull SMART through that bridge (verified 2026-07-25). Neither drive is ATA, so
# there is no attribute table here — the NVMe health log is the whole story.
#
# The SD/USB-flash boot media on both hosts is deliberately out of scope: SD
# cards expose no useful SMART, and the USB recovery flash on cwwk is already
# covered by backup-freshness monitoring. Monitoring them would only flap.
#
# Each device is passed as a `TYPE:DEVICE` token (e.g. nvme:/dev/nvme0n1,
# sntasmedia:/dev/sda). A bare DEVICE lets smartctl auto-detect.
#
# Designed to run under enhanced_monitoring_wrapper (state-tracked Slack alerts).
# Exit: 0 OK, 1 WARNING, 2 CRITICAL — the max severity across all devices.

set -uo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

# Thresholds, overridable from the environment for tuning without a redeploy.
# available_spare is compared against each drive's OWN reported threshold, not a
# constant — the two drives report different thresholds (1% vs 10%).
PCT_USED_WARN="${SMART_PCT_USED_WARN:-90}"      # endurance consumed (NVMe %used)
MEDIA_ERR_WARN="${SMART_MEDIA_ERR_WARN:-1}"     # any data-integrity error warns
MEDIA_ERR_CRIT="${SMART_MEDIA_ERR_CRIT:-100}"   # sustained errors are critical
TEMP_WARN="${SMART_TEMP_WARN:-65}"              # °C
TEMP_CRIT="${SMART_TEMP_CRIT:-75}"

# smartctl needs root to read the SMART log. The cron runs as the unprivileged
# infrastructure user, so it escalates through the narrow NOPASSWD sudoers rule
# the role installs (read-only `smartctl -j -x`). Overridable: SMARTCTL="smartctl"
# when already root, or anything when SMART_FIXTURE bypasses hardware entirely.
# The absolute path is spelled out so it matches the sudoers command exactly.
SMARTCTL="${SMARTCTL:-sudo -n /usr/sbin/smartctl}"

# Test hook: when SMART_FIXTURE is set, read the smartctl JSON from that file
# instead of touching hardware. Lets a synthetic "failing drive" be exercised
# end to end. Applies to every device argument in the run (tests use one).
FIXTURE="${SMART_FIXTURE:-}"

if [ "$#" -eq 0 ]; then
    echo "CRITICAL: check_smart_health called with no devices — nothing monitored" >&2
    exit $EXIT_CRITICAL
fi

exit_code=$EXIT_OK
issues=()
warnings=()
oklines=()

bump() {  # bump WARNING|CRITICAL — raise exit_code, never lower it
    if [ "$1" = "CRITICAL" ]; then
        exit_code=$EXIT_CRITICAL
    elif [ "$1" = "WARNING" ] && [ "$exit_code" -eq "$EXIT_OK" ]; then
        exit_code=$EXIT_WARNING
    fi
}

for spec in "$@"; do
    # Split optional TYPE: prefix (nvme, sntasmedia, sat, …) from the device path.
    if [[ "$spec" == *:* ]]; then
        dtype="${spec%%:*}"
        dev="${spec#*:}"
    else
        dtype=""
        dev="$spec"
    fi
    label="$dev"

    # Fetch the SMART JSON (real hardware, or a fixture under test).
    if [ -n "$FIXTURE" ]; then
        json=$(cat "$FIXTURE" 2>/dev/null)
    elif [ -n "$dtype" ]; then
        json=$($SMARTCTL -j -x -d "$dtype" "$dev" 2>/dev/null)
    else
        json=$($SMARTCTL -j -x "$dev" 2>/dev/null)
    fi

    if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
        warnings+=("WARNING: $label — could not read SMART data (smartctl returned nothing parseable)")
        bump WARNING
        continue
    fi

    # One jq pass pulls every field we judge on. Missing fields come back "null".
    read -r passed cwarn spare spare_thr pct media temp <<EOF
$(echo "$json" | jq -r '
    [ (.smart_status.passed),
      (.nvme_smart_health_information_log.critical_warning),
      (.nvme_smart_health_information_log.available_spare),
      (.nvme_smart_health_information_log.available_spare_threshold),
      (.nvme_smart_health_information_log.percentage_used),
      (.nvme_smart_health_information_log.media_errors),
      (.nvme_smart_health_information_log.temperature)
    ] | map(if . == null then "null" else tostring end) | join(" ")')
EOF

    if [ "$passed" = "null" ] && [ "$cwarn" = "null" ]; then
        warnings+=("WARNING: $label — no NVMe health log in SMART output (wrong -d type or bridge blocks passthrough?)")
        bump WARNING
        continue
    fi

    # Overall device self-assessment.
    if [ "$passed" = "false" ]; then
        issues+=("CRITICAL: $label — SMART overall-health self-assessment FAILED")
        bump CRITICAL
    fi

    # NVMe critical_warning is a bitmask; any set bit is a real condition
    # (spare low, reliability degraded, read-only, volatile-memory backup failed).
    if [[ "$cwarn" =~ ^[0-9]+$ ]] && [ "$cwarn" -ne 0 ]; then
        issues+=("CRITICAL: $label — NVMe critical_warning=0x$(printf '%02x' "$cwarn") (spare/reliability/read-only flag set)")
        bump CRITICAL
    fi

    # Available spare below the drive's own threshold = imminent.
    if [[ "$spare" =~ ^[0-9]+$ ]] && [[ "$spare_thr" =~ ^[0-9]+$ ]] && [ "$spare" -lt "$spare_thr" ]; then
        issues+=("CRITICAL: $label — available spare ${spare}% below drive threshold ${spare_thr}%")
        bump CRITICAL
    fi

    # Media / data-integrity errors.
    if [[ "$media" =~ ^[0-9]+$ ]] && [ "$media" -ge "$MEDIA_ERR_CRIT" ]; then
        issues+=("CRITICAL: $label — ${media} media/data-integrity errors")
        bump CRITICAL
    elif [[ "$media" =~ ^[0-9]+$ ]] && [ "$media" -ge "$MEDIA_ERR_WARN" ]; then
        warnings+=("WARNING: $label — ${media} media/data-integrity error(s)")
        bump WARNING
    fi

    # Endurance consumed. Past 100% the drive still works but is out of rated
    # life — a replace-soon signal, not an outage, so it stays a WARNING.
    if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge "$PCT_USED_WARN" ]; then
        warnings+=("WARNING: $label — ${pct}% of rated endurance used (replace soon)")
        bump WARNING
    fi

    # Temperature.
    if [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -ge "$TEMP_CRIT" ]; then
        issues+=("CRITICAL: $label — drive temperature ${temp}°C")
        bump CRITICAL
    elif [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -ge "$TEMP_WARN" ]; then
        warnings+=("WARNING: $label — drive temperature ${temp}°C")
        bump WARNING
    fi

    oklines+=("$label: used ${pct}% spare ${spare}% media_err ${media} ${temp}°C")
done

# --- Output ---
if [ ${#issues[@]} -gt 0 ]; then
    printf '%s\n' "${issues[@]}"
fi
if [ ${#warnings[@]} -gt 0 ]; then
    printf '%s\n' "${warnings[@]}"
fi
if [ "$exit_code" -eq "$EXIT_OK" ]; then
    echo "OK: SMART nominal — ${oklines[*]}"
fi

exit $exit_code
