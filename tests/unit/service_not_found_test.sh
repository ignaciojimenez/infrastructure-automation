#!/bin/sh
# A CRITICAL_SERVICES name that is no systemd unit is reported as "no such
# unit" at once, not re-checked and called "not running". `systemctl` is stubbed.
# shellcheck disable=SC2329  # svc_line, has and polls are invoked through check()
set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { # check <description> <command...>
    d=$1; shift
    if "$@"; then printf '   ✓ %s\n' "$d"; else printf '   ✗ %s\n' "$d"; failures=$((failures + 1)); fi
}

mkdir -p "$WORK/bin"
COUNT="$WORK/count"
# ghostsvc: no such unit. downsvc: real but inactive. upsvc: running.
cat > "$WORK/bin/systemctl" <<STUB
#!/bin/sh
case "\$1" in
show) [ "\$5" = ghostsvc ] && echo not-found || echo loaded ;;
is-active) [ "\$2" = upsvc ] || [ "\$2" = unattended-upgrades.service ] || echo x >> "$COUNT"
    [ "\$2" = upsvc ]; exit \$? ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/systemctl"
PATH="$WORK/bin:$PATH"
export PATH NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export OS_TYPE=debian SERVICE_RECHECK_ATTEMPTS=3 SERVICE_RECHECK_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent MAINTENANCE_DIR="$WORK/no-windows"

run_case() { : > "$COUNT"; CRITICAL_SERVICES="$1" sh "$SCRIPT" > "$WORK/out" 2>&1; }
svc_line() { sed -n '/Critical Services/,/^$/p' "$WORK/out" | sed 's/\x1b\[[0-9;]*m//g'; }
has() { svc_line | grep -q "$1"; }
polls() { [ "$(wc -l < "$COUNT")" -eq "$1" ]; }

printf '\n── check_services unknown unit\n'
run_case ghostsvc
check "a name that is no unit reads as no such unit" \
    has '❌ Service ghostsvc: no such unit (check the name in critical_services)'
check "and is not re-checked" polls 0
run_case downsvc
check "a real unit that is down still reports not running" has '❌ Service downsvc: not running'
check "after its retries" polls 3
run_case upsvc
check "a running unit still reports running" has '✅ Service upsvc: running'

printf '\n'
[ "$failures" -eq 0 ] && { printf '✅ check_services unknown unit: all checks passed\n'; exit 0; }
printf '❌ check_services unknown unit: %s check(s) failed\n' "$failures"
exit 1
