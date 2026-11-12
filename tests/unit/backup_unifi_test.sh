#!/bin/sh
# backup_unifi.sh hands do_backup the newest .unf, from the host (standalone)
# or from UniFi OS Server's container (--unifi-os), and fails when it cannot.
#
#   tests/unit/backup_unifi_test.sh
#
# sudo, podman and do_backup are stubbed. The podman stub runs the command
# locally, so the test proves the routing (every read goes through
# `sudo -u uosserver podman exec uosserver`), not that the container holds
# the backups at that path. That is checked on the VM (PER-127 runbook).
# shellcheck disable=SC2317,SC2329  # helpers are invoked through check()
set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { # check <description> <command...>
    d=$1; shift
    if "$@"; then printf '   ✓ %s\n' "$d"; else printf '   ✗ %s\n' "$d"; failures=$((failures + 1)); fi
}

# The script finds do_backup at $(dirname "$0")/../common_scripts/do_backup.
mkdir -p "$WORK/net" "$WORK/common_scripts" "$WORK/bin" "$WORK/backups"
cp "$REPO_ROOT/scripts/services/network/backup_unifi.sh" "$WORK/net/"
CALLS="$WORK/calls"

cat > "$WORK/common_scripts/do_backup" <<STUB
#!/bin/sh
# Records what it was handed: the archive's members and the recipient.
[ "\$1" = --silent ] && shift
tar -tzf "\$1" | sed 's|^\./||' | grep -v '^$' | sort > "$WORK/archived"
printf '%s\n' "\$2" > "$WORK/recipient"
STUB
cat > "$WORK/bin/sudo" <<STUB
#!/bin/sh
printf 'sudo %s\n' "\$*" >> "$CALLS"
if [ "\$1" = -u ]; then shift 2; fi
exec "\$@"
STUB
cat > "$WORK/bin/podman" <<STUB
#!/bin/sh
[ -f "$WORK/container-down" ] && { echo "Error: container uosserver is not running" >&2; exit 125; }
[ "\$1 \$2" = "exec uosserver" ] || { echo "unexpected podman call: \$*" >&2; exit 2; }
shift 2
exec "\$@"
STUB
chmod +x "$WORK/common_scripts/do_backup" "$WORK/bin/sudo" "$WORK/bin/podman"
PATH="$WORK/bin:$PATH"
export PATH
UNIFI_BACKUP_DIR="$WORK/backups"
export UNIFI_BACKUP_DIR

# Two autobackups a day apart, plus the meta file.
touch -t 202611110300 "$WORK/backups/autobackup_old.unf"
touch -t 202611120300 "$WORK/backups/autobackup_new.unf"
printf '{}' > "$WORK/backups/autobackup_meta.json"

run() { : > "$CALLS"; rm -f "$WORK/archived"; bash "$WORK/net/backup_unifi.sh" --silent --recipient=age1test "$@" > "$WORK/out" 2>&1; }
archived() { [ "$(tr '\n' ' ' < "$WORK/archived" 2>/dev/null)" = "$1" ]; }
all_reads_via_podman() { ! grep -v '^sudo -u uosserver podman exec uosserver ' "$CALLS" | grep -v '^sudo chown\|^sudo rm' | grep -q .; }
no_podman() { ! grep -q podman "$CALLS"; }

printf '\n── backup_unifi.sh: standalone and UniFi OS Server (PER-127)\n'

run
check "standalone: succeeds" grep -q 'backup completed successfully' "$WORK/out"
check "standalone: archives the newest .unf and the meta file" archived 'autobackup_meta.json autobackup_new.unf '
check "standalone: reads the host directory, no podman" no_podman
check "the age recipient reaches do_backup" grep -qx age1test "$WORK/recipient"

run --unifi-os
check "UniFi OS: succeeds" grep -q 'backup completed successfully' "$WORK/out"
check "UniFi OS: archives the newest .unf and the meta file" archived 'autobackup_meta.json autobackup_new.unf '
check "UniFi OS: every read goes through podman exec as uosserver" all_reads_via_podman

touch "$WORK/container-down"
run --unifi-os; rc=$?
check "UniFi OS, container down: exits non-zero" [ "$rc" -ne 0 ]
check "UniFi OS, container down: nothing handed to do_backup" [ ! -f "$WORK/archived" ]
rm -f "$WORK/container-down"

rm -f "$WORK/backups"/*.unf
run --unifi-os; rc=$?
check "no .unf: exits non-zero" [ "$rc" -ne 0 ]
check "no .unf: says so" grep -q 'No backup files found' "$WORK/out"

printf '\n'
[ "$failures" -eq 0 ] && { printf '✅ backup_unifi: all checks passed\n'; exit 0; }
printf '❌ backup_unifi: %s check(s) failed\n' "$failures"
cat "$WORK/out"
exit 1
