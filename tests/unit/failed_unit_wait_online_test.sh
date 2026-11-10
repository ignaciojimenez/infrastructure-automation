#!/bin/sh
# Regression test: a latched NetworkManager-wait-online.service failure must not
# make check_failed_units alert, while any other failed unit still must.
#
#   tests/unit/failed_unit_wait_online_test.sh
#
# vinylstreamer (Wi-Fi only) reboots with wlan0 late, the wait-online oneshot
# times out and stays "failed", and the health check paged on it (PER-165).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_failed_units ignores wait-online\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

main_line=$(grep -nE '^check_uptime([^(]|$)' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$main_line" ]; then
    printf '   ✗ could not locate the main call section (no check_uptime call line)\n'
    exit 1
fi
sed -n "1,$((main_line - 1))p" "$SCRIPT" > "$WORK/funcs.sh"

if ! grep -q '^check_failed_units()' "$WORK/funcs.sh"; then
    printf '   ✗ check_failed_units() is not defined in %s\n' "$SCRIPT"
    exit 1
fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
[ -r "$FAILED_FIXTURE" ] && cat "$FAILED_FIXTURE"
exit 0
EOF
chmod +x "$WORK/bin/systemctl"

cat > "$WORK/run.sh" <<'EOF'
. "$1" >/dev/null 2>&1
OS_TYPE=debian
check_failed_units >/dev/null 2>&1
echo $?
EOF

check() {
    got=$(PATH="$WORK/bin:$PATH" FAILED_FIXTURE="$WORK/failed.txt" sh "$WORK/run.sh" "$WORK/funcs.sh" 2>/dev/null)
    if [ "$got" = "$1" ]; then
        pass "$2 -> $1"
    else
        fail "$2 -> expected $1, got ${got:-<none>}"
    fi
}

: > "$WORK/failed.txt"
check 0 "no failed units"

printf 'NetworkManager-wait-online.service loaded failed failed Network Manager Wait Online\n' > "$WORK/failed.txt"
check 0 "only wait-online failed"

printf 'fail2ban.service loaded failed failed Fail2Ban\n' > "$WORK/failed.txt"
check 1 "other unit failed"

printf 'NetworkManager-wait-online.service loaded failed failed Wait Online\nfail2ban.service loaded failed failed Fail2Ban\n' > "$WORK/failed.txt"
check 1 "wait-online does not mask another failed unit"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   All checks passed.\n\n'
    exit 0
fi
printf '   %d check(s) failed.\n\n' "$failures"
exit 1
