#!/bin/sh
# save_temps.sh
# Dense thermal + throttle recorder for the Proxmox host.
#
# The 30-min health check (check_proxmox_health.sh) only samples an *instantaneous*
# temperature and logs nothing when it passes, so a thermal spike that crashes the
# box (e.g. a silicon-level THERMTRIP, which leaves no kernel log) is invisible
# afterwards. This logs a high-frequency timeline of temps AND the hardware throttle
# counter so such an event can be reconstructed.
#
# Key signal: package_throttle_count. The CPU can read a calm 56C between throttle
# cycles while actually slamming Tjmax (105C) thousands of times -- only the counter
# reveals it. We record the running count and its delta since the previous sample.
#
# Append-only, self-rotating. No alerting -- thresholds live in check_proxmox_health.sh.

set -eu

# LOG_DIR is overridable (SAVE_TEMPS_LOG_DIR) purely to allow testing without root;
# production cron uses the default.
LOG_DIR="${SAVE_TEMPS_LOG_DIR:-/var/log/diagnostics}"
LOG_FILE="$LOG_DIR/thermal-history.log"
STATE_FILE="$LOG_DIR/.thermal-throttle.prev"
THROTTLE_NODE=/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count
MAX_LINES=2160   # ~3 days at one sample every 2 minutes

mkdir -p "$LOG_DIR"

# CPU package temperature (integer C); NA if sensors/field unavailable.
pkg=$(sensors 2>/dev/null | awk \
    '/^Package id 0:/ {v=$4; gsub(/[^0-9.]/,"",v); print int(v); exit}')
[ -n "${pkg:-}" ] || pkg=NA

# Hottest individual core (integer C).
core_max=$(sensors 2>/dev/null | awk \
    '/^Core [0-9]+:/ {v=$3; gsub(/[^0-9.]/,"",v); t=int(v); if (t>m) m=t}
     END {if (m=="") print "NA"; else print m}')

# NVMe composite temperature (integer C).
nvme=$(sensors 2>/dev/null | awk \
    '/^Composite:/ {v=$2; gsub(/[^0-9.]/,"",v); print int(v); exit}')
[ -n "${nvme:-}" ] || nvme=NA

# Package throttle counter (cumulative since boot) and delta vs previous sample.
tc=$(cat "$THROTTLE_NODE" 2>/dev/null || echo NA)
delta=NA
if [ "$tc" != NA ] && [ -f "$STATE_FILE" ]; then
    prev=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    case "$prev" in
        "" | *[!0-9]*) delta=NA ;;
        *) delta=$(( tc - prev )) ;;
    esac
fi
[ "$tc" != NA ] && printf '%s\n' "$tc" > "$STATE_FILE"

load=$(awk '{print $1}' /proc/loadavg)
ts=$(date '+%Y-%m-%dT%H:%M:%S%z')

printf '%s pkg=%s core_max=%s nvme=%s throttle=%s throttle_delta=%s load=%s\n' \
    "$ts" "$pkg" "$core_max" "$nvme" "$tc" "$delta" "$load" >> "$LOG_FILE"

# Self-rotate: keep only the most recent MAX_LINES.
lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$lines" -gt "$MAX_LINES" ]; then
    tmp="$LOG_FILE.tmp.$$"
    tail -n "$MAX_LINES" "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
fi

# World-readable so the read_agent diagnostic user can inspect it over SSH.
chmod 644 "$LOG_FILE" 2>/dev/null || true
