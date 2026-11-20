#!/bin/sh
# Regression test: check_wg.sh judges the Mullvad tunnels by gateway status,
# group by group, the way OPNsense's failover does.
#
#   tests/unit/check_wg_test.sh            # script under sh
#   dash tests/unit/check_wg_test.sh dash  # script under dash
#
# CHECK_WG_TEST_SCRIPT points it at another copy, e.g. the pre-2026-11-20
# revision, to show which assertions it fails.
#
# pluginctl and wg are stubs on PATH. The config fixture mirrors the firewall's
# real structure read on 2026-11-20 (gateway items, interface map, the NL group's
# five tiers as item..item5) with no keys and no WAN addressing. Each case plants
# a real incident: ES3 dead for three days, US3's monitor not answering while the
# tunnel handshakes, and the NL group running out of members.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="${CHECK_WG_TEST_SCRIPT:-$REPO_ROOT/scripts/services/opnsense/check_wg.sh}"
SH="${1:-sh}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_wg.sh (%s)\n' "$SH"
[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

NOW=$(date +%s)  # the pre-2026-11-20 script reads the real clock, so the fixtures do too
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pluginctl" <<EOF
#!/bin/sh
[ -e "$WORK/pluginctl_fail" ] && { echo "configd: connection refused" >&2; exit 1; }
cat "$WORK/status.json"
EOF
# Answers the three forms real wg(8) is asked: show interfaces, show all
# latest-handshakes, show <if> latest-handshakes.
cat > "$WORK/bin/wg" <<EOF
#!/bin/sh
case "\${2:-}" in
    '') exit 0 ;;
    interfaces) awk '{printf "%s ", \$1} END {print ""}' "$WORK/hs" ;;
    all) cat "$WORK/hs" ;;
    *) awk -v i="\$2" '\$1 == i {print \$2 "\t" \$3}' "$WORK/hs" ;;
esac
EOF
chmod +x "$WORK/bin/pluginctl" "$WORK/bin/wg"

# name:optN:wgN:monitor
GWS="NL1:opt8:wg0:198.41.0.4 NL2:opt9:wg2:199.9.14.201 NL3:opt6:wg3:192.33.4.12
ES1:opt10:wg4:199.7.91.13 ES2:opt11:wg5:192.203.230.10 ES3:opt12:wg6:192.5.5.241
US1:opt13:wg7:199.7.83.42 US2:opt14:wg8:202.12.27.33 US3:opt15:wg9:198.97.190.53
UK1:opt16:wg10:192.36.148.17 UK2:opt17:wg11:192.58.128.30 UK3:opt18:wg12:193.0.14.129"

# config <nl_group_trigger>
config() {
    {
        echo '<opnsense><interfaces><wan><if>vlan0.300</if></wan><opt7><if>wg1</if></opt7>'
        for g in $GWS; do IFS=: read -r n o d m <<E
$g
E
            echo "<$o><if>$d</if></$o>"
        done
        echo '</interfaces><gateways>'
        for g in $GWS; do IFS=: read -r n o d m <<E
$g
E
            echo "<gateway_item><name>WG_MULLVAD_GW_$n</name><interface>$o</interface><monitor>$m</monitor><disabled>0</disabled></gateway_item>"
        done
        echo '<gateway_item><name>ETH2_WAN_DHCP</name><interface>wan</interface><disabled>0</disabled></gateway_item>'
        echo "<gateway_group><name>Mullvad_failover_nl</name><item2>WG_MULLVAD_GW_NL2</item2><item3>WG_MULLVAD_GW_NL3</item3><item4>WG_MULLVAD_GW_UK3</item4><item5>WG_MULLVAD_GW_ES1</item5><item>WG_MULLVAD_GW_NL1</item><trigger>$1</trigger></gateway_group>"
        echo '<gateway_group><name>Mullvad_failover_es</name><item>WG_MULLVAD_GW_ES1</item><trigger>downlosslatency</trigger></gateway_group>'
        # The real US and UK groups carry empty tier slots (item4, item5).
        echo '<gateway_group><name>Mullvad_failover_us</name><item>WG_MULLVAD_GW_US1</item><item2>WG_MULLVAD_GW_US2</item2><item3>WG_MULLVAD_GW_US3</item3><item4/><item5></item5><trigger>downlosslatency</trigger></gateway_group>'
        echo '</gateways></opnsense>'
    } > "$WORK/config.xml"
}

