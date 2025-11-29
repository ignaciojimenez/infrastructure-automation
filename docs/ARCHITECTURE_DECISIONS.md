# Architecture & Strategy Decisions

Simple log of key technical decisions made in this project.

## Infrastructure Strategy

- **Ansible roles are self-healing** - Roles detect and fix missing configuration (e.g., hardware overlays, service configs)
- **Variables over groups** - Use feature toggles in `group_vars/` rather than inventory groups for flexibility
- **No dead code** - Delete disabled tasks, don't comment them out (git preserves history)
- **Testing on devpi first** - Always test changes on development host before production deployment
- **Generic scripts deploy to all hosts** - Prevents configuration drift, ensures consistency

## Hardware Configuration

- **Hardware config in Ansible, not SD card prep** - Roles configure device tree overlays, GPU settings, etc. automatically
- **Reboot handlers for hardware changes** - When firmware config changes, trigger automatic reboot
- **Resilient volume controls** - Audio mixer configuration checks available controls dynamically, doesn't fail on missing hardware

## Deployment & Provisioning

- **SD card provisioning is optional** - Can flash vanilla Raspberry Pi OS and let Ansible handle everything
- **SSH key management via GitHub** - Pull authorized_keys from GitHub profile for easy setup

## Naming Conventions

- Feature toggles: `enable_*` (e.g., `enable_monitoring`)
- Directory paths: `*_dir` (e.g., `scripts_dir`, `logs_dir`)
- Service config: `{service}_*` (e.g., `mpd_port`, `icecast_password`)
- Boolean values: Always use `true`/`false`, never `yes`/`no` (ansible-lint compliance)

## Monitoring & Observability

- **Enhanced monitoring wrapper** - All checks use wrapper for heartbeats and notifications
- **Self-healing health checks** - Scripts attempt auto-fix before alerting
- **State tracking** - Monitoring tracks issue state to avoid alert fatigue
- **Platform-specific monitoring** - Each platform runs it's own monitoring capabilities
- **POSIX-compliant scripts** - All scripts use `/bin/sh` for FreeBSD compatibility
- **Unified Slack webhooks** - All hosts share same monitoring/alert webhook configuration from vault

## Monitoring Strategy

Platform-specific monitoring scripts deployed to appropriate locations:
- **Proxmox (Debian)**: `/home/${USER}/.scripts/monitoring/`
- **OPNsense (FreeBSD)**: `/usr/local/bin/monitoring/`

All scripts are POSIX-compliant shell scripts for maximum portability. Monitoring uses centralized wrapper with Slack notifications and state tracking to prevent alert fatigue.


## Configuration Loading Order

1. `group_vars/all/main.yml` - Global defaults
2. `group_vars/{platform}.yml` - Platform-specific (raspberrypi, lxc, freebsd)
3. `group_vars/{primary_function}.yml` - Role-specific (audio_playback, dns, media)
4. `hosts.yml` host overrides - Rare, only when host truly differs

## Secrets & Vault Strategy

- **Encrypted vault committed to repository** - `vault.yml` uses Ansible Vault (AES256) and is committed
  - This is a personal infrastructure repo, not a shared/team repository
  - Vault password not stored in git
  - Vault password stored locally in macOS Keychain and retrieved via a helper script referenced by `ANSIBLE_VAULT_PASSWORD_FILE`
  - The same vault password can be reused across personal Ansible-based projects
  - Provides backup of encrypted configuration via GitHub
  - Common practice for personal infrastructure-as-code repos
- **Example files for onboarding** - `vault.yml.example` and `*.ini.example` files show structure without secrets
- **No plaintext secrets** - All sensitive data (tokens, passwords, keys) in vault only

## LXC Container Management

- **Hostname resolution fix** - Early fix in bootstrap.yml (line 78-88) adds hostname to /etc/hosts
  - Prevents sudo timeout issues caused by DNS lookup failures
  - Runs before any become operations to ensure success
  - Required for containers where hostname differs from DNS name (e.g., pihole-lxc vs pihole)
- **Container naming** - Proxmox adds `-lxc` suffix, DNS uses friendly names
  - Containers: `pihole-lxc`, `unifi-lxc` (actual hostnames)
  - DNS entries: `pihole`, `unifi` (user-friendly network names)
  - Both approaches valid, handled automatically

## DNS Architecture (Updated November 2025)

- **Unbound over PiHole** - Chose OPNsense native Unbound with blocklists instead of separate PiHole LXC
  - Simpler: One service instead of two
  - Native HA: Unbound on OPNsense is already highly available
  - Same features: Blocklists + static DNS entries available in Unbound
  - Less resource usage: No extra LXC container needed
  
- **VPN-first DNS** - DNS queries go through VPN tunnel for privacy
  - Primary: Forward to 10.64.0.1 (Mullvad DNS via WireGuard)
  - Fallback: 194.242.2.3 (Mullvad public DNS when VPN down)
  - Both Mullvad endpoints: Privacy preserved even during failover
  
- **Script-based failover** - Dynamic config switching vs static dual-forwarder
  - Avoids Unbound querying both in parallel
  - Clear visibility: Slack alerts on failover/recovery
  - Fast detection: 1-minute checks, 3-minute failover threshold
