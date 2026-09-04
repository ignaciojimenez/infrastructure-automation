#!/bin/sh
# Regression test: check_homekit_advertise.sh must fail on the Sep 1 state.
#
# Runs on the laptop — no container, no network, no mDNS. `ip`, `ss`,
# `avahi-browse`, `timeout` and `systemctl` are stubbed on PATH and fed
# fixtures whose SHAPE was captured from the real fleet on 2026-09-04 and whose
# identifiers are synthetic — see the note above the shared fixtures.
#
#   tests/unit/homekit_advertise_test.sh
#
# The outage this pins (2026-09-01): Home Assistant started 19 seconds before
# eth0 got its DHCP lease, found docker0's 172.17.0.1 as the only IPv4 on the
# box, and published all three HomeKit bridges there. Apple Home showed every
# accessory as "No Response" for two days while all seven of dockassist's
# existing checks stayed green.
#
# Case 2 is the one that matters. Everything else here guards the parser; that
# case guards the detection. If it ever goes green, this check has become
# decoration — which is exactly what happened to check_avahi.sh, whose
# `systemctl is-active avahi-daemon` was true throughout the outage.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/homeassistant/check_homekit_advertise.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_homekit_advertise: publishes a routable address\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

FIX="$WORK/fix"
BIN="$WORK/bin"
mkdir -p "$FIX" "$BIN"

# ------------------------------------------------------------------
# Stubs. Each reads whichever fixture $FIX currently holds, so a case is set
# up by writing fixtures and then running the script.
# ------------------------------------------------------------------
cat > "$BIN/ip" <<'STUB'
#!/bin/sh
case "$*" in
    *"link show"*)
        cat "$FIX/ip_link" 2>/dev/null
        ;;
    *"addr show dev "*)
        dev=$(printf '%s' "$*" | sed -n 's/.*addr show dev \([^ ]*\).*/\1/p')
        cat "$FIX/ip_addr_$dev" 2>/dev/null
        ;;
esac
exit 0
STUB

cat > "$BIN/ss" <<'STUB'
#!/bin/sh
cat "$FIX/ss" 2>/dev/null
exit 0
STUB

