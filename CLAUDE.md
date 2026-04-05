# Infrastructure Automation — Claude Code Guide

Personal infrastructure-as-code repository managing a home network of Raspberry Pis, an OPNsense firewall VM, a Proxmox hypervisor, and LXC containers via Ansible.

> For Ansible conventions, role creation, and testing strategy, see [AGENT_INSTRUCTIONS.md](AGENT_INSTRUCTIONS.md).

## Active Hosts

| Inventory Key | SSH Hostname | Platform | Function | Notes |
|---------------|-------------|----------|----------|-------|
| `dockassist` | `dockassist` | RPi | homeassistant | HA + Matter Server + Cloudflared (Docker) |
| `cobra` | `cobra` | RPi | media | Plex, Transmission, Samba |
| `hifipi` | `hifipi` | RPi | audio_playback | MPD, Shairport, Raspotify |
| `vinylstreamer` | `vinylstreamer` | RPi | audio_streaming | Icecast, Liquidsoap |
| `opnsense` | `opnsense` | FreeBSD VM | firewall | Unbound DNS, Mullvad WireGuard, CrowdSec |
| `proxmox` | `cwwk` | Debian | hypervisor | CWWK host for VMs and LXCs |
| `unifi-lxc` | `unifi` | LXC | network_controller | UniFi Network Application |

## Key Conventions

### Ansible Patterns
- **Variables over groups** — use `enable_*` toggles, never `in group_names`
- **No dead code** — delete disabled tasks; git has history
- **Variable naming**: `enable_*` (toggles), `*_dir` (paths), `{service}_*` (config)
- **Booleans**: always `true`/`false`, never `yes`/`no`
- **Config loading order**: `group_vars/all/` → `group_vars/{platform}` → `group_vars/{function}` → host overrides
- **Handlers**: notify with exact handler name to restart services on config change
- **Templates**: Jinja2 templates in `roles/{role}/templates/` → deployed to remote host
- **New roles**: set `primary_function` in inventory — `services.yml` auto-discovers the role

### Home Assistant Specifics
- **Tado heating via direct API** — uses `presenceLock` endpoint to set home/away
  - `tado_presence.sh` calls Tado API (OAuth2 refresh + presenceLock PUT)
  - Credentials in `/config/.tado_tokens` (created once via `tado_setup.sh` on dockassist)
  - HomeKit Controller entities (`climate.tado_smart_*`) still used for monitoring only
  - Group: `group.homekit_tado_climates` (8 radiator/thermostat entities)
- **Presence detection**: Companion App only → `group.persons` (home/not_home)
  - Home trigger uses `for: minutes: 3` to debounce GPS bouncing
  - Away trigger uses `for: minutes: 10` with template `!= "home"` (treats `unknown` as away)
- **HA Jinja2 in Ansible templates**: double-escape as `{{ '{{ ha_expression }}' }}`
- **Config path on remote**: `/home/{{ infrastructure_user }}/homeassistant/`
- **Docker containers**: `home-assistant`, `matter-server`, `cloudflared`
- **Deploy command**: `ansible-playbook ansible/playbooks/services.yml --limit dockassist`

### Monitoring Scripts
- POSIX `/bin/sh` for FreeBSD compatibility
- Use `enhanced_monitoring_wrapper` for heartbeats, state tracking, Slack alerts
- Self-healing: scripts attempt auto-fix before alerting
- Cron jobs defined in Ansible role tasks
- **Cron naming**: Ansible `cron` module identifies entries by `name` — renaming a cron job creates a duplicate unless the old name is explicitly removed with `state: absent`

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

All hosts are reachable via SSH (key-based auth). Use the **SSH Hostname** from the table above (not the inventory key). Two hosts differ:
- `proxmox` → `ssh cwwk`
- `unifi-lxc` → `ssh unifi`

For HA API queries: read the token from `{{ homeassistant_config_dir }}/secrets.yaml` on `dockassist`.

## Working with This Repo

- Edit templates in `ansible/roles/services/*/templates/`, then deploy with Ansible
- Never edit remote files directly — all config is managed from this repo
- Test changes with `--check --diff` before applying
- Commit only in-scope changes; don't stage unrelated files
