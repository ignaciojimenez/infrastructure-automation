#!/bin/sh
# Regression test: the wifi recovery ladder must not destroy its own recovery.
#
# Runs on the laptop — no radio, no NetworkManager, no privilege. `nmcli`, `ip`,
# `modprobe` and `curl` are stubbed; they share one file that says whether the
# link is up, so a stub can bring the link up (NM auto-activating after a driver
# reload) or tear it down (`con up` on top of an active connection).
#
#   tests/unit/wifi_reconnect_ladder_test.sh
#
# The bug this pins (2026-09-13): vinylstreamer was dark from 06:31 to 09:00.
# Every 5 minutes the brcmfmac reload WORKED — NM had the host associated with a
# lease 2 s after `modprobe` — and 8 s later the script's own unconditional
# `nmcli con up` deauthenticated it ("disconnecting for new activation request",
# reason=3 locally generated). The AP rejected the re-association, the health
# check failed, and the script reported "all three recovery layers failed".
# 27 times. The same short up-windows kept HA's ping sensor flapping, which reset
# the plug watchdog's 15-minute timer, so nothing else intervened either.
#
# So the property under test: once a disruptive step has brought the link up,
# the script must SEE that and stop — never force a new activation over it.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="${WIFI_RECONNECT_SCRIPT:-$REPO_ROOT/scripts/services/network/wifi_reconnect.sh}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── wifi_reconnect.sh recovery ladder\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

mkdir -p "$WORK/bin"
S="$WORK/sim"      # simulation knobs + link state, shared by the stubs

# nmcli: `dev status` reports the link; `con up` applies CONUP_EFFECT.
cat > "$WORK/bin/nmcli" <<EOF
#!/bin/sh
S="$S"
case "\$*" in
    *"dev status"*)
        if [ "\$(cat "\$S/link")" = up ]; then echo "wlan0:connected"; else echo "wlan0:disconnected"; fi ;;
    *"con up"*)
        echo "con_up link=\$(cat "\$S/link")" >> "\$S/calls"
        case "\$(cat "\$S/conup_effect")" in
            connect) echo up > "\$S/link" ;;
            break)   echo down > "\$S/link" ;;   # tears down whatever was active
        esac ;;
esac
exit 0
EOF

# ip: `route show default` follows the link; `link set up` may auto-connect.
cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
S="$S"
case "\$*" in
    "route show default")
        [ "\$(cat "\$S/link")" = up ] && echo "default via 10.30.100.254 dev wlan0" ;;
    "link set wlan0 up")
        echo "link_up" >> "\$S/calls"
        [ "\$(cat "\$S/bounce_connects")" = 1 ] && echo up > "\$S/link" ;;
    "link set wlan0 down")
        echo down > "\$S/link" ;;
esac
exit 0
EOF

# modprobe: loading brcmfmac may let NM auto-activate the link.
cat > "$WORK/bin/modprobe" <<EOF
#!/bin/sh
S="$S"
case "\$*" in
    "brcmfmac")
        echo "driver_load" >> "\$S/calls"
        [ -e "\$S/reload_arms_conup" ] && echo connect > "\$S/conup_effect"
        [ "\$(cat "\$S/reload_connects")" = 1 ] && echo up > "\$S/link" ;;
    "-r brcmfmac")
        echo down > "\$S/link" ;;
esac
exit 0
EOF

cat > "$WORK/bin/curl" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do
    [ "\$1" = "--data" ] && { printf '%s\n' "\$2" >> "$S/notify"; shift; }
    shift
done
exit 0
EOF
chmod +x "$WORK/bin/"*

# scenario <link> <fails> <conup_effect> <bounce_connects> <reload_connects>
scenario() {
    rm -rf "$S"; mkdir -p "$S/state"
    echo "$1" > "$S/link"
    echo "$2" > "$S/state/wifi_reconnect.fails"
    echo "$3" > "$S/conup_effect"
    echo "$4" > "$S/bounce_connects"
    echo "$5" > "$S/reload_connects"
    : > "$S/calls"; : > "$S/notify"
}

run() {
    OUT=$(WIFI_RECONNECT_NMCLI="$WORK/bin/nmcli" \
          WIFI_RECONNECT_IP="$WORK/bin/ip" \
          WIFI_RECONNECT_MODPROBE="$WORK/bin/modprobe" \
          WIFI_RECONNECT_CURL="$WORK/bin/curl" \
          WIFI_RECONNECT_STATE_DIR="$S/state" \
          WIFI_RECONNECT_SETTLE=2 WIFI_RECONNECT_DRIVER_WAIT=3 \
          WIFI_RECONNECT_POLL=0 WIFI_RECONNECT_PAUSE=0 \
          sh "$SCRIPT" "T000/B000/xxx" "" preconfigured 2>&1)
    RC=$?
}

