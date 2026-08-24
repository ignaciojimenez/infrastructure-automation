#!/bin/sh
# POSIX-compliant layered wifi recovery for the W1 lockout (Linux/NetworkManager)
#
# Usage: wifi_reconnect.sh <slack_webhook_path> [diagnostic_peer_ip] [connection_name]
#
# NOTE: the peer is DIAGNOSTIC ONLY and never decides whether to act. See
# health_is_ok() for why that distinction cost an outage.
#
# ── Why this exists ───────────────────────────────────────────────────────────
# vinylstreamer's radio times out mid-association, NetworkManager misreads that
# as missing credentials, and gives up: `failed (reason 'no-secrets')` followed
# by ZERO wlan0 lines until something resets it. Measured 2026-08-24: 28 minutes
# of total silence, and on 2026-08-23 nearly 22 hours.
#
# 🔴 `connection.autoconnect-retries=0` DOES NOT FIX THIS. It was deployed and
# verified in effect (`NetworkManager --print-config` returns it) and the host
# gave up anyway — a `no-secrets` failure appears to *block* autoconnect rather
# than exhaust a retry counter, and a counter cannot reach a block. That is why
# recovery has to come from outside NM's own autoconnect.
#
# ── Why layered ───────────────────────────────────────────────────────────────
# We do not know how deep the wedge goes. A power cycle demonstrably clears it,
# but that is a 15-45 minute outage and a reboot. Each layer here is a cheaper
# hypothesis, and WHICH LAYER SUCCEEDS IS THE DIAGNOSTIC:
#
#   1. `nmcli con up`   — NM gave up but the driver is fine
#   2. interface bounce — the link layer needs resetting, NM alone is not enough
#   3. brcmfmac reload  — the driver itself is wedged
#
# If layer 1 always works, this was purely a NetworkManager give-up. If only
# layer 3 ever works, the fault is in the driver and W1's whole framing changes.
# So every recovery reports which layer did it.
#
# ── Why it reports every single time ──────────────────────────────────────────
# ⚠️ Recovering in ~2 min means HA's ping sensor (15 min threshold) never fires,
# the plug watchdog never fires, and the outages become INVISIBLE. That is the
# item-15 failure mode exactly: a fault that stops being reported is not a fault
# that stopped. So each recovery posts to #home-logging and the frequency count
# keeps accumulating. Fixing the symptom must not cost us the measurement.
#
# The plug watchdog stays as the backstop, unchanged, for the case where all
# three layers fail.

set -u

WEBHOOK="${1:-}"
PEER="${2:-}"          # diagnostic only — NEVER decides whether to act
CONN="${3:-preconfigured}"
IFACE="${WIFI_RECONNECT_IFACE:-wlan0}"

if [ -z "$WEBHOOK" ]; then
    echo "Usage: $0 <slack_webhook_path> [diagnostic_peer_ip] [connection_name]" >&2
    exit 2
fi

NMCLI="${WIFI_RECONNECT_NMCLI:-sudo nmcli}"
IPCMD="${WIFI_RECONNECT_IP:-sudo ip}"
MODPROBE="${WIFI_RECONNECT_MODPROBE:-sudo modprobe}"
SETI="${WIFI_RECONNECT_SETTLE:-8}"
CURL="${WIFI_RECONNECT_CURL:-curl}"

STATE_DIR="${WIFI_RECONNECT_STATE_DIR:-/var/log/monitoring-state}"
STATE_FILE="$STATE_DIR/wifi_reconnect.fails"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# 🔴 NO STATE, NO ACTION. The consecutive-failure counter below is the only
# thing standing between a single bad sample and a driver reload. If it cannot
# be persisted, every run reads a fresh 0 and the gate silently degrades to
# "act immediately" — the guard would look present in the source and be absent
# in practice.
#
# Measured on vinylstreamer 2026-08-24: /var/log/monitoring-state is created by
# the proxmox platform role and does not exist on a Pi, so the counter was
# unwritable on the very first deploy. Refusing is the safe direction: the plug
# watchdog still recovers the host, whereas an ungated ladder breaks it.
if ! touch "$STATE_FILE" 2>/dev/null; then
    echo "❌ Cannot write ${STATE_FILE} — the consecutive-failure gate cannot work,"
    echo "   so recovery is DISABLED rather than run ungated. Create the directory."
    exit 1
fi

# 🔴 HEALTH IS JUDGED FROM LOCAL FACTS ONLY. NEVER FROM A PING.
#
# The first version of this script pinged the default gateway (10.30.100.254)
# and treated failure as "the radio is broken". That gateway does not answer
# ICMP AT ALL — 0/3 even from a healthy host on the same VLAN — so the check
# could never pass, and the script ran the full ladder (including a brcmfmac
# reload) every 2 minutes against a perfectly healthy radio. It took the host
# down repeatedly on 2026-08-24 until the cron was pulled.
#
# The lesson is not "pick a better ping target". It is that a recovery action
# must be gated on a signal whose HEALTHY value has been observed, not assumed.
# These two have been: `nmcli` reports `wlan0:connected` and a default route
# exists on a working host, and the captured failure shows NM driving the device
# to `disconnected` — the exact fault this recovers from.
health_is_ok() {
    _state=$($NMCLI -t -f DEVICE,STATE dev status 2>/dev/null \
             | grep "^${IFACE}:" | cut -d: -f2)
    [ "$_state" = "connected" ] || return 1
    $IPCMD route show default 2>/dev/null | grep -q "dev ${IFACE}" || return 1
    return 0
}

