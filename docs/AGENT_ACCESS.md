# Agent Access — Read-Only Infrastructure Access

Read-only infrastructure access for AI agents and automation tools. Enables autonomous
investigation of any system (SSH, APIs, logs) without interactive authentication.

**Status:** Phase 2 — SSH access deployed and validated on all 7 hosts (2026-04-06). HA + Proxmox API tokens pending.

---

## Problem

SSH keys on this control machine are managed by [Secretive](https://github.com/maxgoedjen/secretive),
which stores them in the macOS Secure Enclave and requires biometric (Touch ID) authentication
for every use. This is great for human-interactive SSH but blocks any unattended access —
AI agents, cron-driven scripts, or automation tools cannot SSH to hosts without a human
physically present to authenticate. The same limitation applies to API queries routed
through SSH tunnels.

---

## Architecture Overview

Two access channels, both read-only. Phased rollout:

- **Phase 2 (this implementation):** SSH to all hosts + HA API + Proxmox API
- **Phase 3 (future TODO):** OPNsense API, UniFi API, Plex API (see [Future: API Expansion](#future-api-expansion))

```
Agent (Claude Code, scripts, automation tools)
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

At runtime, agents load the passphrase into their own `ssh-agent` instance and connect
using `ssh hostname-agent` aliases (see [SSH Config](#step-4--ssh-config-on-control-machine)).

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
| Token creation | See [Step 3](#step-3--create-api-userstokens-manual-one-time) for steps |
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
| Token creation | See [Step 3](#step-3--create-api-userstokens-manual-one-time) for commands |
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

- **SSH**: All logins appear in `/var/log/auth.log` (Debian) or `/var/log/audit/audit_*.log` (OPNsense/FreeBSD).
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

### Step 2 — Ansible Role: `roles/agent_access`
The role handles everything cross-platform (Debian + FreeBSD):
- Creates `read_agent` user with locked password and `/bin/sh` shell
- Deploys SSH `authorized_keys` with `from=` IP restriction (public key from vault)
- Deploys platform-specific sudoers file to `/etc/sudoers.d/read_agent`
- Validates sudoers syntax with `visudo -cf %s` before applying
- On OPNsense: adds `read_agent` to sshd's `AllowGroups` (see caveats above)

Deploy to all hosts:
```bash
ansible-playbook ansible/playbooks/system/agent_access.yml
```
Or as part of a full site deploy — the role is included in `site.yml` (Phase 4b).

### Step 3 — Create API Users/Tokens (Manual, One-Time)

**Home Assistant:**
1. Go to HA UI → Settings → People → Users → Add User
2. Create user `read_agent` with a strong password, **non-admin**
3. Log in as `read_agent` → Profile → Long-Lived Access Tokens → Create Token
4. Copy the token and store in vault as `vault_ha_agent_token`

**Proxmox** (run on cwwk as root or with sudo):
```bash
pveum user add read_agent@pve --comment "AI agent read-only"
pveum user token add read_agent@pve readonly --privsep 1
# Note: quote the token ID to prevent bash ! expansion
pveum acl modify / --tokens 'read_agent@pve!readonly' --roles PVEAuditor
```
Copy the token `value` from the output and store in vault as `vault_proxmox_agent_token`.

Store all tokens in `vault.yml`.

### Step 4 — SSH Config on Control Machine

**The problem:** If the control machine uses an SSH agent that requires interactive
authentication (e.g., Secretive, FIDO2 keys, smartcards), the `IdentityAgent` directive
in `~/.ssh/config` forces all SSH connections through that agent — including agent connections
that need to be unattended. A normal `-i keyfile` flag is ignored when `IdentityAgent` is set.

**The solution:** A generic `Host *-agent` pattern in `~/.ssh/config` that:
1. Overrides the interactive agent with the standard `SSH_AUTH_SOCK` environment variable
2. Strips the `-agent` suffix from the hostname to resolve the real target
3. Uses a separate connection path to avoid conflicts with human SSH sessions

Add this block **before** any `Host *` block in `~/.ssh/config`:
```
# Agent access — bypasses interactive SSH agent for unattended connections
# Usage: ssh <hostname>-agent "command"  (e.g., ssh dockassist-agent "uptime")
# Generic: works for any resolvable hostname, no per-host config needed.
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
- `ssh dockassist-agent` → `ProxyCommand` strips `-agent` → `nc dockassist 22`
- `IdentityAgent SSH_AUTH_SOCK` tells SSH to use the real `SSH_AUTH_SOCK` env var
  instead of the hardcoded interactive agent path (e.g., Secretive socket)
- `IdentitiesOnly yes` ensures only the specified key is offered, not all agent keys
- `ControlPath none` prevents multiplexing conflicts with human SSH sessions
- `StrictHostKeyChecking accept-new` auto-accepts first-time host keys for `-agent` aliases
- Adding a new host to the infrastructure requires zero SSH config changes

**Agent workflow** (passphrase from Ansible Vault as `vault_agent_ssh_passphrase`):
```bash
# 1. Start a dedicated ssh-agent (isolated from the interactive agent)
eval $(ssh-agent -s)

# 2. Load the agent key (supply passphrase when prompted)
ssh-add ~/.ssh/read_agent_ed25519

# 3. Connect to any host using the -agent suffix
ssh dockassist-agent "sudo docker ps"
ssh opnsense-agent "sudo pfctl -s info"
ssh cwwk-agent "sudo qm list"

# 4. Clean up when done
kill $SSH_AGENT_PID
```

**If not using Secretive:** The `Host *-agent` block still works — it's just a convenient
alias pattern. The `IdentityAgent SSH_AUTH_SOCK` is a no-op when there's no conflicting
agent override in `Host *`. The key benefit is the hostname suffix convention and
dedicated user/key separation.

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
