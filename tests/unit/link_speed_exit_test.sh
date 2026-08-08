#!/bin/sh
# Regression test: check_link_speed must COUNT its faults and RETURN the total.
#
# Runs on the laptop — no container, no network, no NIC. The function
# definitions are extracted from system_health_check.sh, `ifconfig` is stubbed
# for the FreeBSD path, and a fixture tree stands in for /sys/class/net on the
# Linux path.
#
#   tests/unit/link_speed_exit_test.sh
#
# The bug this pins (2026-08-07): check_link_speed was written against the
# HEALTH_ISSUE_FILE tally — print_status "error" appended a line, and the script
# counted lines at the end. The merged system_health_check.sh uses the other
# convention: each check counts locally and returns, and the runner sums the
# return values. Under that convention a function that reports only via
# print_status contributes NOTHING. check_link_speed would have printed every
# red ❌ correctly and never alerted — which is the exact bug it was written to
# catch, reintroduced by the merge that was supposed to deliver it.
#
# So this asserts the one property that makes the check real: a forced fault
# must change the RETURN VALUE. Printing is not detection.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_link_speed exit convention\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

# ------------------------------------------------------------------
# Extract the function definitions, stopping before the main call section.
# Sourcing the whole script would run every check against this machine.
# ------------------------------------------------------------------
# Match the CALL, not the definition, in either shape the script takes:
#   check_uptime                                        (pre-aggregation)
#   check_uptime;         total_issues=$((...))         (post-aggregation)
# and never `check_uptime() {`. `\b` is not portable to BSD grep, so this uses
# POSIX ERE: end-of-line, or any next character that is not an opening paren.
#
# The narrow '^check_uptime$' this replaces matched only the first shape, so the
# test refused to run against the merged script — i.e. against the one file it
# will actually guard. Found by review, 2026-08-08, before it could matter.
main_line=$(grep -nE '^check_uptime([^(]|$)' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$main_line" ]; then
    printf '   ✗ could not locate the main call section (no check_uptime call line)\n'
    printf '     The extraction below would silently source the whole script.\n'
    exit 1
fi
sed -n "1,$((main_line - 1))p" "$SCRIPT" > "$WORK/funcs.sh"

# Fail loudly rather than skipping. A test that quietly does nothing when its
# subject is absent is the same class of defect it is here to catch.
if ! grep -q '^check_link_speed()' "$WORK/funcs.sh"; then
    printf '   ✗ check_link_speed() is not defined in %s\n' "$SCRIPT"
    printf '     If the function was lifted onto another branch, move this test with it.\n'
    exit 1
fi

# ------------------------------------------------------------------
# FreeBSD path — ifconfig stubbed
# ------------------------------------------------------------------
cat > "$WORK/freebsd.sh" <<'EOF'
# Sourcing runs the script's prologue, which prints a banner. Suppress it so
# the only thing on stdout is the exit code under test.
. "$1" >/dev/null 2>&1
OS_TYPE=freebsd
ifconfig() {
    if [ "$1" = "-l" ]; then echo "$IFACES"; return; fi
    case "$1" in
        good) printf '\tstatus: active\n\tmedia: Ethernet 10Gbase-Twinax <full-duplex>\n' ;;
        gig)  printf '\tstatus: active\n\tmedia: Ethernet 1000baseT <full-duplex>\n' ;;
        slow) printf '\tstatus: active\n\tmedia: Ethernet 100baseTX <full-duplex>\n' ;;
        half) printf '\tstatus: active\n\tmedia: Ethernet 1000baseT <half-duplex>\n' ;;
        down) printf '\tstatus: no carrier\n' ;;
    esac
}
IFACES="$2"
check_link_speed >/dev/null 2>&1
echo $?
EOF

check_bsd() {
    got=$(sh "$WORK/freebsd.sh" "$WORK/funcs.sh" "$1" 2>/dev/null)
    if [ "$got" = "$2" ]; then
        pass "freebsd [$1] -> $2"
    else
        fail "freebsd [$1] -> expected $2, got ${got:-<none>}"
    fi
}

check_bsd "good"      0
check_bsd "gig"       0
check_bsd "slow"      1        # 100baseTX — below gigabit
check_bsd "half"      1        # half-duplex at gigabit
check_bsd "slow half" 2        # both faults counted, not collapsed
check_bsd "good slow" 1        # a healthy NIC must not mask a faulty one
check_bsd "down"      0        # no active interface is advisory, not a fault

# ------------------------------------------------------------------
# Linux path — fixture tree via SYSFS_NET
# ------------------------------------------------------------------
mknic() {
    d="$WORK/sys/$1"; mkdir -p "$d"
    [ "$2" = "virtual" ] || mkdir -p "$d/device"
    printf '%s\n' "$3" > "$d/operstate"
    printf '%s\n' "$4" > "$d/speed"
    printf '%s\n' "$5" > "$d/duplex"
    [ "${6:-}" = "wifi" ] && mkdir -p "$d/wireless"
    return 0
}

cat > "$WORK/linux.sh" <<'EOF'
. "$1" >/dev/null 2>&1
OS_TYPE=linux
SYSFS_NET="$2"
export SYSFS_NET
check_link_speed >/dev/null 2>&1
echo $?
EOF

check_linux() {
    got=$(sh "$WORK/linux.sh" "$WORK/funcs.sh" "$WORK/sys" 2>/dev/null)
    if [ "$got" = "$1" ]; then
        pass "linux $2 -> $1"
    else
        fail "linux $2 -> expected $1, got ${got:-<none>}"
    fi
}

rm -rf "$WORK/sys"; mknic eth0 real up 1000 full
check_linux 0 "[1000/full]"

rm -rf "$WORK/sys"; mknic eth0 real up 100 full
check_linux 1 "[100/full — below gigabit]"

rm -rf "$WORK/sys"; mknic eth0 real up 1000 half
check_linux 1 "[1000/half]"

rm -rf "$WORK/sys"; mknic eth0 real up 100 full; mknic eth1 real up 1000 half
check_linux 2 "[two faults counted]"

rm -rf "$WORK/sys"; mknic eth0 real up 1000 full; mknic eth1 real up 10 half
check_linux 1 "[healthy NIC does not mask a 10M-half one]"

# The finding that motivated the whole check: a switch port at 10M-half.
rm -rf "$WORK/sys"; mknic eth0 real up 10 half
check_linux 1 "[10M-half — network finding 10]"

# A veth has no device symlink. LXC veths report 10000 regardless of the real
# link, so counting them would make every container permanently healthy.
rm -rf "$WORK/sys"; mknic veth0 virtual up 10 half
check_linux 0 "[veth ignored — no device symlink]"

# Wireless rates vary with signal and are not graded.
rm -rf "$WORK/sys"; mknic wlan0 real up 54 half wifi
check_linux 0 "[wireless not graded]"

# A down interface is not a fault.
rm -rf "$WORK/sys"; mknic eth0 real down 10 half
check_linux 0 "[operstate down ignored]"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   All checks passed.\n\n'
    exit 0
fi
printf '   %d check(s) failed.\n\n' "$failures"
exit 1
