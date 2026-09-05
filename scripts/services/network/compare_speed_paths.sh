#!/bin/sh
# compare_speed_paths.sh — compare this host's WAN measurement against a peer's,
# and assert that the two are actually taking different routes.
#
# Runs on the VPN-side host (agent-lxc). Its peer (dockassist) measures the
# direct path. Both write speed_last.json via internet_speed_monitor; this reads
# both, records the pair, and alerts.
#
# ── Why this exists as its own job ────────────────────────────────────────────
# Two hosts each running an absolute-threshold speed check are not a comparison.
# docs/TODO.md item 1d wants the RATIO, because an absolute floor fires whenever
# the ISP has a bad evening and says nothing about the tunnel. Until something
# owns the comparison, the ratio only exists when a human greps two logs — and
# then it silently stays two absolute checks, which is the thing 1d already
# rejected.
#
# ── The alert that needs no threshold ─────────────────────────────────────────
# 🔴 The headline check here is NOT the ratio. It is that the two paths report
# DIFFERENT egress addresses.
#
# If the VPN tunnel drops and this host starts leaving through the normal WAN,
# its throughput goes UP and the ratio moves toward 1.0 — so a pure speed
# comparison reads a VANISHED tunnel as a perfectly healthy one. That failure is
# both more likely and more serious than gradual degradation, and unlike a ratio
# threshold it needs no baseline to detect: same exit address means the traffic
# is not tunnelled. Binary, certain, and available from day one.
#
# ── Why the ratio is recorded but not alerted on ──────────────────────────────
# Setting a ratio threshold needs to know the noise floor. As of 2026-09-05
# there were two samples 17 days apart (94%, 99%) and a single 3-test run spread
# 935.01 / 938.16 / 908.66 Mbps — ~3% within one run. A threshold drawn from two
# points would page on ordinary variation. So this appends the ratio to a
# durable CSV and leaves --min-ratio unset; turning it on later is a config
# change, not a build.
#
# Exit: 0 healthy · 1 fault (alert) · 2 cannot compare (misconfigured/stale)

set -u

STATE_DIR="${HOME}/.logs"
PEER_HOST="dockassist-agent"
PEER_LABEL="direct"
LOCAL_LABEL="vpn"
MAX_AGE_MIN=60
MIN_RATIO=""          # empty = ratio is recorded, never alerted on
SSH_TIMEOUT=15

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") [options]
  --state-dir=PATH    where speed_last.json / the ratio CSV live (default: \$HOME/.logs)
  --peer=HOST         ssh target that measures the other path (default: dockassist-agent)
  --peer-label=NAME   label for the peer's path in the CSV (default: direct)
  --local-label=NAME  label for this host's path in the CSV (default: vpn)
  --max-age=MIN       refuse to compare records older than this (default: 60)
  --min-ratio=FLOAT   alert when local/peer throughput falls below this.
                      UNSET BY DEFAULT ON PURPOSE — see the header.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir=*)   STATE_DIR="${1#*=}" ;;
        --peer=*)        PEER_HOST="${1#*=}" ;;
        --peer-label=*)  PEER_LABEL="${1#*=}" ;;
        --local-label=*) LOCAL_LABEL="${1#*=}" ;;
        --max-age=*)     MAX_AGE_MIN="${1#*=}" ;;
        --min-ratio=*)   MIN_RATIO="${1#*=}" ;;
        --ssh-timeout=*) SSH_TIMEOUT="${1#*=}" ;;
        -h|--help)       usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
    shift
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 2; }

LOCAL_JSON="${STATE_DIR}/speed_last.json"
RATIO_CSV="${STATE_DIR}/speed_ratio_history.csv"

[ -f "$LOCAL_JSON" ] || { fail "no local measurement at $LOCAL_JSON — has internet_speed_monitor run yet?"; exit 2; }

# ── Fetch the peer's record ──────────────────────────────────────────────────
# Through agent_read rather than a direct cat: the peer's home is 0700 and this
# connects as the read-only account, which cannot see into it otherwise.
peer_raw=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$PEER_HOST" \
    'sudo -n /usr/local/bin/agent_read log speed_last.json' 2>/dev/null)
if [ -z "$peer_raw" ]; then
    fail "could not read speed_last.json from $PEER_HOST (unreachable, or it has not measured yet)"
    exit 2
fi

local_raw=$(cat "$LOCAL_JSON")

# jq -e so a malformed record fails here rather than yielding an empty string
# that arithmetic below would silently treat as zero.
read_field() {
    printf '%s' "$1" | jq -er ".$2" 2>/dev/null
}

for f in timestamp download_mbps upload_mbps external_ip isp; do
    if ! read_field "$local_raw" "$f" >/dev/null; then fail "local record missing field: $f"; exit 2; fi
    if ! read_field "$peer_raw"  "$f" >/dev/null; then fail "peer record missing field: $f"; exit 2; fi
done