# if/then/else rather than `A && pass || fail`: in that form fail also runs when
# pass itself returns non-zero (ShellCheck SC2015), which CI rejects.
expect_rc() {
    if [ "$RC" = "$1" ]; then pass "$2: exit $1"; else fail "$2: expected exit $1, got $RC — output: $OUT"; fi
}
expect_out() {
    if printf '%s' "$OUT" | grep -q -- "$1"; then pass "$2"; else fail "$2 — output: $OUT"; fi
}
expect_notify() {
    if grep -q -- "$1" "$S/notify"; then pass "$2"; else fail "$2 — notify: $(cat "$S/notify")"; fi
}
expect_state() {
    if [ "$(cat "$S/state/wifi_reconnect.fails")" = "$1" ]; then pass "$2"; else fail "$2 — counter is $(cat "$S/state/wifi_reconnect.fails")"; fi
}

# ── 1. Healthy: nothing happens, counter and outage clock reset. ─────────────
scenario up 5 break 0 0
echo 1000 > "$S/state/wifi_reconnect.since"
run
expect_rc 0 "healthy"
expect_state 0 "healthy: counter reset"
if [ ! -e "$S/state/wifi_reconnect.since" ]; then pass "healthy: outage clock cleared"; else fail "healthy: outage clock left behind"; fi
if [ ! -s "$S/calls" ]; then pass "healthy: no recovery action taken"; else fail "healthy: acted on a healthy link — $(cat "$S/calls")"; fi

# ── 2. First bad sample: record, never act. ──────────────────────────────────
scenario down 0 connect 0 0
run
expect_rc 0 "first observation"
expect_state 1 "first observation: counter 1"
if [ -s "$S/state/wifi_reconnect.since" ]; then pass "first observation: outage clock started"; else fail "first observation: no outage clock"; fi
if [ ! -s "$S/calls" ]; then pass "first observation: no action"; else fail "first observation: acted on one sample — $(cat "$S/calls")"; fi

# ── 3. THE 2026-09-13 REGRESSION ─────────────────────────────────────────────
# Layers 1 and 2 cannot connect; the driver reload lets NM connect on its own;
# a `con up` over an active connection tears it down.
scenario down 1 break 0 1
run
expect_rc 0 "driver reload auto-connects"
expect_out "recovered at layer 3" "reports layer 3, not 'all three layers failed'"
if sed -n '/driver_load/,$p' "$S/calls" | grep -q con_up; then
    fail "forced con up AFTER the driver reload had already connected — $(tr '\n' ' ' < "$S/calls")"
else
    pass "no con up forced over NM's own activation"
fi
expect_notify "layer 3" "layer-3 recovery is reported to Slack"

# Same shape one layer earlier: the bounce itself lets NM reconnect.
scenario down 1 break 1 0
run
expect_rc 0 "bounce auto-connects"
expect_out "recovered at layer 2" "reports layer 2"
if sed -n '/link_up/,$p' "$S/calls" | grep -q con_up; then
    fail "forced con up after the bounce had already connected"
else
    pass "no con up forced over the bounce's activation"
fi

# ── 4. Reload does not auto-connect: the forced con up must still happen. ────
# Layers 1 and 2 must miss, so `con up` only starts working once the driver is
# reloaded — the stub arms it on load.
scenario down 1 none 0 0
touch "$S/reload_arms_conup"
run
expect_rc 0 "reload needs a forced con up"
expect_out "recovered at layer 3" "reports layer 3"
if sed -n '/driver_load/,$p' "$S/calls" | grep -q con_up; then
    pass "forced con up used when NM did not auto-activate"
else
    fail "never forced con up although NM stayed down"
fi

# ── 5. Layer 1 works; the message carries the OUTAGE, not the run. ───────────
scenario down 29 connect 0 0
echo $(( $(date +%s) - 9000 )) > "$S/state/wifi_reconnect.since"
run
expect_rc 0 "layer 1"
expect_notify "layer 1" "layer-1 recovery reported"
expect_notify "down ~150 min across 30 checks" "reports the 2.5 h outage and attempt count, not only this run"
expect_state 0 "layer 1: counter reset"

# ── 6. Nothing works: fail loudly, keep the state. ───────────────────────────
scenario down 1 none 0 0
run
expect_rc 1 "all layers fail"
expect_out "all three recovery layers failed" "says so"
expect_state 2 "counter kept"
if [ ! -s "$S/notify" ]; then pass "no false recovery message"; else fail "posted a recovery that did not happen"; fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   All checks passed.\n\n'
    exit 0
fi
printf '   %d check(s) failed.\n\n' "$failures"
exit 1
