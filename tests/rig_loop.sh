#!/bin/sh
# One command: create -> converge -> verify -> destroy, against a disposable
# test container. Runs ON THE WORKBENCH (TODO 3b, docs/TESTING_GOALS.md goal 1).
#
#   tests/rig_loop.sh                      # site.yml against CT 199 (Debian 13)
#   tests/rig_loop.sh --deb12              # ... against CT 198 (Debian 12, the Pis)
#   tests/rig_loop.sh path/to/playbook.yml # any playbook, same loop
#   tests/rig_loop.sh --keep               # leave the container up to poke at
#
# Why it exists, and why here: a cloud session can clone, edit and open a PR.
# What it can never do is reach this LAN and prove a change converges on a real
# host. That is the one thing the workbench has that a cloud session does not,
# so this loop is what makes the box more than a worse cloud session.
#
# What a PASS means: the playbook converged a FRESH container with failed=0,
# and a second run, on fresh SSH connections, reported changed=0. It proves
# "this deploys", never "this works" — the rig's vault is fake, so nothing
# reaches Slack, healthchecks.io or Home Assistant. See TESTING_GOALS.md.
#
# Steps:
#   1. destroy, then create, over the rig_ct grant (ssh rig_runner@cwwk). The
#      container is always fresh: converging one left over from an earlier run
#      would prove nothing about a new host. `create` installs this box's key.
#   2. check the host answering at that address IS the test container
#   3. converge, via ansible/inventory_test/ ONLY
#   4. converge again; require changed=0
#   5. destroy — always, on success, failure or Ctrl-C, unless --keep
#
# Exit 0 only when every step passed AND the container was destroyed.

set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
INVENTORY="$REPO/ansible/inventory_test/hosts.yml"

# The hypervisor, by address: the workbench has no mDNS resolver.
HYPERVISOR=10.30.40.51
RIG_USER=rig_runner
RIG_KEY="$HOME/.ssh/rig_runner_ed25519"

# The only two targets. Literal, so there is no way to aim this at anything
# else: the VMIDs are the only two the rig_ct grant accepts, and the hostnames
# are what step 2 insists on finding.
VMID=199
HOST=testlxc
KEEP=0
PLAYBOOK="$REPO/ansible/playbooks/site.yml"

say()  { printf '\n\033[0;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33mwarn:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --deb12) VMID=198; HOST=test-deb12 ;;
        --keep)  KEEP=1 ;;
        -h|--help) usage 0 ;;
        -*) warn "unknown option: $1"; usage 1 ;;
        *)  PLAYBOOK="$1" ;;
    esac
    shift
done

[ -f "$PLAYBOOK" ] || die "no such playbook: $PLAYBOOK"
PLAYBOOK=$(cd "$(dirname "$PLAYBOOK")" && pwd)/$(basename "$PLAYBOOK")
[ -r "$RIG_KEY" ] || die "no $RIG_KEY — this runs on the workbench, as the agent account (see docs/WORKBENCH.md)"
command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not on PATH — converge the workbench role"

# Several Remote Control sessions share this box. Two loops on one VMID would
# destroy each other's container mid-converge, and the failure would look like
# a playbook bug. mkdir is atomic; the trap removes it.
LOCK="/tmp/rig_loop.$VMID.lock"
mkdir "$LOCK" 2>/dev/null \
    || die "CT $VMID is in use by another rig_loop (or a stale lock: rmdir $LOCK)"

RUN_DIR=$(mktemp -d /tmp/rig.XXXXXX)

rig() {
    ssh -i "$RIG_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "$RIG_USER@$HYPERVISOR" "$1"
}

DESTROYED=0
cleanup() {
    rc=$?
    trap - EXIT INT TERM
    if [ "$KEEP" = 1 ]; then
        warn "--keep: CT $VMID ($HOST) left running. Destroy it with: ssh -i $RIG_KEY $RIG_USER@$HYPERVISOR 'destroy $VMID'"
    elif rig "destroy $VMID"; then
        DESTROYED=1
    else
        # A leaked container is a failure even when the converge passed: the
        # next run's `create` would say "exists" and test nothing.
        warn "DESTROY FAILED — CT $VMID may still exist"
        rc=1
    fi
    rm -rf "${RUN_DIR:?}"
    rmdir "$LOCK" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        say "PASS — $HOST converged from fresh and reported changed=0 on the second run$([ "$DESTROYED" = 1 ] && echo '; container destroyed')"
    else
        printf '\n\033[0;31m==> FAIL\033[0m (exit %s)%s\n' "$rc" \
            "$([ "$DESTROYED" = 1 ] && echo ' — container destroyed')" >&2
    fi
    exit "$rc"
}
# dash runs an EXIT trap on `exit`, not on death by signal — so turn the
# signals into exits, or Ctrl-C would leak the container.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every Ansible run below uses the rig's own settings, not the laptop's:
#   * no vault password — the rig's vault is plaintext; see the script for why
#     this still has to be set, and how it fails closed on the fleet vault
#   * an in-memory fact cache — ansible.cfg caches facts for an hour, and a
#     recreated container would otherwise inherit its predecessor's
#   * no retry files
export ANSIBLE_VAULT_PASSWORD_FILE="$REPO/tests/lib/no_vault_pass.sh"
export ANSIBLE_CACHE_PLUGIN=memory
export ANSIBLE_RETRY_FILES_ENABLED=false
cd "$REPO"