# Successive calls consume $FIX/avahi.1, avahi.2, ... falling back to
# $FIX/avahi. That is what lets a case script a transient: bad on the first
# browse, good on the second.
cat > "$BIN/avahi-browse" <<'STUB'
#!/bin/sh
n=$(cat "$FIX/.n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FIX/.n"
if [ -f "$FIX/avahi.$n" ]; then
    cat "$FIX/avahi.$n"
else
    cat "$FIX/avahi" 2>/dev/null
fi
exit 0
STUB

# `timeout` is not present on stock macOS. Stub it so the test measures the
# script's logic rather than the laptop's coreutils.
cat > "$BIN/timeout" <<'STUB'
#!/bin/sh
shift
exec "$@"
STUB

cat > "$BIN/systemctl" <<'STUB'
#!/bin/sh
exit "${SYSTEMCTL_RC:-0}"
STUB

chmod +x "$BIN"/*
export FIX
PATH="$BIN:$PATH"
export PATH

# TEST_SH lets this run the script under a strict POSIX shell. macOS /bin/sh is
# bash in POSIX mode and forgives things dash does not, so CI and the container
# run this as TEST_SH=dash — see tests/README.md.
TEST_SH="${TEST_SH:-sh}"

# HAP_RECHECK_DELAY=0 keeps the suite instant. The attempt COUNT is left at the
# production default on purpose: the recheck loop itself is under test, only
# its sleep is not.
run_check() {
    rm -f "$FIX/.n"
    HAP_RECHECK_DELAY=0 "$TEST_SH" "$SCRIPT" 2>&1
}

# ------------------------------------------------------------------
# Shared fixtures. Field ORDER, escaping and the IPv4/IPv6 quirk are copied
# from real fleet output captured 2026-09-04; the identifiers in them are
# synthetic. Device names, MACs and the HomeKit instance id are the kind of
# thing docs/local/ exists for, and a test needs the shape, not the values.
# ------------------------------------------------------------------

# `ss -ltn` on dockassist. HA's bridges are 21064-21066.
cat > "$FIX/ss" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      100          0.0.0.0:21066      0.0.0.0:*
LISTEN 0      100          0.0.0.0:21065      0.0.0.0:*
LISTEN 0      100          0.0.0.0:21064      0.0.0.0:*
LISTEN 0      4096       127.0.0.1:18554      0.0.0.0:*
LISTEN 0      128          0.0.0.0:8123       0.0.0.0:*
LISTEN 0      128          0.0.0.0:22         0.0.0.0:*
LISTEN 0      100             [::]:21066         [::]:*
LISTEN 0      128             [::]:8123          [::]:*
EOF

cat > "$FIX/ip_addr_eth0" <<'EOF'
2: eth0    inet 10.30.100.100/24 brd 10.30.100.255 scope global dynamic noprefixroute eth0\       valid_lft 7167sec preferred_lft 7167sec
EOF

# ==================================================================
printf '\n1. healthy: bridges advertise the host address on eth0\n'
# ==================================================================
cat > "$FIX/ip_link" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
EOF

# Note the IPv6-marked rows carrying IPv4 addresses — that quirk is real.
cat > "$FIX/avahi" <<'EOF'
+;eth0;IPv6;HASS\032Bridge\032AAAAAA;_hap._tcp;local
=;eth0;IPv6;HASS\032Bridge\032AAAAAA;_hap._tcp;local;hassbridge-hap.local;10.30.100.100;21064;"sf=0" "md=HASS Bridge"
=;eth0;IPv4;HASS\032Bridge\032AAAAAA;_hap._tcp;local;hassbridge-hap.local;10.30.100.100;21064;"sf=0" "md=HASS Bridge"
=;eth0;IPv6;Lounge\032TV\032BBBBBB;_hap._tcp;local;hassbridge-hap.local;10.30.100.100;21066;"sf=0" "md=Lounge TV"
=;eth0;IPv4;Lounge\032TV\032BBBBBB;_hap._tcp;local;hassbridge-hap.local;10.30.100.100;21066;"sf=0" "md=Lounge TV"
=;eth0;IPv4;RemoteSpeaker\032DDDDDD;_hap._tcp;local;remotespeaker.local;10.30.100.101;62946;"md=RemoteSpeaker"
=;eth0;IPv4;Remote\032Bridge\032EEEEEE;_hap._tcp;local;remotebridge.local;10.30.100.244;80;"md=Remote Bridge"
EOF

out=$(run_check); rc=$?
if [ "$rc" -eq 0 ]; then pass "exits 0"; else fail "expected exit 0, got $rc"; fi
case "$out" in
    *"2 HomeKit bridge(s) advertising a routable address"*)
        pass "counts 2 bridges, deduping the IPv4/IPv6 row pair" ;;
    *)  fail "expected 2 deduped bridges; got: $out" ;;
esac
case "$out" in
    *RemoteSpeaker*|*'Remote\032Bridge'*|*"Remote Bridge"*) fail "remote accessory treated as ours: $out" ;;
    *)                pass "remote accessories on 62946 and 80 ignored — not our ports" ;;
esac

# ==================================================================
printf '\n2. THE OUTAGE: bridges on docker0 172.17.0.1, docker0 state DOWN\n'
# ==================================================================
# docker0 as the kernel reported it with no containers attached: IFF_UP is set
# in the flags, operstate is DOWN. `ip link show up` MATCHES this line.
cat > "$FIX/ip_link" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default\    link/ether 02:42:1a:2b:3c:4d brd ff:ff:ff:ff:ff:ff
EOF
cat > "$FIX/ip_addr_docker0" <<'EOF'
3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\       valid_lft forever preferred_lft forever
EOF
cat > "$FIX/avahi" <<'EOF'
=;docker0;IPv4;HASS\032Bridge\032AAAAAA;_hap._tcp;local;hassbridge-hap.local;172.17.0.1;21064;"sf=0" "md=HASS Bridge"
=;docker0;IPv4;Lounge\032TV\032BBBBBB;_hap._tcp;local;hassbridge-hap.local;172.17.0.1;21066;"sf=0" "md=Lounge TV"
=;docker0;IPv4;Lounge\032TV\032CCCCCC;_hap._tcp;local;hassbridge-hap.local;172.17.0.1;21065;"sf=0" "md=Lounge TV"
=;eth0;IPv4;RemoteSpeaker\032DDDDDD;_hap._tcp;local;remotespeaker.local;10.30.100.101;62946;"md=RemoteSpeaker"
EOF

out=$(run_check); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "exits 1 — the outage is DETECTED"
else
    fail "MISSED THE OUTAGE: expected exit 1, got $rc — $out"
fi
case "$out" in
    *"3 HomeKit bridge(s) advertising an address this host does not hold"*)
        pass "names all three bridges" ;;
    *)  fail "expected all 3 bridges reported; got: $out" ;;
esac
case "$out" in
    *172.17.0.1*) pass "reports the offending address" ;;
    *)            fail "offending address not in message: $out" ;;
esac
case "$out" in
    *10.30.100.100*) pass "reports where the host IS reachable" ;;
    *)               fail "did not report the real address: $out" ;;
esac

# ==================================================================
printf '\n3. the operstate trap: a down interface must not launder an address\n'
# ==================================================================
# Same fixtures as case 2. The only reason that case fails is that docker0's
# 172.17.0.1 is NOT in the truth set. Assert that directly, because every
# obvious way of writing the collector — `ip addr show up`, `ip link show up`,
# or plain `ip addr show scope global` — would have included it and turned
# case 2 green.
addrs=$(cd "$WORK" && sh -c '
    for iface in $(ip -o link show | sed -n "s/^[0-9]*: \([^:@]*\)[@:].*state UP .*/\1/p"); do
        ip -o addr show dev "$iface" scope global | awk "{for(i=1;i<=NF;i++) if(\$i==\"inet\"||\$i==\"inet6\"){split(\$(i+1),a,\"/\"); print a[1]}}"
    done')
case "$addrs" in
    *172.17.0.1*) fail "docker0 address leaked into the truth set: $addrs" ;;
    *)            pass "172.17.0.1 excluded — operstate DOWN, not merely IFF_UP" ;;