l_ts=$(read_field "$local_raw" timestamp);  p_ts=$(read_field "$peer_raw" timestamp)
l_dn=$(read_field "$local_raw" download_mbps); p_dn=$(read_field "$peer_raw" download_mbps)
l_up=$(read_field "$local_raw" upload_mbps);   p_up=$(read_field "$peer_raw" upload_mbps)
l_ip=$(read_field "$local_raw" external_ip);   p_ip=$(read_field "$peer_raw" external_ip)
l_isp=$(read_field "$local_raw" isp);          p_isp=$(read_field "$peer_raw" isp)

# ── Freshness ────────────────────────────────────────────────────────────────
# A stale record is not a healthy one. Comparing yesterday's VPN number against
# today's direct number would produce a ratio that means nothing, and a check
# that reports a meaningless number as green is worse than one that refuses.
now_epoch=$(date -u '+%s')
# GNU and BSD `date` disagree on parsing a timestamp, and this repo's monitoring
# scripts are expected to run on both. Try GNU's -d, then BSD's -j -f. Returning
# non-zero when neither works matters: a silently-zero epoch would make every
# record look ancient and take this check permanently to exit 2.
age_min() {
    e=$(date -u -d "$1" '+%s' 2>/dev/null) \
      || e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null) \
      || return 1
    [ -n "$e" ] || return 1
    echo $(( (now_epoch - e) / 60 ))
}
l_age=$(age_min "$l_ts") || { fail "cannot parse local timestamp: $l_ts"; exit 2; }
p_age=$(age_min "$p_ts") || { fail "cannot parse peer timestamp: $p_ts"; exit 2; }

if [ "$l_age" -gt "$MAX_AGE_MIN" ] || [ "$p_age" -gt "$MAX_AGE_MIN" ]; then
    fail "stale measurements (local ${l_age}min, peer ${p_age}min, limit ${MAX_AGE_MIN}min) — not comparing"
    exit 2
fi

# ── Record the pair before judging it ────────────────────────────────────────
ratio_dn=$(awk -v a="$l_dn" -v b="$p_dn" 'BEGIN{ if (b+0 == 0) print "0"; else printf "%.4f", a/b }')
ratio_up=$(awk -v a="$l_up" -v b="$p_up" 'BEGIN{ if (b+0 == 0) print "0"; else printf "%.4f", a/b }')

# Same reason as internet_speed_monitor's write_state: the ISP fields are
# vendor-controlled free text, and one comma would shift every column after it.
l_isp_csv=$(printf '%s' "$l_isp" | tr ',' ' ')
p_isp_csv=$(printf '%s' "$p_isp" | tr ',' ' ')

if [ ! -f "$RATIO_CSV" ]; then
    echo "timestamp,local_label,peer_label,local_down,peer_down,ratio_down,local_up,peer_up,ratio_up,local_ip,peer_ip,local_isp,peer_isp" > "$RATIO_CSV" 2>/dev/null \
        || fail "cannot create $RATIO_CSV"
fi
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOCAL_LABEL" "$PEER_LABEL" \
    "$l_dn" "$p_dn" "$ratio_dn" "$l_up" "$p_up" "$ratio_up" \
    "$l_ip" "$p_ip" "$l_isp_csv" "$p_isp_csv" >> "$RATIO_CSV" 2>/dev/null \
    || fail "cannot append $RATIO_CSV"

log "${LOCAL_LABEL}: ${l_dn}/${l_up} Mbps via ${l_ip} (${l_isp})"
log "${PEER_LABEL}: ${p_dn}/${p_up} Mbps via ${p_ip} (${p_isp})"
log "ratio: down ${ratio_dn}, up ${ratio_up}"

# ── The check that needs no baseline ─────────────────────────────────────────
if [ "$l_ip" = "$p_ip" ]; then
    fail "❌ ${LOCAL_LABEL} and ${PEER_LABEL} egress from the SAME address (${l_ip})"
    fail "   The tunnel is not carrying this host's traffic. Throughput will look FINE"
    fail "   or better — speed alone cannot detect this, which is why the address is checked."
    fail "   ISP reported: ${LOCAL_LABEL}=${l_isp} ${PEER_LABEL}=${p_isp}"
    exit 1
fi

# ── The ratio check, off unless configured ───────────────────────────────────
if [ -n "$MIN_RATIO" ]; then
    below=$(awk -v r="$ratio_dn" -v m="$MIN_RATIO" 'BEGIN{ print (r+0 < m+0) ? "yes" : "no" }')
    if [ "$below" = "yes" ]; then
        fail "❌ ${LOCAL_LABEL}/${PEER_LABEL} download ratio ${ratio_dn} is below ${MIN_RATIO}"
        fail "   ${LOCAL_LABEL} ${l_dn} Mbps vs ${PEER_LABEL} ${p_dn} Mbps, both on the same pinned server."
        exit 1
    fi
fi

log "✅ paths differ (${l_ip} vs ${p_ip}); ratio down ${ratio_dn}, up ${ratio_up}"
exit 0