# Diagnostic only. Recorded in the notification so we learn whether the link was
# carrying traffic, but it must never gate an action — that is the mistake above.
peer_note() {
    [ -n "$PEER" ] || { echo "no peer configured"; return; }
    if ping -c 2 -W 2 "$PEER" >/dev/null 2>&1; then
        echo "peer ${PEER} replied"
    else
        echo "peer ${PEER} silent"
    fi
}

notify() {
    [ -n "$WEBHOOK" ] || return 0
    $CURL -s -X POST --max-time 10 \
        -H 'Content-type: application/json' \
        --data "{\"text\":\"$1\"}" \
        "https://hooks.slack.com/services/$WEBHOOK" >/dev/null 2>&1 || true
}

# --- Healthy path: reset the counter, say nothing. ----------------------------
if health_is_ok; then
    echo "0" > "$STATE_FILE" 2>/dev/null || true
    echo "✅ ${IFACE} healthy (NM connected, default route present)"
    exit 0
fi

# 🔴 Two consecutive observations before ANY action. A single bad sample must
# never reload a driver — the cost of acting wrongly here is an outage, which is
# strictly worse than the fault we are recovering from. Roughly a 4-minute delay
# at a 2-minute interval, against a plug watchdog that takes 15-45.
FAILS=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
FAILS=$(( FAILS + 1 ))
echo "$FAILS" > "$STATE_FILE" 2>/dev/null || true

if [ "$FAILS" -lt 2 ]; then
    echo "⚠️  ${IFACE} looks down (observation ${FAILS}/2) — waiting for confirmation before acting"
    exit 0
fi

echo "⚠️  ${IFACE} down on ${FAILS} consecutive checks ($(peer_note)) — starting layered recovery"
START=$(date +%s)

# --- Layer 1: NetworkManager gave up; ask it again. ---------------------------
echo "→ layer 1: ${NMCLI} con up ${CONN}"
$NMCLI con up "$CONN" >/dev/null 2>&1
sleep "$SETI"
if health_is_ok; then
    echo "0" > "$STATE_FILE" 2>/dev/null || true
    ELAPSED=$(( $(date +%s) - START ))
    echo "✅ recovered at layer 1 (nmcli con up) after ${ELAPSED}s"
    notify ":arrows_counterclockwise: vinylstreamer wifi recovered at *layer 1* (\`nmcli con up\`) after ${ELAPSED}s — NetworkManager had given up but the driver was fine. W1 remediation, root cause still open."
    exit 0
fi

# --- Layer 2: the link layer needs a kick. ------------------------------------
echo "→ layer 2: bounce ${IFACE}"
$IPCMD link set "$IFACE" down >/dev/null 2>&1
sleep 2
$IPCMD link set "$IFACE" up >/dev/null 2>&1
sleep 2
$NMCLI con up "$CONN" >/dev/null 2>&1
sleep "$SETI"
if health_is_ok; then
    echo "0" > "$STATE_FILE" 2>/dev/null || true
    ELAPSED=$(( $(date +%s) - START ))
    echo "✅ recovered at layer 2 (interface bounce) after ${ELAPSED}s"
    notify ":arrows_counterclockwise: vinylstreamer wifi recovered at *layer 2* (interface bounce) after ${ELAPSED}s — \`nmcli con up\` alone was NOT enough, the link layer needed resetting. Record this against W1."
    exit 0
fi

# --- Layer 3: the driver itself. ----------------------------------------------
# ⚠️ Last resort before the plug. Reloading the module on a host whose only link
# is this radio strands it if the reload fails — which is precisely why the plug
# watchdog stays in place and is not being retired by this script.
echo "→ layer 3: reload brcmfmac"
$MODPROBE -r brcmfmac >/dev/null 2>&1
sleep 3
$MODPROBE brcmfmac >/dev/null 2>&1
sleep 5
$NMCLI con up "$CONN" >/dev/null 2>&1
sleep "$SETI"
if health_is_ok; then
    echo "0" > "$STATE_FILE" 2>/dev/null || true
    ELAPSED=$(( $(date +%s) - START ))
    echo "✅ recovered at layer 3 (brcmfmac reload) after ${ELAPSED}s"
    notify ":arrows_counterclockwise: vinylstreamer wifi recovered at *layer 3* (brcmfmac reload) after ${ELAPSED}s — NM and an interface bounce both failed, so the DRIVER was wedged. This reframes W1: the fault is below NetworkManager."
    exit 0
fi

ELAPSED=$(( $(date +%s) - START ))
echo "❌ all three recovery layers failed after ${ELAPSED}s — ${IFACE} is still not connected ($(peer_note))"
echo "   The plug watchdog is the remaining backstop (HA, 15 min threshold)."
exit 1
