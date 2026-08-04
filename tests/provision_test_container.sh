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
        testlxc|test-*|*-test) : ;;
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