esac
case "$addrs" in
    *10.30.100.100*) pass "eth0 address kept" ;;
    *)               fail "eth0 address missing from truth set: $addrs" ;;
esac

# ==================================================================
printf '\n4. an empty browse is reported, not paged\n'
# ==================================================================
cat > "$FIX/ip_link" <<'EOF'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
EOF
rm -f "$FIX/ip_addr_docker0"
: > "$FIX/avahi"

out=$(run_check); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "exits 0 — multicast luck does not page"
else
    fail "expected exit 0 on empty browse, got $rc"
fi
case "$out" in
    *"no _hap._tcp records found"*) pass "says so in the log" ;;
    *) fail "empty browse not reported: $out" ;;
esac

# ==================================================================
printf '\n5. avahi-daemon down is a hard fault\n'
# ==================================================================
out=$(SYSTEMCTL_RC=3 run_check); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "exits 1 when avahi-daemon is inactive"
else
    fail "expected exit 1, got $rc"
fi

# ==================================================================
printf '\n6. no routable address at all is a fault, not a pass\n'
# ==================================================================
cat > "$FIX/ip_link" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
EOF
out=$(run_check); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "exits 1 rather than silently passing"
else
    fail "expected exit 1, got $rc"
fi

# ==================================================================
printf '\n7. a stale record that clears on recheck must NOT page\n'
# ==================================================================
# The restart window: avahi still holds the pre-restart record on the first
# browse, the correct one by the second. This is the false positive the
# bounded recheck exists to absorb.
cat > "$FIX/ip_link" <<'EOF'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
EOF
cat > "$FIX/avahi.1" <<'EOF'
=;docker0;IPv4;HASS\032Bridge\032AAAAAA;_hap._tcp;local;h-hap.local;172.17.0.1;21064;"md=HASS Bridge"
EOF
cat > "$FIX/avahi" <<'EOF'
=;eth0;IPv4;HASS\032Bridge\032AAAAAA;_hap._tcp;local;h-hap.local;10.30.100.100;21064;"md=HASS Bridge"
EOF

out=$(run_check); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "exits 0 — transient absorbed"
else
    fail "restart window paged: expected 0, got $rc — $out"
fi
case "$out" in
    *"settled after"*) pass "says it settled, so the absorption is visible" ;;
    *) fail "absorbed silently — no 'settled after' note: $out" ;;
esac
rm -f "$FIX/avahi.1"

# ==================================================================
printf '\n8. a PERSISTENT wrong address still pages after every recheck\n'
# ==================================================================
# The dangerous direction from service_recheck_test: retrying must not be a
# way of never reporting. Same bad record on every browse.
cat > "$FIX/ip_link" <<'EOF'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP mode DEFAULT group default qlen 1000\    link/ether aa:bb:cc:00:00:01 brd ff:ff:ff:ff:ff:ff
3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN mode DEFAULT group default\    link/ether 02:42:1a:2b:3c:4d brd ff:ff:ff:ff:ff:ff
EOF
cat > "$FIX/avahi" <<'EOF'
=;docker0;IPv4;HASS\032Bridge\032AAAAAA;_hap._tcp;local;h-hap.local;172.17.0.1;21064;"md=HASS Bridge"
EOF

out=$(run_check); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "exits 1 — retry did not launder the fault"
else
    fail "PERSISTENT FAULT SWALLOWED BY RETRY: got $rc — $out"
fi
case "$out" in
    *"checks over"*) pass "message states it survived the recheck window" ;;
    *) fail "no recheck window in message: $out" ;;
esac

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   all checks passed\n\n'
    exit 0
fi
printf '   %s check(s) failed\n\n' "$failures"
exit 1
