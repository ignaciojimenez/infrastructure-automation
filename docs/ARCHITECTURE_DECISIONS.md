# Architecture & Strategy Decisions

Simple log of key technical decisions made in this project.

## Infrastructure Strategy

- **Ansible roles are self-healing** - Roles detect and fix missing configuration (e.g., hardware overlays, service configs)
- **Variables over groups** - Use feature toggles in `group_vars/` rather than inventory groups for flexibility
- **No dead code** - Delete disabled tasks, don't comment them out (git preserves history)
- **Generic scripts deploy to all hosts** - Prevents configuration drift, ensures consistency

## Hardware Configuration

- **Hardware config in Ansible, not SD card prep** - Roles configure device tree overlays, GPU settings, etc. automatically
- **Reboot handlers for hardware changes** - When firmware config changes, trigger automatic reboot
- **Resilient volume controls** - Audio mixer configuration checks available controls dynamically, doesn't fail on missing hardware

### cwwk Thermal Management (2026-06-30)

- **Why** - cwwk (Intel Core 3 N355, ~15W-class) hosts the OPNsense firewall (VM 100), so any thermal crash drops all internet. On 2026-06-30 it hard-reset with no kernel log/panic — a silicon **THERMTRIP** after a fan facing it was switched off during a heatwave. Root cause was confirmed by `package_throttle_count` (22,841 throttle events/boot; healthy ≈ 0), not by `sensors` (which reads a calm ~56°C between throttle cycles, and the kernel suppresses the throttle log line).
- **RAPL power cap** - Board ships with PL1 (sustained) = 35W into a marginal cooler. Capped PL1 to **20W** (still above the chip's 15W base TDP), PL2 (burst) left at 35W. Applied at boot by `cwwk-power-tuning.service` (oneshot, in `platform/proxmox` role); tunable via `proxmox_rapl_pl1_watts` / `enable_proxmox_power_tuning`. **No throughput cost** — at a 1 Gbps WAN the line is the bottleneck, not the CPU, so WireGuard/routing is unaffected. The cap is *insurance*: degraded airflow now throttles gracefully instead of THERMTRIP-ing.
- **Governor** - Host CPU governor set to `powersave` (intel_pstate dynamic; still boosts to max under load) — lower idle heat, no peak-performance cost.
- **Thermal forensics** - `save_temps.sh` (root cron `*/2`) logs temps + throttle counter to `/var/log/diagnostics/thermal-history.log` so a future thermal event is quantifiable (instantaneous-sample monitoring can't catch a fast runaway).
- **Thermal alerting** - `check_thermal.sh` (cron `*/5`, via `enhanced_monitoring_wrapper` → #home-alerts) alerts on the throttle-counter **delta** — the reliable signal. Temperature alerting was moved out of `check_proxmox_health.sh` into this dedicated check to avoid double-alerts. `check_kernel_errors.sh`'s `"temperature above threshold"` pattern is a no-op on this kernel (line suppressed) and is superseded by the counter-based check.
- **Still required** - The fan is the actual fix; the cap only widens the margin. Pending: confirm cwwk's UPS topology, consider a BIOS newer than 5.27 (2024-11).

## Deployment & Provisioning

- **SD card provisioning is optional** - Can flash vanilla Raspberry Pi OS and let Ansible handle everything
- **SSH key management via GitHub** - Pull authorized_keys from GitHub profile for easy setup
- **Ansible Vault password in macOS Keychain** - Stored under item `ansible-vault-master`, fetched by `bin/vault_pass.sh`; synced via iCloud Keychain so a fresh laptop only needs the repo clone

## Naming Conventions

- Feature toggles: `enable_*` (e.g., `enable_monitoring`)
- Directory paths: `*_dir` (e.g., `scripts_dir`, `logs_dir`)
- Service config: `{service}_*` (e.g., `mpd_port`, `icecast_password`)
- Boolean values: Always use `true`/`false`, never `yes`/`no` (ansible-lint compliance)

## Monitoring & Observability

- **Enhanced monitoring wrapper** - All checks use wrapper for heartbeats and notifications
- **Self-healing health checks** - Scripts attempt auto-fix before alerting
- **State tracking** - Monitoring tracks issue state to avoid alert fatigue
- **Platform-specific monitoring** - Each platform runs its own monitoring capabilities
- **POSIX-compliant scripts** - All scripts use `/bin/sh` for FreeBSD compatibility
- **Unified Slack webhooks** - All hosts share same monitoring/alert webhook configuration from vault
- **Auto-upgrades: pending counts are informational only** - Pending updates naturally accumulate between daily runs; only service/config issues trigger alerts
- **Persistent journald on all Pis (2026-07-14)** - `Storage=persistent` drop-in with SD-wear caps (100M total, 16M/file, compression) via the raspberrypi platform playbook (`enable_persistent_journal` toggle). Default volatile journal made the 2026-07-12 vinylstreamer reboot un-diagnosable. pstore/ramoops deliberately skipped: costs reserved RAM on 512MB Pis and wouldn't capture a power cut anyway
- **Journald cap on cwwk: explicit 4G (2026-07-16)** - Same drop-in pattern via `platform/proxmox`. cwwk was already persistent but only bounded by systemd's implicit min(10% fs, 4G); made it explicit at 4G (~3 months at the observed ~1.2G/month) — cwwk is the forensics-critical host (THERMTRIP history), disk cost is ~2%. unifi-lxc persists at ~100M; opnsense is FreeBSD syslog (persistent by default) — neither needs action

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

- **Hostname resolution fix** - Early fix in bootstrap.yml adds hostname to /etc/hosts
  - Prevents sudo timeout issues caused by DNS lookup failures
  - Runs before any become operations to ensure success
  - Required for containers where hostname differs from DNS name (e.g., `unifi-lxc` vs `unifi`)
- **Container naming** - Proxmox adds `-lxc` suffix, DNS uses friendly names
  - Container: `unifi-lxc` (actual hostname), DNS: `unifi` (user-friendly network name)
  - Handled automatically in inventory (`ansible_host` override)

## Proxmox Host Management

- **Inventory keys must match real hostnames** - bootstrap.yml writes `inventory_hostname` into `/etc/hosts`; a mismatch (e.g., key `proxmox` vs real hostname `cwwk`) corrupts hostname resolution and breaks sudo/PVE API
- **Skip hostname management for Proxmox** - Proxmox manages its own hostname for cluster/API identity; bootstrap guards hostname tasks with `when: platform_type != 'proxmox'`

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

## Home Assistant Architecture (Updated November 2025)

- **HA as central brain** - All automation logic centralized in Home Assistant
  - Bulb scenes/schedules → HA automations
  - Tado away/home mode → HA presence-based automations
  - Siri Shortcuts → Native HomeKit Bridge (no separate shortcuts needed)

- **Apple HomeKit as frontend only** - Voice control and remote access via Apple ecosystem
  - HomeKit Bridge exposes HA entities to Siri
  - HomePod Mini as Thread border router for Matter devices
  - No duplicate logic in Apple Home app

- **Matter Server as separate container** - Required for Eve sensor integration
  - Eve sensors use Matter multi-admin pairing (HomeKit + HA)
  - Thread network shared between Apple Home and HA via border router
  - Matter Server runs alongside HA container on dockassist

- **Presence detection via Companion App + Tado fallback** - Robust dual-source tracking
  - Primary: Mobile Companion App device trackers (real-time GPS)
  - Fallback: Tado device trackers (30-minute freshness window)
  - Combined presence sensors: `binary_sensor.choco_presence`, `binary_sensor.candela_presence`
  - group.persons for home/away state
  - Guest mode toggle disables automatic away
  - 10-minute delay prevents false triggers

- **Cloudflare Tunnel for remote access** - Secure external access without port forwarding
  - Separate container: `cloudflared`
  - Token-based auth from Ansible vault
  - External URL: ha.ignacio.systems

- **Docker deployment** - Not Home Assistant OS
  - Containers: `home-assistant`, `matter-server`, `cloudflared`
  - Network mode: host (required for Matter/Thread)
  - Privileged mode: enabled for USB/Bluetooth access

- **Shelly Duo G3 bulbs replace Wyze (July 2026)** - Local control over cloud dependency
  - Wyze bulbs died with HA 2026.7.0: certifi dropped the retired DigiCert Global Root CA that Wyze's cloud API still chains to (upstream Wyze bug, no local fallback)
  - Shelly integration is local push — no cloud, no optimistic-state lying, HA state reflects the device
  - Bulbs renamed in the entity registry to the previous semantic IDs (`light.floor_lamp`, `light.book_floor_lamp`, `light.table_lamp`, `light.floor_lamp_new`) so scenes, `light.all_lights`, and automations carried over unchanged
  - `wyzeapi` custom component + config entry removed

- **Docker cleanup via weekly prune** - Prevents disk space issues from old images
  - `docker system prune -a -f` runs weekly via cron
  - Each HA update leaves ~2GB of old images behind
  - Weekly schedule balances cleanup frequency vs unnecessary runs
  - Use `special_time: "weekly"` in Ansible cron tasks (not `cron_day` which is day-of-month)

## Backup Strategy

- **age encryption (asymmetric)** — Public key on all hosts, private key in password manager only. Hosts can encrypt without ever seeing the secret key.
- **curlbin as offsite storage** — Simple HTTP upload/download. Encrypted backups are safe on any public endpoint.
- **USB recovery drive is supplement, not replacement** — Fast-path for "NVMe died" scenario only. curlbin offsite backups remain the primary disaster recovery path. USB and NVMe are co-located — catastrophic event loses both.
- **Mount-on-demand for USB** — fstab `nofail,x-systemd.automount` prevents boot dependency. Script mounts/unmounts around each sync. Disconnection triggers Slack alert via enhanced_monitoring_wrapper failure.
- **Two-generation rotation on USB** — `current/` and `previous/` directories. Protects against copying a corrupt vzdump while fitting within drive capacity.
- **Root-owned helper for privileged USB operations** — Follows `pve_backup_helper` pattern. Keeps sudoers rules minimal and auditable. One helper script = one sudoers entry.
- **vzdump schedule is Proxmox-managed, not Ansible** — Proxmox UI/API manages `/etc/pve/jobs.cfg`. Accepted trade-off: simpler than fighting Proxmox's own scheduler, but must be manually reconfigured after a rebuild (documented in USB recovery checklist).

## Agent Access

- **Dedicated `read_agent` user** — Separate user for autonomous agent SSH access, not reusing human credentials. Read-only sudo rules, no group memberships.
- **Password-protected SSH key outside Secretive** — Ed25519 key at `~/.ssh/read_agent_ed25519` on control machine, passphrase in Ansible Vault. Secretive blocks unattended access by design; agent key is intentionally outside it.
- **IP-restricted authorized_keys** — `from="<control-machine-IP>"` on every host. Even if the key leaks, it's only usable from one source IP.
- **Phased API rollout** — Phase 2: SSH + HA API + Proxmox API. Phase 3: OPNsense/UniFi/Plex APIs. Start lean, expand once SSH-based investigation proves the pattern.
- **No secret access for agents** — Agent cannot read vault files, `.tado_tokens`, `secrets.yaml`, `.netrc`, or any credential files belonging to other users.
- **SSH config aliases bypass Secretive** — Generic `Host *-agent` pattern uses `ProxyCommand` to strip the `-agent` suffix and `IdentityAgent SSH_AUTH_SOCK` to override Secretive. No per-host config — `ssh anyhost-agent` works for any resolvable hostname.
- **OPNsense sshd reload, not restart** — `service openssh onereload` (SIGHUP) instead of restart. Full restart regenerates host keys and risks config overwrites by OPNsense's auto-generator.
- **`read_agent` on OPNsense is `pw`-managed and expected to be wiped by upgrades — do not try to move it into `config.xml`** — Settled 2026-07-21 after testing the config.xml route and hitting a hard wall. A firmware upgrade (26.1.9, 2026-06-13) silently deleted the Ansible-created account, leaving agent access to the firewall broken for ~3 months: `local_sync_accounts` (`auth.inc`) enumerates accounts with uid ≥ 2000 and reconciles them against `config.xml`, deleting anything not there. The obvious fix — create the user in the OPNsense user manager so it lives in `config.xml` — **does not work for a least-privilege account**: `local_user_set` (`auth.inc:351`) forces `shell` to `/usr/sbin/nologin` for any user failing `userIsAdmin()`, which is `userHasPrivilege(…, 'page-all')` — full GUI administrator. OPNsense has no concept of a non-admin account with a login shell; the `<shell>` field in `config.xml` is ignored unless the user is an admin. Tested live: the UI-created user authenticated by key and then died on `This account is currently not available`. Worse, a config.xml-managed account gets its shell reset on *every* config apply, not just upgrades. So the account stays `pw`-managed and out-of-band by design. Mitigations: recovery is one idempotent command (`ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense`, ~9s from a fully wiped state, verified), and detection rides on the Agent LXC's Tier 1 reachability sweep. The alternative, if the repair ever becomes annoying, is to drop SSH for opnsense and use a privilege-scoped OPNsense API key (durable in config.xml, needs no shell) at the cost of losing `service -e` / `cscli` / `pfctl` diagnostics.
- **OPNsense sshd overrides live in `sshd_config.d/`, never in `sshd_config`** — `openssh.inc` regenerates `/usr/local/etc/ssh/sshd_config` from config.xml with a hardcoded `AllowGroups wheel`, so the role's former `lineinfile` edit was erased by upgrades *and* by any SSH settings change. The generated config `Include`s `/usr/local/etc/ssh/sshd_config.d/*.conf` at the very top and sshd takes the first value per keyword, so a fragment there wins. `agent_access` now ships `10-read_agent.conf`; `sshd_config` itself is left at OPNsense's native `AllowGroups wheel`, making a regeneration a no-op. Verified with `sshd -T` and a live login after reverting sshd_config to its native state.
- **Root shell hardening is Debian-only** — `ssh_hardening.yml` sets `shell: /sbin/nologin` on root only when `os_family == 'debian'` (via `omit` elsewhere). On OPNsense root's shell is `/usr/local/sbin/opnsense-shell`, the VGA/serial console admin menu; replacing it would remove the console recovery path. `password_lock` still applies on both platforms.
- **HA non-admin is not read-only** — HA non-admin users can call entity services (lights, switches). Only system operations (restart, add-ons) are blocked. Read-only is enforced by convention (GET requests only), not by HA permissions.
- **Proxmox privsep requires user + token ACLs** — With `--privsep 1`, effective permissions = intersection of user and token. Both must have PVEAuditor role assigned, not just the token.
- **Debounce at the detector, not in HA** — vinyl phantom-start filtering lives in `detect_audio` (3 consecutive active chunks, ~1s), which sees the raw signal; HA automations trigger instantly. Defense in depth is a cycling watchdog alert (plug on >3×/h), never a `for:` delay that would tax every real listening session.
- **MQTT push over HA polling for latency-sensitive state** — HA's MPD config entry polls (~10s, no scan_interval knob); detect_audio publishes retained play state to Mosquitto instead, cutting needle-drop→amp-on from ~10s to ~1–2s. Same pattern as raspotify's `spotify_event.sh`.
- **Broadlink codes: HA owns, Ansible seeds** — learned IR codes live in HA's `.storage` (rewritten on every `remote.learn_command`), so Ansible deploys the captured copy only when the file is missing (`force: false`) — disaster-recovery seed, not enforced state. Re-capture into the role after learning new positions.
