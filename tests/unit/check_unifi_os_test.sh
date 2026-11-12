#!/bin/sh
# check_unifi_os.sh: healthy is quiet, each broken layer is named, one restart
# is tried, and a fix is reported as fixed. systemctl, sudo, podman and curl
# are stubbed; each layer's health is a file the stubs read.
#
#   tests/unit/check_unifi_os_test.sh
#
# The probes themselves (port 11443, the inform port, the unit and container
# names) are checked on the VM by forcing each failure (PER-127 runbook).
# shellcheck disable=SC2317,SC2329  # helpers are invoked through check()
set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/check_unifi_os.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { # check <description> <command...>
    d=$1; shift
    if "$@"; then printf '   ✓ %s\n' "$d"; else printf '   ✗ %s\n' "$d"; failures=$((failures + 1)); fi
}

mkdir -p "$WORK/bin" "$WORK/down"
D="$WORK/down"
# A file in $D marks that layer down. `heals` makes a restart clear them all.
cat > "$WORK/bin/sudo" <<STUB
#!/bin/sh
if [ "\$1" = -u ]; then shift 2; fi
exec "\$@"
STUB
cat > "$WORK/bin/systemctl" <<STUB
#!/bin/sh
case "\$1" in
is-active) [ ! -f "$D/service" ] ;;
restart) echo restart >> "$WORK/restarts"; [ -f "$D/heals" ] && rm -f "$D"/* ; exit 0 ;;
esac
STUB
cat > "$WORK/bin/podman" <<STUB
#!/bin/sh
[ -f "$D/container" ] && echo false || echo true
STUB
cat > "$WORK/bin/curl" <<STUB
#!/bin/sh
for a in "\$@"; do last=\$a; done
case "\$last" in
*11443*) [ ! -f "$D/web" ] ;;
*inform*) [ -f "$D/inform" ] && printf 000 || printf 400 ;;
esac
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"
export PATH UNIFI_OS_RESTART_WAIT=0

run() { rm -f "$D"/* "$WORK/restarts"; for f in "$@"; do touch "$D/$f"; done; bash "$SCRIPT" > "$WORK/out" 2>&1; rc=$?; }
says() { grep -q "$1" "$WORK/out"; }
restarts() { [ "$(cat "$WORK/restarts" 2>/dev/null | wc -l | tr -d ' ')" -eq "$1" ]; }

printf '\n── check_unifi_os.sh (PER-127)\n'

run
check "healthy: exit 0" [ "$rc" -eq 0 ]
check "healthy: says so" says 'running normally'
check "healthy: no restart" restarts 0

for layer in service container web inform; do
    run "$layer"
    check "$layer down, restart does not help: exit 1" [ "$rc" -eq 1 ]
    check "$layer down: one restart, no more" restarts 1
done
run service;   check "service down is named"   says 'uosserver service is not active'
run container; check "container down is named" says 'uosserver container is not running'
run web;       check "console down is named"   says 'console does not answer'
run inform;    check "inform port down is named" says "APs' inform port"

run inform heals
check "fixed by the restart: exit 0" [ "$rc" -eq 0 ]
check "fixed by the restart: reported as fixed, with what was found" says 'Found: Network application does not answer'

printf '\n'
[ "$failures" -eq 0 ] && { printf '✅ check_unifi_os: all checks passed\n'; exit 0; }
printf '❌ check_unifi_os: %s check(s) failed\n' "$failures"
cat "$WORK/out"
exit 1
