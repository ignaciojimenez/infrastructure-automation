#!/bin/sh
# Hands-on access to a disposable test container.
#
# For the case the batch suite does not cover: you are part-way through a change
# and want to try it on something that behaves like a fleet host, without
# touching one.
#
#   tests/sandbox.sh                    # shell in, as the infrastructure user
#   tests/sandbox.sh --root             # ... as root, for the bootstrap path
#   tests/sandbox.sh --deb12            # CT 198 instead of CT 199
#   tests/sandbox.sh --push             # copy the working tree's scripts over
#   tests/sandbox.sh --run system_health_check.sh
#   tests/sandbox.sh --reset            # back to baseline
#   tests/sandbox.sh --status
#
# --push copies what is in your working tree right now, uncommitted included,
# and it does not go through Ansible. That is the point: no playbook run, no
# vault, no commit, just the file on the box in a second so you can run it.
# Use the playbooks when you want to test the *deploy*; use this when you want
# to test the *script*.
#
# See docs/TEST_CONTAINER.md for what these containers are and are not a proxy
# for. tests/run_tests.sh is the batch suite; this is the manual door.

set -eu

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

TARGET="${SANDBOX_TARGET:-10.30.40.205}"
SSH_USER="${SANDBOX_USER:-choco}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/read_agent_ed25519}"
ACTION=shell
RUN_CMD=""

# Mirrors provision_test_container.sh — the set system_health_check.sh probes.
PACKAGES="openssh-server python3 sudo procps iproute2 unattended-upgrades cron fail2ban curl jq"

say()  { printf '\033[0;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m warn:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)   SSH_USER=root; shift ;;
        --deb12)  TARGET=10.30.40.206; shift ;;
        --target) TARGET="${2:?--target needs a host}"; shift 2 ;;
        --push)   ACTION=push; shift ;;
        --reset)  ACTION=reset; shift ;;
        --status) ACTION=status; shift ;;
        --run)    ACTION=run; RUN_CMD="${2:?--run needs a script name}"; shift 2 ;;
        --shell)  ACTION=shell; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

SSH="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o IdentityAgent=none \
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# ------------------------------------------------------------------
# Same guard as run_tests.sh, for the same reason: --reset deletes things and
# --push overwrites them. Pointing either at dockassist would be a self-
# inflicted outage.
# ------------------------------------------------------------------
# -n on every non-interactive ssh: without it ssh reads the script's stdin,
# which silently swallows the answer to the --reset confirmation prompt below.
remote_hostname=$($SSH -n "$SSH_USER@$TARGET" 'hostname' 2>/dev/null) || {
    printf 'error: cannot reach %s@%s\n' "$SSH_USER" "$TARGET" >&2
    printf '       is the container running? see docs/TEST_CONTAINER.md\n' >&2
    exit 1
}

case "$remote_hostname" in
    testlxc*|test-*|*-test) : ;;
    *)
        die "target is '$remote_hostname', not a recognised test container. Refusing."
        ;;
esac

# Where the fleet keeps them, and where the playbooks deploy them.
SCRIPTS_DIR="/home/$SSH_USER/.scripts"
LOGS_DIR="/home/$SSH_USER/.logs"
[ "$SSH_USER" = root ] && { SCRIPTS_DIR=/root/.scripts; LOGS_DIR=/root/.logs; }

