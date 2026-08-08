#!/bin/sh
# Provision (or destroy) the disposable test container on Proxmox.
#
# Run ON the Proxmox host — it needs `pct`, which read_agent deliberately
# cannot use:
#
#   ssh cwwk
#   sh /path/to/provision_test_container.sh          # create + configure
#   sh /path/to/provision_test_container.sh --destroy
#
# Or drive it from the laptop without copying it over:
#
#   ssh cwwk 'sh -s' < tests/provision_test_container.sh
#
# Idempotent: an existing CT 199 is reconfigured, not recreated.
#
# TARGETS
#
#   CT 199 (default) — Debian 13. Exact match for agent-lxc and unifi-lxc,
#   close match for cwwk (same OS/arch/systemd/python; bare metal rather than
#   LXC).
#
#   CT 198 — Debian 12, for the four Raspberry Pis. They report as Debian 12
#   bookworm with systemd 252 and Python 3.11, two major versions behind
#   CT 199. That gap — not the CPU architecture — is where the behaviour a
#   POSIX shell script can trip over actually lives: coreutils and util-linux
#   flags, systemctl output, python. Create it with:
#
#     TEST_CT_VMID=198 TEST_CT_HOSTNAME=test-deb12 \
#     TEST_CT_IP=10.30.40.206 \
#     TEST_CT_TEMPLATE=debian-12-standard_12.12-1_amd64.tar.zst \
#     sh provision_test_container.sh
#
#   (the template is not cached on cwwk by default; the script downloads it)
#
# STILL NOT COVERED by either container, and unfixable here: aarch64, and
# anything touching Pi hardware — ALSA on hifipi, vcgencmd, the thermal sysfs
# paths. LXC shares the host kernel, so no aarch64 container can run on the
# x86_64 cwwk. FreeBSD needs a VM, not a container — see docs/TEST_CONTAINER.md.
#
# This is deliberately a shell script and not an Ansible playbook. The
# container is disposable scaffolding that must be creatable when the
# inventory, the vault, or the playbooks themselves are what is being tested —
# so it takes no dependency on any of them. `provision_agent_lxc.yml` remains
# the pattern for real infrastructure.
#
# See docs/TEST_CONTAINER.md for the reasoning behind each setting.

set -eu

VMID="${TEST_CT_VMID:-199}"
HOSTNAME_="${TEST_CT_HOSTNAME:-testlxc}"
IP="${TEST_CT_IP:-10.30.40.205}"
CIDR="${TEST_CT_CIDR:-24}"
GATEWAY="${TEST_CT_GATEWAY:-10.30.40.254}"
NAMESERVER="${TEST_CT_NAMESERVER:-10.30.40.254}"
BRIDGE="${TEST_CT_BRIDGE:-vmbr0}"
STORAGE="${TEST_CT_STORAGE:-local-zfs}"
ROOTFS_GB="${TEST_CT_ROOTFS_GB:-4}"
MEMORY="${TEST_CT_MEMORY:-1024}"
SWAP="${TEST_CT_SWAP:-512}"
CORES="${TEST_CT_CORES:-1}"

# Must match `infrastructure_user` as the inventory resolves it, since that is
# what every playbook chowns to. It defaults to $USER on the control machine
# (see group_vars/all/main.yml), so the default here is that same name rather
# than something rig-specific — the container is meant to be a twin.
INFRA_USER="${TEST_CT_USER:-choco}"

# TEST_CT_BARE=1 leaves the container with root and nothing else — a genuinely
# fresh host. That is the only state in which bootstrap.yml's "connected as
# root, create the infrastructure user" branch runs, so it is the only way to
# test the user-gardening path. The default (0) produces a host that already
# looks bootstrapped, which is what everything downstream of bootstrap expects.
BARE="${TEST_CT_BARE:-0}"

# Same pinned image as agent-lxc, so the target is a twin of a real fleet host
# rather than an approximation. Bump both together when Debian moves.
TEMPLATE_STORAGE="${TEST_CT_TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEST_CT_TEMPLATE:-debian-13-standard_13.6-1_amd64.tar.zst}"

# The read_agent public key. Authorised for root here — the tests must fill
# disks and stop services, which read_agent's scoped read-only sudo exists to
# prevent. Acceptable only because this container is LAN-only, empty, and
# destroyed after use. Never reuse this pattern on a host that persists.
AGENT_PUBKEY="${TEST_CT_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzwUkF8g+nliH4mXRm3Qlslb7TioAHQlvl1w9i5XkN3 claude_agent@infrastructure}"

# system_health_check.sh probes all of these; without them a healthy baseline
# would fail for the wrong reason.
PACKAGES="openssh-server python3 sudo procps iproute2 unattended-upgrades cron fail2ban curl jq"

