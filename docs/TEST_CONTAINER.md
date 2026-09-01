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

**CT 199 is disposable by design.** It is not hardened, not monitored, and not
set to start on boot. Nothing should ever depend on it existing.

⚠️ **It IS in an Ansible inventory — just not the fleet's.** This paragraph used
to say the opposite, which was wrong and actively harmful: an agent that read it
first concluded playbook testing was out of scope and stopped. The rig is
described in [`ansible/inventory/test_hosts.yml`](../ansible/inventory/test_hosts.yml),
a **separate** inventory that never mentions a fleet host, and running playbooks
against it is a first-class use of this container — see
[§6b](#6b-running-playbooks-against-it) and [TESTING_GOALS.md](TESTING_GOALS.md).
What must never happen is CT 199 appearing in `ansible/inventory/hosts.yml`, or a
fleet host appearing in `test_hosts.yml` — `is_test_environment` unlocks
behaviour that must not reach production.

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

## 3b. Make it look like a host bootstrap has met

Two things a fleet host has and a fresh template does not. Skipping either makes
the rig report faults that exist only in the rig — the same trap as the fail2ban
jail below.

```sh
# ping: a template has no capability xattr on /bin/ping, so ICMP works for root
# and fails for everyone else. system_health_check.sh then reports "Internet:
# unreachable" on a container whose network is fine. `apt-get install
# --reinstall iputils-ping` does NOT fix it; setcap does, even unprivileged.
pct exec 199 -- setcap cap_net_raw+ep /bin/ping

# The infrastructure user. Every playbook writes under its home — scripts_dir,
# logs_dir, the crontabs — so without it deploy_monitoring.yml fails on its
# first task with "chown failed: failed to look up user".
pct exec 199 -- useradd --create-home --shell /bin/bash --groups sudo choco
pct exec 199 -- sh -c 'echo "choco ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/choco'
pct exec 199 -- chmod 440 /etc/sudoers.d/choco

# ... and the key authorised for it, so Ansible connects the way it connects to
# the fleet: as the infrastructure user, escalating with sudo. Connecting as
# root instead makes `become` a no-op, so every privilege-escalation path in
# every playbook goes untested.
pct exec 199 -- install -d -m 700 -o choco -g choco /home/choco/.ssh
pct exec 199 -- sh -c 'cp /root/.ssh/authorized_keys /home/choco/.ssh/authorized_keys'
pct exec 199 -- chown choco:choco /home/choco/.ssh/authorized_keys
pct exec 199 -- chmod 600 /home/choco/.ssh/authorized_keys
```

For the **bootstrap user-creation path**, you want the opposite — a container
with root and nothing else, which is the only state where that branch runs.
`TEST_CT_BARE=1 sh provision_test_container.sh` skips this whole step.

Verified against production (`unifi-lxc`, 2026-08-04): its `/bin/ping` carries
`cap_net_raw+ep` while `net.ipv4.ping_group_range` is `65534 65534` on both, so
the capability is what the fleet actually relies on.

`--groups sudo` and nothing else is deliberate — it is exactly what
`bootstrap.yml` does. In particular **do not add `adm`**: its absence is a real
fleet fault the rig should reproduce, not paper over. See `docs/TODO.md`.

What is deliberately *not* mirrored is `ssh_hardening.yml`. See "Running
playbooks against it" below.

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

See [tests/README.md](../tests/README.md) for what the suite covers and how
to add cases.

## 6b. Running playbooks against it

`ansible/inventory/test_hosts.yml` describes both containers. It is a separate
inventory file, never included from `hosts.yml`, so nothing here can reach a
fleet host by accident.

```sh
ansible-playbook -i ansible/inventory/test_hosts.yml \
    ansible/playbooks/deploy_monitoring.yml
```

Measured 2026-08-04, against both CT 199 and CT 198:

Connection is as the **infrastructure user over sudo**, exactly as the fleet is
reached — not as root. Connecting as root would make `become` a no-op and drag
`scripts_dir`/`logs_dir` to `/home/root`, since they derive from `ansible_user`.

| Play | Result |
|---|---|
| Deploy common monitoring scripts | converges; all 6 scripts, `changed=0` on re-run |
| Deploy Proxmox monitoring | no hosts matched — needs a host in `proxmox_hosts` |
| Deploy OPNsense monitoring | no hosts matched — needs FreeBSD |
| SMART disk-health | skipped; gated on `enable_smart_monitoring` |

`services.yml --tags monitoring` converges and installs the cron.
`services.yml --tags ssh` — the full hardening pass — converges too, verified on
CT 198 on 2026-08-04.

### How hardening is kept from locking the rig out

`tasks/ssh_hardening.yml` sets authorized_keys for `ansible_user` with
`exclusive: true`. That is the whole point of the task on a fleet host — the
GitHub key set is the only truth, so a revoked key disappears everywhere. On a
disposable container the key Ansible connected with *is* the only way in, so the
same task would lock the rig out of itself with `pct` as the sole way back.

Rather than skipping hardening on test hosts, which would leave it untested,
three things are gated on `is_test_environment` — set only in `test_hosts.yml`,
never in the fleet inventory:

| Task | Fleet host | Test container |
|---|---|---|
| authorized_keys, `exclusive: true` | GitHub key set only | GitHub key set **+ `test_environment_ssh_key`** |
| Disable root login | root shell → nologin | skipped, so root SSH stays as a second way in |
| Lock the user password | locked | skipped |
| `sshd_config` | `PermitRootLogin no` | `PermitRootLogin prohibit-password` |

An `assert` runs **before** the authorized_keys write and fails the play if the
connecting key is missing or empty — after `exclusive: true` has run there is no
way back in to fix it.

Verified in both directions on CT 198: with the flag set, a fresh SSH as both
`choco` and `root` still works after hardening; with `is_test_environment: false`
the same run plans to *remove* the rescue key and renders `PermitRootLogin no`.
So the fleet's behaviour is unchanged.

⚠️ Still true: `bootstrap.yml` and a full `site.yml` have not been run against a
container. Hardening is the piece that made them dangerous, and it is now
handled, but the rest of those playbooks remains unexercised here.

## 7. Destroy when done

```sh
pct stop 199 && pct destroy 199
```

Nothing else needs cleaning up — the container held no state, and it appears
only in `test_hosts.yml`, never in the fleet inventory.

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
