# Infrastructure Automation — Claude Code Guide

Personal infrastructure-as-code repository managing a home network of Raspberry Pis, an OPNsense firewall VM, a Proxmox hypervisor, and LXC containers via Ansible.

## Repository Structure

```
ansible/
  inventory/
    hosts.yml                       # Unified multi-platform inventory
    group_vars/all/main.yml         # Global defaults (source of truth)
    group_vars/all/vault.yml        # Encrypted secrets (AES256)
    group_vars/{function}.yml       # Role-specific vars (homeassistant, media, dns, etc.)
  playbooks/
    site.yml                        # Full orchestration: bootstrap → platform → services → monitoring
    services.yml                    # Service deployment (loads roles by primary_function)
    deploy_monitoring.yml           # Monitoring scripts to all hosts
    system/                         # Bootstrap, baseline, updates, validation
    platform/                       # Platform-specific (debian, freebsd, raspberrypi, lxc, proxmox)
  roles/services/                   # One role per service (homeassistant, docker, plex, etc.)
scripts/
  common/enhanced_monitoring_wrapper  # Shared monitoring wrapper (heartbeats, state tracking, Slack)
  services/{service}/               # Per-service monitoring/management scripts (POSIX sh)
docs/                               # Architecture decisions, infrastructure state, monitoring docs
```

## Active Hosts

| Host | Platform | Function | Notes |
|------|----------|----------|-------|
| `dockassist` | RPi | homeassistant | HA + Matter Server + Cloudflared (Docker) |
| `cobra` | RPi | media | Plex, Transmission, Samba |
| `hifipi` | RPi | audio_playback | MPD, Shairport, Raspotify |
| `vinylstreamer` | RPi | audio_streaming | Icecast, Liquidsoap |
| `opnsense` | FreeBSD VM | firewall | Unbound DNS, Mullvad WireGuard, CrowdSec |
| `proxmox` | Debian | hypervisor | CWWK host for VMs and LXCs |
| `unifi-lxc` | LXC | network_controller | UniFi Network Application |

## Key Conventions

### Ansible Patterns
- **Variables over groups** — use `enable_*` toggles, never `in group_names`
- **No dead code** — delete disabled tasks; git has history
- **Variable naming**: `enable_*` (toggles), `*_dir` (paths), `{service}_*` (config)
- **Booleans**: always `true`/`false`, never `yes`/`no`
- **Config loading order**: `group_vars/all/` → `group_vars/{platform}` → `group_vars/{function}` → host overrides
- **Handlers**: notify with exact handler name to restart services on config change
- **Templates**: Jinja2 templates in `roles/{role}/templates/` → deployed to remote host

### Home Assistant Specifics
- **Tado heating via HomeKit Controller** — native Tado integration deprecated
  - Entities: `climate.tado_smart_*` (8 radiator/thermostat entities)
  - Group: `group.homekit_tado_climates`
  - **No preset_mode support** — HomeKit climates only support `hvac_mode: off/heat`
  - Away = `climate.set_hvac_mode` off; Home = `climate.set_hvac_mode` heat
- **Presence detection**: Companion App + Tado fallback → `group.persons` (home/not_home)
  - Hourly device-tracker polling causes brief `unknown` blips on the group
  - Use `!= "home"` template triggers instead of `to: "not_home"` state triggers with `for:`
- **HA Jinja2 in Ansible templates**: double-escape as `{{ '{{ ha_expression }}' }}`
- **Config path on remote**: `/home/choco/homeassistant/`
- **Docker containers**: `home-assistant`, `matter-server`, `cloudflared`
- **Deploy command**: `ansible-playbook ansible/playbooks/services.yml --limit dockassist`

### Monitoring Scripts
- POSIX `/bin/sh` for FreeBSD compatibility
- Use `enhanced_monitoring_wrapper` for heartbeats, state tracking, Slack alerts
- Self-healing: scripts attempt auto-fix before alerting
- Cron jobs defined in Ansible role tasks

### Secrets
- Ansible Vault (`vault.yml`) committed encrypted — vault password in macOS Keychain
- Templates reference vault vars as `{{ vault_* }}`
- Never hardcode tokens, passwords, or webhooks

## Deployment

```bash
# Full deploy to a host
ansible-playbook ansible/playbooks/site.yml --limit hostname

# Service-only update (e.g., after editing HA templates)
ansible-playbook ansible/playbooks/services.yml --limit dockassist

# Deploy monitoring scripts to all hosts
ansible-playbook ansible/playbooks/deploy_monitoring.yml
```

## SSH Access

All hosts are reachable by hostname via SSH (key-based auth). Use `ssh hostname` directly.
For HA API queries: read the token from `/home/choco/homeassistant/secrets.yaml` on `dockassist`.

## Working with This Repo

- Edit templates in `ansible/roles/services/*/templates/`, then deploy with Ansible
- Never edit remote files directly — all config is managed from this repo
- Test changes with `--check --diff` before applying
- Commit only in-scope changes; don't stage unrelated files
