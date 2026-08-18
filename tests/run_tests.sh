#!/bin/sh
# Test runner for the monitoring scripts.
#
# Stages the repo's scripts onto a disposable Debian LXC and runs each case
# there. The cases force real faults — a full disk, a stopped service, a
# blackholed gateway — so they must not run against anything you care about.
#
#   tests/run_tests.sh --target 10.30.40.205
#   tests/run_tests.sh --target 10.30.40.205 --case disk_full --verbose
#
# See docs/TEST_CONTAINER.md for how to create the target.
#
# ⚠️ KNOWN BLIND SPOT: this connects as root, because the cases fill disks and
# stop services. The fleet's checks run as the infrastructure user under cron,
# so anything that fails only for an unprivileged user is invisible here.
# Demonstrated 2026-08-04 on CT 199: check_auto_upgrades prints "Upgrade log not
# found" as `choco` and "Last upgrade: <date>" as root, same script, same host,
# same minute — /var/log/unattended-upgrades is root:adm 0750 and the user is
# not in adm. That is a real fleet bug on 3 of 7 hosts and this suite cannot see
# it. Use `tests/sandbox.sh --run <script>` (which connects as the
# infrastructure user) whenever a check touches a file it does not own.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TARGET=""
CASE_FILTER=""
VERBOSE=0
SSH_KEY="${SSH_KEY:-$HOME/.ssh/read_agent_ed25519}"
SSH_USER="${SSH_USER:-root}"

# Staging root, per connecting user.
#
# ⚠️ Was a hardcoded /opt/uut, which only root can create. That made running as
# an unprivileged user impossible at the FIRST step — the suite could not even
# stage, let alone reveal a permission fault. Found 2026-08-18 by trying it:
# `rm: cannot remove '/opt/uut/tests': Permission denied`.
#
# Per-user rather than one shared path, so a root run and a user run cannot
# leave each other's root-owned leftovers behind and produce a confusing
# second failure.
UUT_ROOT="${UUT_ROOT:-/tmp/uut-$SSH_USER}"

usage() {
    cat <<'EOF'
Usage: tests/run_tests.sh --target <host-or-ip> [--case <name>] [--verbose]

  --target   Disposable test container (see docs/TEST_CONTAINER.md).
             REQUIRED — there is no default, on purpose.
  --case     Run only cases whose filename contains this substring.
  --verbose  Show each assertion and the script's full output.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --case)   CASE_FILTER="${2:-}"; shift 2 ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$TARGET" ]; then
    printf 'error: --target is required\n\n' >&2
    usage >&2
    exit 2
fi

SSH="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o IdentityAgent=none \
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $SSH_USER@$TARGET"

# ------------------------------------------------------------------
# Refuse to run against anything that looks like a real host.
# These cases stop cron and fill disks; pointing them at dockassist
# would be a self-inflicted outage.
# ------------------------------------------------------------------
remote_hostname=$($SSH 'hostname' 2>/dev/null) || {
    printf 'error: cannot reach %s@%s\n' "$SSH_USER" "$TARGET" >&2
    printf '       check the container is running (docs/TEST_CONTAINER.md)\n' >&2
    exit 1
}

case "$remote_hostname" in
    testlxc*|test-*|*-test) : ;;
    *)
        printf 'error: target hostname is "%s", which is not a recognised test container.\n' "$remote_hostname" >&2
        printf '       These tests deliberately break the host they run on. Refusing.\n' >&2
        printf '       Rename the container to "testlxc" if this really is disposable.\n' >&2
        exit 1
        ;;
esac

printf 'Target: %s (%s)\n' "$remote_hostname" "$TARGET"

# ------------------------------------------------------------------
# Stage the repo under test. tar over ssh rather than rsync — a fresh
# Debian container has tar, and may not have rsync.
# ------------------------------------------------------------------
printf 'Staging scripts to %s:%s ... ' "$remote_hostname" "$UUT_ROOT"
$SSH "rm -rf $UUT_ROOT && mkdir -p $UUT_ROOT" || exit 1
tar -C "$REPO_ROOT" -cf - scripts tests | $SSH "tar -C $UUT_ROOT -xf -" || exit 1
printf 'done\n'

# ------------------------------------------------------------------
# Run the cases
# ------------------------------------------------------------------
total=0
failed=0
failed_names=""

for case_file in "$REPO_ROOT"/tests/cases/*.sh; do
    [ -f "$case_file" ] || continue
    case_name=$(basename "$case_file" .sh)

    if [ -n "$CASE_FILTER" ]; then
        case "$case_name" in
            *"$CASE_FILTER"*) : ;;
            *) continue ;;
        esac
    fi

    total=$((total + 1))
    if $SSH "UUT_ROOT=$UUT_ROOT VERBOSE=$VERBOSE sh $UUT_ROOT/tests/cases/$case_name.sh"; then
        :
    else
        failed=$((failed + 1))
        failed_names="$failed_names $case_name"
    fi
done

printf '\n══════════════════════════════════════\n'
if [ "$total" -eq 0 ]; then
    printf 'No cases matched.\n'
    exit 1
elif [ "$failed" -eq 0 ]; then
    printf 'All %s case(s) passed.\n' "$total"
    exit 0
else
    printf '%s of %s case(s) FAILED:%s\n' "$failed" "$total" "$failed_names"
    exit 1
fi
