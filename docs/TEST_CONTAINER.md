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

---

# Covering the rest of the fleet

CT 199 is an exact match for `agent-lxc` and `unifi-lxc`, and close to `cwwk`.
It represents **three of seven hosts**. What follows closes most of the rest.

Measured 2026-08-04:

| Host | OS | Arch | systemd | Python |
|---|---|---|---|---|
| CT 199 `testlxc` | Debian 13 | x86_64 | 257 | 3.13.5 |
| `agent-lxc`, `unifi-lxc` | Debian 13 | x86_64 | 257 | 3.13.5 |
| `cwwk` | Debian 13 | x86_64 | 257 | 3.13.5 |
| 4× RPis | Debian 12 | aarch64 | 252 | 3.11.2 |
| `opnsense` | FreeBSD 14.3 | x86_64 | — | — |

## ⚠️ Read this before creating anything on cwwk

`free -h` on cwwk reports **31 GiB total, 25 GiB used, 5.9 GiB available** — the
OPNsense VM alone holds 12 GiB. cwwk is also the internet single point of
failure and has overheated twice (2026-06-30, 2026-07-31).

- **Containers are nearly free.** An idle Debian LXC costs ~100–200 MB. Adding
  CT 198 is not a meaningful risk.
- **VMs are not.** A FreeBSD test VM takes real memory from a box whose own
  TODO carries "cwwk Memory Optimization" as a standing item.

So: **start a test VM only when you need it and stop it afterwards. Never set
`onboot 1` on one.** Cheap to obey, and the failure mode is losing the internet.

## Raspberry Pi coverage — a Debian 12 container

The Pis differ from CT 199 in OS version *and* architecture. Only the first is
worth chasing, and it is the one that matters: POSIX shell does not care about
the CPU, but it very much cares about coreutils/util-linux flag support,
`systemctl` output format, and Python version — all of which track the Debian
release.

```sh
TEST_CT_VMID=198 TEST_CT_HOSTNAME=test-deb12 \
TEST_CT_IP=10.30.40.206 \
TEST_CT_TEMPLATE=debian-12-standard_12.12-1_amd64.tar.zst \
sh tests/provision_test_container.sh

tests/run_tests.sh --target 10.30.40.206
```

`debian-12-standard_12.12-1_amd64.tar.zst` is available from `pveam` but not
cached on cwwk; the script downloads it.

### Debian 12 gotcha, found on the first run (2026-08-04)

A bare Debian 12 container ends up with **fail2ban dead and one failed unit**:
its stock sshd jail reads `/var/log/auth.log`, and a container with no rsyslog
never creates that file, so the service exits with *"Have not found any log
file for sshd jail"*. Debian 13 does not have this problem — it defaults to the
systemd backend.

The fleet does not have it either, because `bootstrap` writes
`/etc/fail2ban/jail.d/sshd.conf` with `backend = systemd`
(`ansible/playbooks/tasks/install_base_software.yml:52`). Verified on
dockassist: no rsyslog, no `auth.log`, fail2ban **active**.

`provision_test_container.sh` now applies the same config, so the container
matches the fleet. Worth noting as a category: **anything bootstrap does to a
real host has to be mirrored here, or the test rig reports faults that only
exist in the test rig.** This one surfaced immediately because
`system_health_check.sh` treats fail2ban as a critical service.

**Permanently uncovered:** aarch64 itself, and anything touching Pi hardware —
ALSA on hifipi, `vcgencmd`, the thermal sysfs paths. LXC shares the host
kernel, so an aarch64 container cannot run on the x86_64 cwwk at all. Full
aarch64 emulation under QEMU/TCG would work but is far too slow to be worth it
for shell scripts. Treat arch-specific and hardware-specific behaviour as
reasoned, never verified.

## FreeBSD coverage — a plain FreeBSD VM, not OPNsense

**Use FreeBSD, not OPNsense.** What the fleet scripts actually hit on the
firewall is BSD *userland*: `service X status` instead of `systemctl`, BSD
`awk`/`df`/`sed` output, FreeBSD `/bin/sh` instead of dash, no `/proc/meminfo`.
A stock FreeBSD VM covers all of it. OPNsense adds only OPNsense-specific
behaviour — `config.xml` account regeneration, the `auth.inc` shell gating —
and the repo's own direction is to stop SSH-probing OPNsense in favour of its
API, so investing in an OPNsense test VM builds for a path being retired.

FreeBSD publishes **pre-installed qcow2 images, no installer required**, and
14.3-RELEASE matches opnsense's `14.3-RELEASE-p14` base:

```sh
# On cwwk, as root
cd /var/lib/vz/template/iso
curl -fLO https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64.qcow2.xz
unxz FreeBSD-14.3-RELEASE-amd64.qcow2.xz

qm create 198 --name test-freebsd --memory 1024 --cores 1 \
  --net0 virtio,bridge=vmbr0 --ostype other \
  --serial0 socket --vga serial0 --onboot 0

qm importdisk 198 FreeBSD-14.3-RELEASE-amd64.qcow2 local-zfs
qm set 198 --scsihw virtio-scsi-pci --scsi0 local-zfs:vm-198-disk-0 --boot order=scsi0
qm start 198
qm terminal 198        # serial console over your SSH session; Ctrl-O to exit
```

Pick a VMID that is free — 198 is used above for the Debian 12 *container*, and
CT and VM IDs share one namespace on Proxmox, so choose different numbers for
the two.

The `--serial0 socket` + `qm terminal` combination is what makes this workable
over SSH alone, with no Proxmox web UI. First boot needs a console to set a
root password and enable sshd, after which the read_agent key can be installed
the same way as on the containers.

**Unverified:** these `qm` invocations are written from the documented Proxmox
pattern and have not been executed. Expect to adjust the disk name that
`importdisk` reports.

## If you specifically need OPNsense, not just FreeBSD

Verified against the OPNsense install documentation: **there is no official
qcow2, OVA, or cloud image.** The DVD, VGA and serial images all boot a live
environment and require running the installer; only the Nano image is
pre-installed, and it targets embedded devices on ≥4 GB media.

The workable SSH-only path is the **serial** image plus `qm terminal`, giving a
text-mode installer without the web UI — roughly ten interactive minutes. Worth
it only for testing OPNsense-specific behaviour, which is a small and shrinking
surface.
