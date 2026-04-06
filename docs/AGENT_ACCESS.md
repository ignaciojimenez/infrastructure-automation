# Agent Access — Phase 1 Discovery & Design

Read-only infrastructure access for Claude agents. Enables autonomous investigation
of any system (SSH, APIs, logs) without biometric authentication.

**Status:** Phase 2 — SSH access deployed and validated on all 7 hosts (2026-04-06). HA + Proxmox API tokens pending.

---

## Problem

All SSH keys are in Secretive (Secure Enclave), requiring biometric auth for each use.
This blocks agents from SSHing to hosts, querying APIs via SSH tunnels, or running
diagnostic commands autonomously. Every investigation requires the operator to manually
authenticate, defeating the purpose of agent-driven diagnostics.

---

## Architecture Overview

Two access channels, both read-only. Phased rollout:

- **Phase 2 (this implementation):** SSH to all hosts + HA API + Proxmox API
- **Phase 3 (future TODO):** OPNsense API, UniFi API, Plex API (see [Future: API Expansion](#future-api-expansion))

```
Claude Agent
    |
    +-- SSH (Ed25519 key, password-protected, IP-restricted)
    |     +-- dockassist   (docker ps/logs, systemctl status, journalctl)
    |     +-- cobra        (systemctl status, df, mount checks)
    |     +-- hifipi       (systemctl status, amixer, aplay -l)
    |     +-- vinylstreamer (systemctl status)
    |     +-- opnsense     (pgrep, sysctl, pfctl -s, configctl)
    |     +-- cwwk         (qm/pct status, zpool, sensors, pvesh get)
    |     +-- unifi        (systemctl status, pgrep, curl localhost)
    |
    +-- APIs (Phase 2 scope)
    |     +-- Home Assistant  :8123  (Bearer token, read-only user)
    |     +-- Proxmox         :8006  (PVEAPIToken, PVEAuditor role)
    |
    +-- APIs (Phase 3 — future TODO)
          +-- OPNsense        :443   (API key+secret, read-only group)
          +-- UniFi           :8443  (Session cookie, read-only admin)
          +-- Plex            :32400 (X-Plex-Token, read-only)
```

---

## SSH Access Design

### User: `read_agent`

| Property | Value | Rationale |
|----------|-------|-----------|
| Username | `read_agent` | Descriptive, distinct from human users |
| Shell | `/bin/sh` | POSIX — works on both Debian and FreeBSD |
| Home | `/home/read_agent` (Debian), `/usr/home/read_agent` (FreeBSD) | Minimal, no sensitive files |
| Password | disabled (locked) | Key-only auth |
| SSH key | Ed25519, NOT in Secretive | Unattended agent access is the whole point |
| Groups | `read_agent` only | No membership in `sudo`, `wheel`, `docker`, or other privileged groups |

### SSH Key Management

The agent's private key lives on the control machine at `~/.ssh/read_agent_ed25519`,
outside Secretive. The key is **password-protected**; the passphrase is stored in
Ansible Vault as `vault_agent_ssh_passphrase`.

| Artifact | Location | Protection |
|----------|----------|------------|
| Private key | `~/.ssh/read_agent_ed25519` on control machine | Passphrase-encrypted Ed25519 |
| Passphrase | `vault_agent_ssh_passphrase` in Ansible Vault | AES256 vault encryption |
| Public key | `vault_agent_ssh_pubkey` in Ansible Vault | Deployed to all hosts |

The public key is deployed to all hosts via Ansible in `authorized_keys` for `read_agent`,
with a `from=` restriction limiting connections to the home LAN (`10.30.0.0/16`).

```
# authorized_keys format on each host
from="10.30.0.0/16" ssh-ed25519 AAAA... read_agent@infrastructure
```

At runtime, Claude Code uses `ssh -i ~/.ssh/read_agent_ed25519` with the passphrase
loaded into `ssh-agent` at session start.

### Sudo Rules — Debian Hosts (dockassist, cobra, hifipi, vinylstreamer, cwwk, unifi)

```sudoers
# /etc/sudoers.d/read_agent — deployed by Ansible
# Read-only commands only — NO restart, write, delete, or control operations

# System diagnostics (all Debian hosts)
read_agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
read_agent ALL=(ALL) NOPASSWD: /usr/bin/journalctl --no-pager *
read_agent ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u * --no-pager *
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/ss -tlnp
read_agent ALL=(ALL) NOPASSWD: /usr/bin/lsof -i
```

### Sudo Rules — Proxmox Host (cwwk) — additional

```sudoers
# Proxmox-specific read-only commands
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/qm list
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/qm status *
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/qm config *
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/pct list
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/pct status *
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/pct config *
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/zpool status
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/zpool list
read_agent ALL=(ALL) NOPASSWD: /usr/sbin/zfs list
read_agent ALL=(ALL) NOPASSWD: /usr/bin/sensors
read_agent ALL=(ALL) NOPASSWD: /usr/bin/pvesh get *
```

### Sudo Rules — Homeassistant Host (dockassist) — additional

```sudoers
# Docker read-only commands (dockassist only)
read_agent ALL=(ALL) NOPASSWD: /usr/bin/docker ps *
read_agent ALL=(ALL) NOPASSWD: /usr/bin/docker logs *
read_agent ALL=(ALL) NOPASSWD: /usr/bin/docker inspect *
read_agent ALL=(ALL) NOPASSWD: /usr/bin/docker stats --no-stream *
```

### Sudo Rules — FreeBSD / OPNsense

```sudoers
# /usr/local/etc/sudoers.d/read_agent
read_agent ALL=(ALL) NOPASSWD: /usr/bin/pgrep *
read_agent ALL=(ALL) NOPASSWD: /sbin/pfctl -s info
read_agent ALL=(ALL) NOPASSWD: /sbin/pfctl -s state
read_agent ALL=(ALL) NOPASSWD: /sbin/pfctl -s rules
read_agent ALL=(ALL) NOPASSWD: /usr/local/sbin/configctl service list
read_agent ALL=(ALL) NOPASSWD: /usr/local/sbin/configctl unbound status
read_agent ALL=(ALL) NOPASSWD: /usr/local/sbin/configctl wireguard showconf
```

**OPNsense SSH access note:** OPNsense restricts SSH via `AllowGroups wheel` in sshd_config.
The agent user is NOT added to `wheel` (that gives unrestricted sudo via OPNsense's
`/usr/local/etc/sudoers.d/20-opnsense` which grants `%wheel ALL=(ALL) NOPASSWD: ALL`).
Instead, the Ansible role adds `read_agent` to sshd's `AllowGroups` directive.

**OPNsense sshd reload caveat:** OPNsense auto-generates `sshd_config` from
`/usr/local/etc/inc/plugins.inc.d/openssh.inc`. A full `service openssh restart` can
regenerate host keys and potentially wipe config changes. The Ansible handler uses
`service openssh onereload` (SIGHUP) instead, which re-reads the config without
regenerating keys. After any AllowGroups change, verify with `sshd -T | grep allowgroups`.

### Commands that DON'T need sudo

These are available to the agent without any sudo rules:

- `uptime`, `df -h`, `free -m`, `ps aux`, `top -bn1`, `w`
- `cat /etc/os-release`, `uname -a`, `hostname`
- `crontab -l` (own crontab)
- `sysctl` read operations (FreeBSD)
- `id`, `who`, `last` (login history)
- `ping`, `traceroute`, `dig`, `nslookup`
- `curl` (for health-check endpoints)

---

## API Access Design

### Home Assistant (dockassist:8123)

| Property | Value |
|----------|-------|
| Auth method | Long-lived access token (Bearer) |
| User | Dedicated `read_agent` HA user (local, non-admin) |
| Token creation | HA UI > Profile > Long-Lived Access Tokens |
| Token storage | Ansible Vault as `vault_ha_agent_token` |
| Access scope | All entity states, history, logbook (read). No service calls, config changes, or automations. |

**Key endpoints:**
- `GET /api/states` — all entity states
- `GET /api/states/{entity_id}` — single entity
- `GET /api/history/period/{timestamp}` — historical data
- `GET /api/logbook/{timestamp}` — logbook entries
- `GET /api/config` — HA configuration overview
- `GET /api/` — API health check (returns 200 + `{"message": "API running."}`)

**Limitation:** HA long-lived tokens inherit the user's permissions. A non-admin user
can read states and history but cannot call services, modify config, or install add-ons.
Verify this by creating the user and testing before granting the token.

### Proxmox (cwwk:8006)

| Property | Value |
|----------|-------|
| Auth method | API token (`PVEAPIToken` header) |
| User | `read_agent@pve` (Proxmox local user) |
| Role | `PVEAuditor` — built-in read-only role |
| Token name | `readonly` → full ID: `read_agent@pve!readonly` |
| Token creation | `pveum user add read_agent@pve` + `pveum user token add read_agent@pve readonly --privsep 1` + `pveum acl modify / --tokens read_agent@pve!readonly --roles PVEAuditor` |
| Token storage | Ansible Vault as `vault_proxmox_agent_token` |

**Key endpoints:**
- `GET /api2/json/nodes/{node}/status` — host resource usage
- `GET /api2/json/nodes/{node}/qemu` — VM list
- `GET /api2/json/nodes/{node}/qemu/{vmid}/status/current` — VM status
- `GET /api2/json/nodes/{node}/lxc` — container list
- `GET /api2/json/nodes/{node}/lxc/{vmid}/status/current` — CT status
- `GET /api2/json/nodes/{node}/disks/zfs` — ZFS pool info
- `GET /api2/json/nodes/{node}/tasks` — recent tasks
- `GET /api2/json/cluster/status` — cluster overview

**Header format:**
```
Authorization: PVEAPIToken=read_agent@pve!readonly=<secret-uuid>
```

### Future: API Expansion (Phase 3) {#future-api-expansion}

The following APIs are **out of scope for Phase 2** but documented here for completeness.
SSH access to these hosts is included in Phase 2 — API access adds richer diagnostics
on top of what SSH provides.

**OPNsense (opnsense:443)** — API key + secret, HTTP Basic Auth. Create a `read_agent`
user in a `monitoring-api` group with read-only privileges. Key endpoints: system status,
interface stats, gateway health, Unbound/WireGuard status. Verify endpoints at
`https://opnsense/api-docs`. No API keys exist yet — requires UI setup.

**UniFi (unifi:8443)** — Session cookie auth (no API tokens). Create a local read-only
admin. Community-documented endpoints for device list, client stats, health, alarms.
Requires a wrapper script for session management. Self-signed TLS. Undocumented API
may change between versions.

**Plex (cobra:32400)** — `X-Plex-Token`, account-scoped (no role scoping). Current
monitoring is SSH-based (service running + port check). API would add session/library
visibility but broadens attack surface. Nice-to-have, not needed.

---

## Security Model

### Principles

1. **Read-only enforcement at every layer** — sudo allowlist, API role scoping, no write endpoints
2. **Least privilege** — each access method grants only what's needed for diagnostics
3. **No secret access** — agent user cannot read `vault.yml`, `.tado_tokens`, `secrets.yaml`, `.netrc`, SSL private keys, or any credential files
4. **Separate credentials** — agent uses its own tokens/keys, never shares human credentials
5. **Audit trail** — all agent SSH sessions logged to syslog; API access logged by each service

### What the Agent CAN Do

- SSH to any host and run read-only diagnostic commands
- Query system resource usage (CPU, memory, disk, load)
- Check service status (systemd units, Docker containers, process lists)
- Read logs (journalctl, syslog)
- Query HA and Proxmox APIs for status, health, entity states
- Correlate events across hosts

### What the Agent CANNOT Do

- Restart, stop, or start any service
- Modify any configuration file
- Create, delete, or control VMs/containers
- Execute arbitrary commands via sudo
- Read secrets, tokens, or private keys belonging to other users
- Make API calls that trigger reconfiguration or restarts
- Push code, modify crons, or deploy changes
- Access the network beyond the home LAN (no outbound from agent SSH sessions)

### Credential Storage (Phase 2 Scope)

| Credential | Vault Variable | Created By |
|-----------|----------------|------------|
| SSH passphrase | `vault_agent_ssh_passphrase` | Generated once, stored in vault |
| SSH public key | `vault_agent_ssh_pubkey` | Generated once, deployed to all hosts |
| HA token | `vault_ha_agent_token` | Created in HA UI, stored in vault |
| Proxmox API token | `vault_proxmox_agent_token` | Created via `pveum`, stored in vault |

### Revocation

To revoke all agent access:

1. **SSH**: `ansible all -m user -a "name=read_agent state=absent remove=yes" --become`
2. **HA**: Delete the `read_agent` user in HA UI (invalidates token)
3. **Proxmox**: `pveum user delete read_agent@pve` (invalidates token)

Each can be revoked independently. SSH key removal is also an Ansible one-liner.
To revoke SSH without removing the user, clear `authorized_keys`:
`ansible all -m file -a "path=/home/read_agent/.ssh/authorized_keys state=absent" --become`

### Audit

- **SSH**: All logins appear in `/var/log/auth.log` (Debian) or `/var/log/auth.log` (FreeBSD).
  The username `read_agent` makes grep/filter trivial.
- **Proxmox**: API token usage logged in Proxmox task log and syslog.
- **HA**: API calls logged in HA system log at debug level.

**Optional enhancement:** Add a Slack notification on `read_agent` SSH login via
a PAM exec hook or a simple `~/.ssh/rc` script. Low effort, high visibility.

---

## Implementation Plan (Phase 2)

### Step 1 — Generate SSH Key Pair
```bash
ssh-keygen -t ed25519 -C "read_agent@infrastructure" \
  -f ~/.ssh/read_agent_ed25519 -N "<passphrase>"
# Store passphrase in vault as vault_agent_ssh_passphrase
# Store public key in vault as vault_agent_ssh_pubkey
```

### Step 2 — Ansible Role: `roles/system/agent_access`
Create a role that:
- Creates `read_agent` user (cross-platform: Debian + FreeBSD)
- Deploys SSH `authorized_keys` with `from=` IP restriction (public key from vault)
- Deploys platform-specific sudoers file to `/etc/sudoers.d/read_agent`
- Validates sudoers syntax with `visudo -c` before applying

### Step 3 — Create API Users/Tokens (Manual, One-Time)
- **HA**: Create `read_agent` user (non-admin) in HA UI, generate long-lived token
- **Proxmox**: Run `pveum` commands on cwwk to create user + PVEAuditor token

Store tokens in `vault.yml`.

### Step 4 — SSH Config on Control Machine
Added to `~/.ssh/config` (before the `Host *` block with Secretive's `IdentityAgent`):
```
# Agent access — bypasses Secretive for unattended SSH
# Generic pattern — strips "-agent" suffix to resolve real hostname via ProxyCommand.
Host *-agent
    User read_agent
    IdentityFile ~/.ssh/read_agent_ed25519
    IdentityAgent SSH_AUTH_SOCK
    IdentitiesOnly yes
    ControlPath none
    ProxyCommand sh -c 'nc $(echo %h | sed s/-agent$//) %p'
    StrictHostKeyChecking accept-new
```

**How it works:**
- `ssh dockassist-agent` → `ProxyCommand` strips `-agent` → connects to `dockassist:22`
- `IdentityAgent SSH_AUTH_SOCK` overrides Secretive's agent set in `Host *`
- No per-host config needed — add a new host and `ssh newhost-agent` works immediately
- `ControlPath none` prevents multiplexing conflicts with human SSH sessions
- `StrictHostKeyChecking accept-new` auto-accepts first-time host keys for `-agent` aliases

**Agent workflow:**
1. Start own ssh-agent: `eval $(ssh-agent -s)`
2. Load the key: `ssh-add ~/.ssh/read_agent_ed25519` (supply passphrase)
3. Connect: `ssh dockassist-agent "command"`

### Step 5 — Validation
SSH validated on all 7 hosts (2026-04-06):
- [x] SSH connects without biometric auth — all 7 hosts
- [x] Sudo commands in allowlist work — all 7 hosts
- [x] Sudo commands NOT in allowlist are denied — all 7 hosts
- [ ] Cannot read other users' files (`/home/choco/.netrc`, `secrets.yaml`, etc.)
- [ ] `from=` restriction blocks connections from outside 10.30.0.0/16
- [ ] HA API token returns entity states, rejects service calls
- [ ] Proxmox API token returns VM status, rejects control operations

---

## Decisions (Resolved)

1. **SSH key**: Local Ed25519 key at `~/.ssh/read_agent_ed25519`, password-protected.
   Passphrase stored in Ansible Vault. NOT in Secretive — unattended access is the point.

2. **Plex API**: Out of scope. Current SSH-based monitoring (service + port check) is
   sufficient. No role-scoped tokens available. Revisit if richer monitoring is needed.

3. **UniFi/OPNsense APIs**: Out of scope for Phase 2. Start with SSH-based investigation.
   API access documented in [Future: API Expansion](#future-api-expansion) for Phase 3.

4. **IP scoping**: Yes. `from="10.30.0.0/16"` in all `authorized_keys` entries.
   Defense-in-depth — even if the key leaks, it's only usable from the home LAN.
   Covers all VLANs since the laptop doesn't have a fixed IP.

5. **Phase 2 scope**: SSH (all 7 hosts) + HA API + Proxmox API. Lean and testable.
   Expand to OPNsense/UniFi/Plex APIs in Phase 3 as a follow-up TODO.