say() { printf '\n\033[0;32m==>\033[0m %s\n' "$1"; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root on the Proxmox host"
command -v pct >/dev/null 2>&1 || die "pct not found — this must run on the Proxmox host, not the laptop"

# ------------------------------------------------------------------
# Destroy
# ------------------------------------------------------------------
if [ "${1:-}" = "--destroy" ]; then
    if ! pct config "$VMID" >/dev/null 2>&1; then
        say "CT $VMID does not exist; nothing to destroy"
        exit 0
    fi
    # Guard against ever pointing this at a real container.
    _name=$(pct config "$VMID" | awk -F': ' '/^hostname:/ {print $2}')
    case "$_name" in
        testlxc*|test-*|*-test) : ;;
        *) die "CT $VMID is '$_name', not a test container. Refusing to destroy." ;;
    esac
    say "Stopping and destroying CT $VMID ($_name)"
    pct stop "$VMID" 2>/dev/null || true
    pct destroy "$VMID"
    say "Destroyed."
    exit 0
fi

[ "${1:-}" = "" ] || die "unknown argument: $1 (expected --destroy or nothing)"

# ------------------------------------------------------------------
# Create
# ------------------------------------------------------------------
if pct config "$VMID" >/dev/null 2>&1; then
    say "CT $VMID already exists — reconfiguring, not recreating"
else
    if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
        say "Template $TEMPLATE not cached; downloading"
        pveam update
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    fi

    say "Creating CT $VMID ($HOSTNAME_) at $IP"
    # --features nesting=1 is not optional. Without it systemd cannot mount its
    # credentials tmpfs, journald dies, and every systemd assertion in the
    # suite becomes meaningless — the exact failure that hid the CT 103 outage
    # for 12 days.
    # --onboot 0 so a forgotten test container does not survive a reboot.
    pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME_" \
        --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
        --rootfs "${STORAGE}:${ROOTFS_GB}" \
        --features nesting=1 \
        --net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=${IP}/${CIDR},gw=${GATEWAY},type=veth" \
        --nameserver "$NAMESERVER" --searchdomain local \
        --ostype debian --unprivileged 1 --onboot 0
fi

if [ "$(pct status "$VMID")" != "status: running" ]; then
    say "Starting CT $VMID"
    pct start "$VMID"
    sleep 10
fi

# A degraded container invalidates every systemd result the suite produces, so
# this is a hard failure rather than a warning — the same lesson that
# provision_agent_lxc.yml learned from CT 103 passing provisioning with 19
# failed units.
say "Checking systemd health"
_failed=$(pct exec "$VMID" -- systemctl list-units --failed --no-legend --plain 2>/dev/null \
          | grep -c '[^[:space:]]' || true)
if [ "${_failed:-0}" -gt 0 ]; then
    pct exec "$VMID" -- systemctl --failed || true
    die "CT $VMID has ${_failed} failed unit(s) — check that nesting=1 took effect"
fi
say "systemd clean (0 failed units)"

say "Installing test prerequisites"
pct exec "$VMID" -- apt-get update -qq
# shellcheck disable=SC2086  # word splitting is intended for the package list
pct exec "$VMID" -- apt-get install -y -qq $PACKAGES

# Mirror the fail2ban jail config the fleet gets from bootstrap
# (install_base_software.yml). Debian 13 defaults to the systemd backend, but
# Debian 12 does not: its stock sshd jail reads /var/log/auth.log, which a
# container with no rsyslog never creates, so fail2ban dies at startup with
# "Have not found any log file for sshd jail". Without this the container has a
# failed unit and a dead fail2ban that no real fleet host has, and
# system_health_check reports a fault that exists only in the test rig.
say "Applying the fleet's fail2ban sshd jail config"
pct exec "$VMID" -- sh -c 'printf "[sshd]\nenabled = true\nbackend = systemd\n" > /etc/fail2ban/jail.d/sshd.conf'
pct exec "$VMID" -- chmod 644 /etc/fail2ban/jail.d/sshd.conf
pct exec "$VMID" -- systemctl restart fail2ban

# A container built from a pveam template has no capability xattr on /bin/ping,
# so ICMP works for root and fails for everyone else with "socket: Operation not
# permitted" — and system_health_check.sh reports "Internet: unreachable" for a
# host whose network is fine. A long-lived fleet container (verified on
# unifi-lxc) does carry cap_net_raw+ep, and the fleet's ping_group_range is
# 65534 65534, so the capability is what production actually relies on.
# `apt-get install --reinstall iputils-ping` does NOT restore it; setcap does,
# and it works inside an unprivileged container.
say "Restoring cap_net_raw on ping (absent in a fresh template)"
pct exec "$VMID" -- setcap cap_net_raw+ep /bin/ping