# Each pass gets its own SSH control socket. ansible.cfg keeps a master open
# for 10 minutes, and a live master keeps serving a session whose key has just
# been removed — a run that locked itself out would look healthy until the
# socket expired. A fresh socket per pass means pass 2 authenticates anew, so
# changed=0 also proves the key survived pass 1.
ssh_args_for() {
    echo "-o ControlMaster=auto -o ControlPersist=60s -o ControlPath=$RUN_DIR/cm-$1-%C"
}

# ------------------------------------------------------------------
say "Fresh CT $VMID ($HOST): destroy, then create"
rig "destroy $VMID"
rig "create $VMID"

# A recreated container has a new host key; the old entry would fail the
# connection rather than protect it.
IP=$(ansible-inventory -i "$INVENTORY" --host "$HOST" 2>/dev/null \
    | sed -n 's/.*"ansible_host": *"\([0-9.]*\)".*/\1/p')
[ -n "$IP" ] || die "could not read ansible_host for $HOST from $INVENTORY"
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

# ------------------------------------------------------------------
say "Checking that $IP is the test container"
# Asked through Ansible with the inventory's own key and user, so this also
# proves the connection every later step depends on.
_name=""
_try=0
while [ "$_try" -lt 30 ]; do
    # Not `-o`: the oneline callback is deprecated and goes in ansible-core
    # 2.23. The default format is "<host> | CHANGED | rc=0 >>" then stdout.
    _name=$(ANSIBLE_SSH_ARGS="$(ssh_args_for probe)" \
        ansible "$HOST" -i "$INVENTORY" -m ansible.builtin.command -a hostname 2>/dev/null \
        | sed -n '/ | CHANGED | rc=0 >>$/{n;p;}') || true
    [ -n "$_name" ] && break
    _try=$((_try + 1))
    sleep 2
done
[ -n "$_name" ] || die "$HOST ($IP) never answered over SSH"
case "$_name" in
    "$HOST") : ;;
    *) die "$IP answers as '$_name', not '$HOST'. Refusing to converge it." ;;
esac
say "$IP is $_name"

# ------------------------------------------------------------------
# Runs the playbook, streaming its output, and leaves the exit code and the
# recap line for $HOST behind. POSIX sh has no pipefail, so the exit code is
# carried out of the pipe in a file — and captured with `||`, because the
# brace group inherits `set -e` and would otherwise exit before recording it.
converge() {
    _pass=$1
    _log="$RUN_DIR/converge-$_pass.log"
    say "Converge $_pass: $(basename "$PLAYBOOK") -> $HOST"
    { _rc=0
      ANSIBLE_SSH_ARGS="$(ssh_args_for "$_pass")" \
          ansible-playbook -i "$INVENTORY" --limit "$HOST" "$PLAYBOOK" || _rc=$?
      echo "$_rc" > "$RUN_DIR/rc-$_pass"; } 2>&1 | tee "$_log"
    RC=$(cat "$RUN_DIR/rc-$_pass")
    # No recap line is a failure, not a pass: a syntax error, or a playbook
    # whose hosts never matched $HOST, prints none.
    RECAP=$(grep -E "^${HOST}[[:space:]]+: ok=" "$_log" | tail -1 || true)
}

recap_val() {
    printf '%s\n' "$RECAP" | sed -n "s/.*[[:space:]]$1=\([0-9][0-9]*\).*/\1/p"
}

check_pass() {
    [ -n "$RECAP" ] || die "converge $1: no PLAY RECAP line for $HOST (exit $RC)"
    _failed=$(recap_val failed)
    _unreach=$(recap_val unreachable)
    if [ "$RC" -ne 0 ] || [ "${_failed:-x}" != 0 ] || [ "${_unreach:-x}" != 0 ]; then
        die "converge $1 failed: exit $RC, failed=${_failed:-?}, unreachable=${_unreach:-?}"
    fi
}

converge 1
check_pass 1

converge 2
check_pass 2
_changed=$(recap_val changed)
if [ "${_changed:-x}" != 0 ]; then
    # Name the tasks, so the report says what is not idempotent rather than
    # only that something is.
    warn "tasks that changed on the second run:"
    awk '/^TASK \[/ { t = $0; sub(/ \*+$/, "", t) } /^changed: / { print "  " t }' \
        "$RUN_DIR/converge-2.log" | sort -u >&2
    die "converge 2 reported changed=${_changed:-?} — not idempotent"
fi
say "Converge 2: changed=0"