case "$ACTION" in

    shell)
        say "$remote_hostname ($TARGET) as $SSH_USER"
        printf '    scripts: %s\n' "$SCRIPTS_DIR"
        printf '    reset with: tests/sandbox.sh --reset\n\n'
        # No command: hand the terminal over.
        exec $SSH -t "$SSH_USER@$TARGET"
        ;;

    push)
        say "Pushing scripts/ from the working tree to $remote_hostname"
        $SSH -n "$SSH_USER@$TARGET" "mkdir -p '$SCRIPTS_DIR' '$LOGS_DIR'"
        # tar rather than rsync: a fresh Debian container has tar and may not
        # have rsync. --strip-components lands scripts/common/x at .scripts/x,
        # which is where deploy_monitoring.yml puts it. --no-xattrs keeps macOS
        # from attaching com.apple.provenance headers that GNU tar then warns
        # about on every single file.
        tar --no-xattrs -C "$REPO_ROOT/scripts" -cf - common \
            | $SSH "$SSH_USER@$TARGET" "tar -C '$SCRIPTS_DIR' --strip-components=1 -xf -"
        # Only the files just pushed. Anything else in there was deployed by a
        # playbook and may be root-owned — chmod'ing the whole directory fails
        # on those and says nothing useful.
        pushed=$(find "$REPO_ROOT/scripts/common" -maxdepth 1 -type f -exec basename {} \; | tr '\n' ' ')
        $SSH -n "$SSH_USER@$TARGET" "cd '$SCRIPTS_DIR' && chmod 0755 $pushed"
        $SSH -n "$SSH_USER@$TARGET" "ls -1 '$SCRIPTS_DIR'"
        say "Done. Note this bypassed Ansible — it proves the script, not the deploy."
        ;;

    run)
        say "Running $RUN_CMD on $remote_hostname"
        $SSH -t "$SSH_USER@$TARGET" "cd '$SCRIPTS_DIR' && ./$RUN_CMD; \
            printf '\n\033[0;36mexit: %s\033[0m\n' \$?"
        ;;

    status)
        say "$remote_hostname ($TARGET) as $SSH_USER"
        $SSH -n "$SSH_USER@$TARGET" "
            . /etc/os-release; printf 'os        : %s\n' \"\$PRETTY_NAME\"
            printf 'failed    : %s unit(s)\n' \"\$(systemctl list-units --failed --no-legend --plain | grep -c '[^[:space:]]' || true)\"
            printf 'scripts   : %s file(s) in %s\n' \"\$(ls -1 '$SCRIPTS_DIR' 2>/dev/null | wc -l | tr -d ' ')\" '$SCRIPTS_DIR'
            printf 'logs dir  : %s\n' \"\$([ -d '$LOGS_DIR' ] && echo present || echo MISSING)\"
            printf 'crontab   : %s line(s)\n' \"\$(crontab -l 2>/dev/null | grep -v '^#' | grep -c '[^[:space:]]' || true)\"
            printf 'disk      : %s\n' \"\$(df -h / | awk 'NR==2 {print \$5\" used\"}')\"
        "
        ;;

    reset)
        # A soft reset: everything a test or a hand-edit is likely to have
        # changed, minus the container itself. It deliberately does NOT recreate
        # the container — that needs `pct` on the Proxmox host, which needs
        # someone at the machine. If the box is wedged past this, rebuild with
        #   ssh cwwk 'sh -s -- --destroy' < tests/provision_test_container.sh
        say "Resetting $remote_hostname to baseline"

        warn "this deletes $SCRIPTS_DIR, $LOGS_DIR and $SSH_USER's crontab"
        printf 'continue? [y/N] '
        read -r reply || reply=""
        case "$reply" in [yY]*) : ;; *) die "aborted" ;; esac

        $SSH -n "$SSH_USER@$TARGET" "
            set -e
            rm -rf '$SCRIPTS_DIR' '$LOGS_DIR'
            crontab -r 2>/dev/null || true
            sudo rm -rf /etc/monitoring
            sudo systemctl reset-failed 2>/dev/null || true
            sudo apt-get install -y -qq $PACKAGES >/dev/null 2>&1
            sudo systemctl start cron fail2ban ssh 2>/dev/null || true
            # The suite fills disks and breaks name resolution on purpose.
            sudo rm -f /testfill /var/tmp/testfill 2>/dev/null || true
            sudo sed -i '/# sandbox-test/d' /etc/hosts 2>/dev/null || true
        "
        say "Clean. Verifying:"
        if [ "$SSH_USER" = root ]; then
            exec "$0" --target "$TARGET" --root --status
        else
            exec "$0" --target "$TARGET" --status
        fi
        ;;
esac
