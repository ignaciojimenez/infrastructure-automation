#!/bin/sh
# POSIX-compliant NIC transmit-stall check (Linux only)
#
# The Raspberry Pi's bcmgenet driver logs a kernel line when a transmit queue
# stops making progress and the watchdog resets it:
#
#   bcmgenet fd580000.ethernet eth0: NETDEV WATCHDOG: CPU: 1: transmit queue 0 timed out 2024 ms
#
# One of these is usually a benign hiccup. A run of them means the link is
# stalling repeatedly, which on dockassist takes Home Assistant, the Matter
# server and Cloudflared off the network without any service or container check
# noticing — the host is up, the units are active, and nothing is reachable.
# That is the failure shape of TODO item 15, one layer down.
#
# 🔴 Alerts on the DELTA since the previous run, never on presence. The journal
# keeps these lines for as long as it keeps anything, so a presence test would
# fire forever about one historical event and be muted within a day. Same
# reasoning, and the same state-file shape, as check_thermal.sh.
#
# Deliberately NOT a driver workaround. Disabling offloads (`ethtool -K eth0 tso
# off`) is the usual folklore for this message and would be a change made on one
# observation, with no way to tell afterwards whether it helped. Count first.

set -u

STALL_WARN="${NIC_STALL_WARN:-1}"      # events since last run -> warn
STALL_CRIT="${NIC_STALL_CRIT:-5}"      # events since last run -> alert

# Overridable only so the test rig can point it somewhere writable.
STATE_DIR="${CHECK_NIC_STATE_DIR:-/var/log/monitoring-state}"
STATE_FILE="$STATE_DIR/nic_stalls.prev"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# 🔴 Fail loudly if state cannot be persisted. Without this the script is
# harmless-looking and completely inert: every run finds no previous count,
# reports "first run - baseline set", exits 0, and NEVER alerts. Measured on
# dockassist, where /var/log/monitoring-state is created by the proxmox role
# and therefore does not exist on a Pi — the check ran green twice in a row
# while being structurally incapable of firing.
#
# A check that cannot remember is not a quiet check, it is a broken one, and it
# must say so rather than pass.
if ! touch "$STATE_FILE" 2>/dev/null; then
    echo "❌ Cannot write ${STATE_FILE} — delta tracking is impossible, so this check cannot work"
    exit 1
fi

exit_code=0

# Can we read the kernel journal at all? Asked separately and FIRST, because
# "no stalls" and "cannot see the journal" are the same silence otherwise — and
# a check that reports a clean bill of health when it is actually blind is the
# exact failure this whole item exists to prevent.
if ! journalctl -k --no-pager -n 1 >/dev/null 2>&1; then
    echo "❌ Cannot read the kernel journal — is this user in systemd-journal?"
    exit 1
fi

# Count every stall the journal still holds.
#
# 🔴 No `|| echo 0` here. `grep -c` prints 0 AND exits 1 when there are no
# matches, so the fallback appended a second 0 and produced "0\n0" — which
# failed the numeric guard and reported a *journal read error* on precisely the
# healthy hosts that have never stalled. Caught by forcing the zero-match case
# rather than by reading the code.
count_now=$(journalctl -k --no-pager 2>/dev/null | grep -c "NETDEV WATCHDOG")

case "$count_now" in
    ''|*[!0-9]*)
        echo "❌ Could not count NIC stalls (unexpected value: '${count_now}')"
        exit 1
        ;;
esac

delta=0
prev=$(cat "$STATE_FILE" 2>/dev/null || echo "")
case "$prev" in
    ''|*[!0-9]*)
        # No usable previous count: first run, or the file was just created by
        # the writability probe above. Establish the baseline silently-ish —
        # reporting the whole historical backlog here would alert once about
        # things that already happened and teach the reader to ignore this check.
        echo "ℹ️  Baseline set at ${count_now} historical NIC stall(s), not alerting"
        ;;
    *)
        delta=$(( count_now - prev ))
        # A journal rotation (or a reboot) shrinks the count. Treat a negative
        # delta as a fresh baseline rather than as good news.
        [ "$delta" -lt 0 ] && delta=0
        ;;
esac

echo "$count_now" > "$STATE_FILE"

if [ "$delta" -ge "$STALL_CRIT" ]; then
    echo "❌ NIC transmit stalls: ${delta} since last check (total ${count_now}) — the link is stalling repeatedly"
    exit_code=1
elif [ "$delta" -ge "$STALL_WARN" ]; then
    echo "❌ NIC transmit stalls: ${delta} since last check (total ${count_now})"
    exit_code=1
else
    echo "✅ No new NIC transmit stalls (total seen: ${count_now})"
fi

exit "$exit_code"
