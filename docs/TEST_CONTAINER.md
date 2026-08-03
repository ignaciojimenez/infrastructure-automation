# Disposable Test Container

A throwaway Debian LXC on `cwwk` for testing monitoring scripts against **real**
failure conditions — a genuinely full disk, a stopped `cron`, an unreachable
gateway, a failed systemd unit.

## Why this exists

Most of this repo's monitoring is POSIX shell that only matters when something
breaks. The 2026-08-03 incident showed the cost of never testing that path:
`system_health_check.sh` had been unable to fail on all 7 hosts since it was
written, because the red ❌ output printed perfectly while the exit code stayed
`0`. Printing an error and *reporting* an error are different things, and only
one of them is visible without forcing the condition.

Forcing those conditions on a production host is unacceptable — filling
`dockassist`'s disk to test a disk check is a worse outage than the one the
check is meant to catch. So they get forced here instead, on a container that
is deleted afterwards.

**CT 199 is disposable by design.** It is deliberately *not* in the Ansible
inventory, not hardened, not monitored, and not set to start on boot. Nothing
should ever depend on it existing.

## Design choices

| Choice | Why |
|---|---|
| CTID `199` | Well clear of the real range (100–103). Obviously not production. |
| Same pinned template as `agent-lxc` | `debian-13-standard_13.6-1_amd64.tar.zst` — already cached on cwwk. A faithful twin of the host these scripts actually run on, not an approximation. |
| `--features nesting=1` | Without it systemd cannot mount its credentials tmpfs and `journald` dies — the exact CT 103 bug. Since these tests exercise `systemctl`, an unhealthy systemd would invalidate every result. |
| `--onboot 0` | A forgotten test container must not survive a reboot. |
| 4 GB rootfs | Small enough that "fill the disk" is a ~2 GB write, not a 15 GB one. |
| `root` SSH with the `read_agent` key | The tests must *break* things — stop services, fill disks. `read_agent`'s scoped read-only sudo exists precisely to prevent that, so it is the wrong identity here. |

> ⚠️ **Security note.** This container permits root SSH with a passphrase-free
> key. That is acceptable only because it is LAN-only, short-lived, holds
> nothing, and is destroyed after use. Do not copy this pattern to any host
> that persists, and delete the container when finished.

## Prerequisites

Run from your laptop as `choco` (needs Touch ID — `read_agent` deliberately
cannot create containers):

```sh
ssh cwwk
```

Everything below runs as root on the Proxmox host.

## 1. Verify the IP is free

The fleet's Proxmox guests use a static block at `10.30.40.200–204`
(`.200` pihole, `.201` unifi, `.203` agent-lxc, `.204` a Raspberry Pi), so
`.205` follows the existing pattern. **This is inferred from the neighbouring
assignments, not verified against the DHCP pool** — `read_agent` cannot read
`/conf/config.xml` on OPNsense. Confirm before creating:

```sh
# On the Proxmox host — nothing should answer
ping -c2 -W1 10.30.40.205

# On OPNsense (as root), confirm .205 is outside the DHCP pool
grep -A3 '<range>' /conf/config.xml | head -20
```

If `.205` is inside the pool, either pick one below it or swap the `--net0`
line for `ip=dhcp` and read the address back with
`pct exec 199 -- ip -4 -br addr show eth0`.

## 2. Create and start

```sh
pct create 199 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname testlxc \
  --cores 1 --memory 1024 --swap 512 \
  --rootfs local-zfs:4 \
  --features nesting=1 \
  --net0 name=eth0,bridge=vmbr0,firewall=1,ip=10.30.40.205/24,gw=10.30.40.254,type=veth \
  --nameserver 10.30.40.254 --searchdomain local \
  --ostype debian --unprivileged 1 --onboot 0

pct start 199
sleep 10
```

Confirm systemd came up clean — if this reports failed units, `nesting=1` did
not take effect and the results of any systemd test will be meaningless:

```sh
pct exec 199 -- systemctl --failed
# expected: "0 loaded units listed."
```

## 3. Install the test prerequisites

```sh
pct exec 199 -- apt-get update
pct exec 199 -- apt-get install -y openssh-server python3 sudo procps iproute2 \
    unattended-upgrades cron fail2ban curl jq
```

`unattended-upgrades`, `cron` and `fail2ban` are installed because
`system_health_check.sh` checks for them; without them the "healthy baseline"
test would fail for the wrong reason.

## 4. Authorise the agent key

```sh
pct exec 199 -- mkdir -p /root/.ssh
pct exec 199 -- sh -c 'cat > /root/.ssh/authorized_keys' <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzwUkF8g+nliH4mXRm3Qlslb7TioAHQlvl1w9i5XkN3 claude_agent@infrastructure
EOF
pct exec 199 -- chmod 700 /root/.ssh
pct exec 199 -- chmod 600 /root/.ssh/authorized_keys
pct exec 199 -- sh -c 'echo "PermitRootLogin prohibit-password" > /etc/ssh/sshd_config.d/10-testlxc.conf'
pct exec 199 -- systemctl restart ssh
```

## 5. Verify from the laptop

```sh
ssh -i ~/.ssh/read_agent_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=accept-new root@10.30.40.205 'hostname; systemctl --failed'
```

The container is ready when that prints `testlxc` and `0 loaded units listed.`

## 6. Run the test suite

From the repo root on the laptop:

```sh
tests/run_tests.sh --target 10.30.40.205
```

See [tests/README.md](../../tests/README.md) for what the suite covers and how
to add cases.

## 7. Destroy when done

```sh
pct stop 199 && pct destroy 199
```

Nothing else needs cleaning up — the container held no state and was never in
the inventory.

## Rebuilding later

Steps 2–4 are idempotent enough to paste again after a `pct destroy`. If the
pinned template has been garbage-collected from `local`:

```sh
pveam update
pveam download local debian-13-standard_13.6-1_amd64.tar.zst
```