# Deliberately NOT mirrored: adding the user to the `adm` group. bootstrap.yml
# creates it with `groups: sudo` only, so on every host whose user came from
# bootstrap — cwwk, unifi-lxc, agent-lxc — /var/log/unattended-upgrades
# (root:adm 0750) is unreadable and check_auto_upgrades reports "Upgrade log not
# found". The four Pis escape it because their user predates bootstrap and
# inherited the Pi image's group list. The rig reproducing that is correct: it
# is a real fleet fault, not a rig artifact. See docs/TODO.md.

# Mirror the infrastructure user bootstrap.yml creates the first time it meets a
# host as root. Every playbook writes under /home/<infrastructure_user> —
# scripts_dir, logs_dir, the crontabs — so without this user
# deploy_monitoring.yml dies on its very first task with "chown failed: failed
# to look up user", and site.yml never gets far enough to test anything.
# Same lesson as the fail2ban jail above: what bootstrap does to a real host has
# to be mirrored here, or the rig only reports faults of its own making.
#
# Deliberately NOT mirrored: ssh_hardening.yml. It sets PermitRootLogin to
# prohibit-password with no key for the fleet's real users, and gives root
# /sbin/nologin. The read_agent key authorised for root below is the only way
# into this container, so hardening it would lock the rig out of itself.
if [ "$BARE" = "1" ]; then
    say "TEST_CT_BARE=1 — skipping the infrastructure user"
    printf '    The container is left as a fresh host with root only, which is what\n'
    printf '    bootstrap.yml expects the first time it meets a machine. Point the\n'
    printf '    inventory at it with ansible_user=root to exercise that path.\n'
else
    say "Creating the infrastructure user ($INFRA_USER)"
    pct exec "$VMID" -- sh -c "id '$INFRA_USER' >/dev/null 2>&1 || \
        useradd --create-home --shell /bin/bash --groups sudo '$INFRA_USER'"
    pct exec "$VMID" -- sh -c "printf '%s ALL=(ALL) NOPASSWD: ALL\n' '$INFRA_USER' \
        > '/etc/sudoers.d/$INFRA_USER'"
    pct exec "$VMID" -- chmod 440 "/etc/sudoers.d/$INFRA_USER"
    pct exec "$VMID" -- visudo -c -f "/etc/sudoers.d/$INFRA_USER"

    # Authorising the key for the infrastructure user, not just root, is what
    # lets the inventory connect the way the fleet actually does — as
    # $INFRA_USER over sudo. Connecting as root instead makes `become` a no-op,
    # so every privilege-escalation path in every playbook goes untested, and it
    # drags scripts_dir and logs_dir to /home/root because they derive from
    # ansible_user.
    say "Authorising the agent key for $INFRA_USER"
    pct exec "$VMID" -- install -d -m 700 -o "$INFRA_USER" -g "$INFRA_USER" \
        "/home/$INFRA_USER/.ssh"
    pct exec "$VMID" -- sh -c "printf '%s\n' '$AGENT_PUBKEY' \
        > '/home/$INFRA_USER/.ssh/authorized_keys'"
    pct exec "$VMID" -- chown "$INFRA_USER:$INFRA_USER" "/home/$INFRA_USER/.ssh/authorized_keys"
    pct exec "$VMID" -- chmod 600 "/home/$INFRA_USER/.ssh/authorized_keys"
fi

# Root keeps the key too, as the second way in. ssh_hardening would normally
# close this off; on a host flagged is_test_environment it leaves it open,
# because `pct` on the hypervisor is otherwise the only recovery path.
say "Authorising the agent key for root"
pct exec "$VMID" -- mkdir -p /root/.ssh
pct exec "$VMID" -- sh -c "printf '%s\n' '$AGENT_PUBKEY' > /root/.ssh/authorized_keys"
pct exec "$VMID" -- chmod 700 /root/.ssh
pct exec "$VMID" -- chmod 600 /root/.ssh/authorized_keys
pct exec "$VMID" -- sh -c 'echo "PermitRootLogin prohibit-password" > /etc/ssh/sshd_config.d/10-testlxc.conf'
pct exec "$VMID" -- systemctl restart ssh

cat <<EOF

────────────────────────────────────────────────────────
CT $VMID ($HOSTNAME_) ready at $IP

Verify from the laptop:
  ssh -i ~/.ssh/read_agent_ed25519 -o IdentitiesOnly=yes \\
      -o IdentityAgent=none root@$IP 'hostname; systemctl --failed'

Run the suite from the repo root:
  tests/run_tests.sh --target $IP

Destroy when done:
  ssh cwwk 'sh -s -- --destroy' < tests/provision_test_container.sh
────────────────────────────────────────────────────────
EOF