# status <gw=state>... — every other gateway is "none" (up).
status() {
    {
        printf '{"dpinger":{"ETH2_WAN_DHCP":{"status":"none","monitor":"~"}'
        for g in $GWS; do
            n=${g%%:*}; st=none
            for o in "$@"; do [ "${o%%=*}" = "$n" ] && st=${o#*=}; done
            printf ',"WG_MULLVAD_GW_%s":{"status":"%s","name":"WG_MULLVAD_GW_%s","loss":"0.0 %%"}' "$n" "$st" "$n"
        done
        printf '}}'
    } > "$WORK/status.json"
}

# handshakes <wgN=age|never>... — every other tunnel handshook 30 s ago.
handshakes() {
    : > "$WORK/hs"
    for d in wg0 wg1 wg2 wg3 wg4 wg5 wg6 wg7 wg8 wg9 wg10 wg11 wg12; do
        t=$((NOW - 30))
        for o in "$@"; do
            [ "${o%%=*}" = "$d" ] || continue
            case "${o#*=}" in never) t=0 ;; *) t=$((NOW - ${o#*=})) ;; esac
        done
        printf '%s\tKEY%s=\t%s\n' "$d" "$d" "$t" >> "$WORK/hs"
    done
}

run() {
    OUT=$(PATH="$WORK/bin:$PATH" CHECK_WG_CONFIG="$WORK/config.xml" CHECK_WG_NOW="${1:-$NOW}" "$SH" "$SCRIPT" 2>&1)
    RC=$?
}

expect_rc() { if [ "$RC" = "$1" ]; then pass "$2 (exit $RC)"; else fail "$2 — expected exit $1, got $RC: $OUT"; fi; }
expect_out() { if printf '%s' "$OUT" | grep -qF -- "$1"; then pass "$2"; else fail "$2 — output lacks: $1 | $OUT"; fi; }
expect_not() { if printf '%s' "$OUT" | grep -qF -- "$1"; then fail "$2 — output unexpectedly has: $1"; else pass "$2"; fi; }

# ── A. All up ────────────────────────────────────────────────────────────────
config downlosslatency; status; handshakes
run
expect_rc 0 "every gateway up"
expect_out "OK: 12/12 Mullvad gateways up" "says so and counts them"

# ── B. ES3, 2026-11-17: tunnel dead, one of twelve ───────────────────────────
status ES3=down; handshakes wg6=164689
run
expect_rc 1 "one dead tunnel of twelve warns"
expect_out "❌ WARNING: WG_MULLVAD_GW_ES3 is down: monitor 192.5.5.241 not answering" "names the gateway and its monitor"
expect_out "tunnel wg6 last handshook 164689 s ago, so the tunnel itself is dead" "blames the tunnel when the handshake is stale"
expect_out "11/12 Mullvad gateways up" "counts what is left"

status ES3=down; handshakes wg6=never
run
expect_out "tunnel wg6 has not handshaken since boot" "a never-handshaken tunnel is called dead"

# ── C. US3, 2026-11-20: monitor dead, tunnel fine ────────────────────────────
status US3=down; handshakes
run
expect_rc 1 "a down gateway on a live tunnel still warns"
expect_out "tunnel wg9 still handshakes (30 s ago), so the monitor is the likelier fault" "points at the monitor when the tunnel handshakes"

# ── D. The NL group running out ──────────────────────────────────────────────
status NL1=down NL2=down NL3=down; handshakes
run
expect_rc 1 "NL1-3 down with UK3 and ES1 left: warning, not critical"
expect_not "CRITICAL" "a group with a usable member is not exhausted"

status NL1=down NL2=down NL3=down UK3=down ES1=down
run
expect_rc 2 "all five NL tiers down is critical"
expect_out "❌ CRITICAL: gateway group Mullvad_failover_nl has no usable member" "names the exhausted group"
expect_out "WG_MULLVAD_GW_NL1, WG_MULLVAD_GW_NL2, WG_MULLVAD_GW_NL3, WG_MULLVAD_GW_UK3, WG_MULLVAD_GW_ES1" "lists its members in tier order"
expect_out "leaves via the WAN gateway, unencrypted" "says the traffic is unencrypted"
expect_out "❌ CRITICAL: gateway group Mullvad_failover_es has no usable member" "ES1 down also exhausts the one-member ES group"

# ES1 down also empties the ES group, so the exit code cannot tell these apart:
# judge the NL group's own line.
status NL1=down NL2=down NL3=down ES1=down UK3=loss
run
expect_out "gateway group Mullvad_failover_nl has no usable member" "last member in a loss alarm counts as unusable under downlosslatency"

config down; run
expect_not "gateway group Mullvad_failover_nl has no usable member" "the same loss alarm under trigger 'down' leaves the member usable"
config downlosslatency

status US1=down US2=down US3=down
run
expect_rc 2 "empty tier slots are not members: US1-3 down exhausts the US group"
expect_out "gateway group Mullvad_failover_us has no usable member (WG_MULLVAD_GW_US1, WG_MULLVAD_GW_US2, WG_MULLVAD_GW_US3)" "and lists only the real members"

# ── E. Alarms that failover handles are not warnings ─────────────────────────
status ES2=loss US1=delay; handshakes
run
expect_rc 0 "loss/delay alarms alone stay OK"
expect_out "in loss/delay alarm: WG_MULLVAD_GW_ES2 (loss), WG_MULLVAD_GW_US1 (delay)" "but are mentioned"

# ── F. A gateway dpinger does not know is not silently healthy ───────────────
status; sed 's/,"WG_MULLVAD_GW_UK2":{[^}]*}//' "$WORK/status.json" > "$WORK/s" && mv "$WORK/s" "$WORK/status.json"
run
expect_rc 1 "a gateway missing from dpinger warns"
expect_out "WG_MULLVAD_GW_UK2 has no gateway status" "and names it"

# ── G. Cannot judge: never OK ────────────────────────────────────────────────
status; touch "$WORK/pluginctl_fail"
run
expect_rc 2 "pluginctl failing is critical"
expect_out "cannot read gateway status" "and says why"
rm -f "$WORK/pluginctl_fail"

printf 'not json' > "$WORK/status.json"
run
expect_rc 2 "unparseable status is critical"

status; printf '<opnsense/>' > "$WORK/config.xml"
run
expect_rc 2 "a config with no WireGuard gateways is critical"
config downlosslatency

# ── H. The wrapper's signature does not move with handshake ages ─────────────
mask() { printf '%s\n' "$1" | grep -F '❌' | sed 's/[0-9][0-9]*/#/g'; }
status ES3=down; handshakes wg6=164689; run; a=$(mask "$OUT")
handshakes wg6=165289; run $((NOW + 600)); b=$(mask "$OUT")
if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "an unchanged failure ten minutes later hashes the same"; else fail "signature moved: [$a] vs [$b]"; fi
status ES3=down US3=down; run; c=$(mask "$OUT")
if [ "$a" != "$c" ]; then pass "a second gateway going down changes the signature"; else fail "a new failure did not change the signature"; fi

printf '\n'
if [ "$failures" -eq 0 ]; then printf '   All checks passed.\n\n'; exit 0; fi
printf '   %d check(s) failed.\n\n' "$failures"
exit 1
