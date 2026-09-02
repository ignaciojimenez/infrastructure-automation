# Architecture & Strategy Decisions

Simple log of key technical decisions made in this project.

## Contents

**Standing rules.** Consult before designing anything new; each entry says what was decided and why, so a settled question is not re-litigated.

- [Infrastructure Strategy](#infrastructure-strategy)
- [Hardware Configuration](#hardware-configuration)
- [Deployment & Provisioning](#deployment--provisioning)
- [Naming Conventions](#naming-conventions)
- [Monitoring & Observability](#monitoring--observability)
- [Configuration Loading Order](#configuration-loading-order)
- [Secrets & Vault Strategy](#secrets--vault-strategy)
- [Disclosure tiering — what goes in a public repo](#disclosure-tiering--what-goes-in-a-public-repo)
- [LXC Container Management](#lxc-container-management)
- [Proxmox Host Management](#proxmox-host-management)
- [DNS Architecture (Updated November 2025)](#dns-architecture-updated-november-2025)
- [Home Assistant Architecture (Updated November 2025)](#home-assistant-architecture-updated-november-2025)
- [Backup Strategy](#backup-strategy)
- [Agent Access](#agent-access)
- [Test Environments (2026-08-18)](#test-environments-2026-08-18)
- [Agent LXC — Fleet Observer (CT 103, 2026-07-22)](#agent-lxc--fleet-observer-ct-103-2026-07-22)

---


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
- **KSM off** (2026-08-16, measured 2026-08-02) - `ksmtuned` is **masked** via `proxmox_disable_ksm`. KSM's page scan is continuous low-level CPU across every core, worth **~3 °C** of package temperature here — enough to matter because throttling is a *threshold* effect, not a linear one (throttles collapsed from ~3,500/hr to ~0/hr on the day it was turned off, at 0.7 °C **higher** ambient). It also pays nothing back on this guest topology: `general_profit` was **negative** (~192 MiB of rmap overhead against ~208 KiB actually shared), because cwwk runs one large FreeBSD VM plus LXCs that already share the host kernel. Masked rather than disabled because the unit ships `preset: enabled`, so `disabled` is precisely the state a rebuild undoes. Set `proxmox_disable_ksm: false` to hand KSM back if guests ever become many near-identical VMs. Any future thermal comparison on cwwk **must record `/sys/kernel/mm/ksm/run`**, or it is uninterpretable.
- **Power tuning fails loudly** (2026-08-16) - `cwwk_power_tuning.sh` reads every write back and exits non-zero on mismatch, so a rejected cap makes the oneshot unit go `failed`. Previously both writes were `|| true` and the `[ -w ]` guards skipped silently, so the unit reported success whether or not it had applied anything — and logged nothing either way, leaving no evidence of what any past boot actually set. Because firmware defaults can coincide with the targets, the script logs `before -> after` rather than just the final value: a correct reading does not prove the script did it.
- **Thermal forensics** - `save_temps.sh` (root cron `*/2`) logs temps + throttle counter to `/var/log/diagnostics/thermal-history.log` so a future thermal event is quantifiable (instantaneous-sample monitoring can't catch a fast runaway).
- **Thermal alerting** - `check_thermal.sh` (cron `*/5`, via `enhanced_monitoring_wrapper` → #home-alerts) alerts on the throttle-counter **delta** — the reliable signal. Temperature alerting was moved out of `check_proxmox_health.sh` into this dedicated check to avoid double-alerts. `check_kernel_errors.sh`'s `"temperature above threshold"` pattern is a no-op on this kernel (line suppressed) and is superseded by the counter-based check.
- **Still required** - The fan is the actual fix; the cap only widens the margin. Pending: confirm cwwk's UPS topology, consider a BIOS newer than 5.27 (2024-11).

## Deployment & Provisioning

- **SD card provisioning is optional** - Can flash vanilla Raspberry Pi OS and let Ansible handle everything
- **`config.txt` lives on the boot partition, at `/boot/firmware/config.txt`** (2026-08-23) - On Bookworm `/boot/config.txt` is a 112-byte placeholder whose first line reads `DO NOT EDIT THIS FILE`. Writing an overlay there fails **silently**: the file accepts the line and nothing reads it. Resolve the path from where the boot partition is actually mounted rather than hardcoding either, so the same task keeps working on Bullseye where `/boot` *is* the boot partition. Never `backup: true` on that file — Ansible names backups with colons, which vfat rejects
- **The Wi-Fi radio is not optional on every wired host** (2026-08-23) - `--no-wifi` in `rpi-provisioner` writes `dtoverlay=disable-wifi`, removing the interface. dockassist is wired but needs its radio for the Thread border-router leg above; its preset pins `disable_wifi: false`
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
- **`read_agent` is in `systemd-journal` (2026-08-23)** - Persistent journald (2026-07-14, below) was added so a reboot could be diagnosed after the fact, but the tier that does the diagnosing was never given read rights, so it bought nothing for 40 days. Measured on hifipi: `read_agent` sits in no supplementary group, `journalctl -k` returns "-- No entries --", and journalctl prints the remedy itself ("Users in groups 'adm', 'systemd-journal' can see all messages"). The 2026-08-23 vinylstreamer investigation still reported "dmesg … aren't readable by this account". `systemd-journal` and not `adm`: adm additionally opens `/var/log/*` including auth logs, which a read-only investigator does not need. Debian only — FreeBSD has no journal. **Persistence without read access is not observability**
- **The vinylstreamer plug cooldown postpones a cycle, it does not cancel one (2026-08-23)** - `vinylstreamer_cycle_cooldown_hours` was enforced only at trigger time, and the trigger was a bare state-transition into `off`. Measured: the host dropped 01:58:06, the automation fired correctly at 02:13:06, refused because a cycle had run 29 min earlier, and then never re-evaluated — the cooldown expired at 07:44 with the host still down and nothing asked again, leaving it eligible-but-untried for 8 h until a human noticed. A `time_pattern` re-check every `vinylstreamer_down_after_minutes` now re-arms it, so the config's stated meaning ("at most one cycle per N hours") is what actually happens (N lowered 6 → 1 on 2026-08-24, once a refusal meant "later" rather than "never") rather than "at most one cycle per outage, none if the outage began inside the window". Repeat decisions post to #home-logging, not the watched channel, so one outage pages once per *decision* and not once per check. **A rate limit evaluated only on an edge is a veto**
- **W1 is a NetworkManager misdiagnosis, and the fix is a conf.d drop-in (2026-08-24)** - vinylstreamer's lockout is not auth, not signal loss, not a crash: the host stays fully running. Association times out (`ASSOC-REJECT status_code=16` with an **all-zero BSSID** — no AP ever answered, wpa_supplicant raised the reject itself), NM logs "association took too long", asks for new secrets, logs *"secrets exist. No new secrets needed."*, burns its retries and lands on `failed (reason 'no-secrets')` — a reason meaning "a human must intervene" — then emits no further wlan0 line for the rest of the boot. Proven running-not-halted by accident: the host's own health check ran at 16:10:02 with every service active while HA had it offline 15 min, and `uptime -s` puts the boot 25 s later. Fixed via `/etc/NetworkManager/conf.d/10-wifi-lockout.conf` (`[main] autoconnect-retries-default=0`, `[connection] wifi.powersave=2`) rather than `nmcli con modify`, because the `preconfigured` profile is Raspberry-Pi-Imager-managed and already defers both properties to the globals — so setting globals configures it without owning a profile a re-image regenerates. Values verified against `man 5 nm-settings-nmcli` on the host: *"Zero means forever, -1 means the global default (4 times if not overridden)"*, `powersave` *"disable (2)"*. **Powersave verified live; retry-forever is NOT synthetically verifiable** — `nmcli con down` blocks autoconnect by user request and a clean disassociation never reaches the retry path, so the next real lockout is the test
- **Outage duration is measured from a stamped input_datetime, not from `last_changed` (2026-08-24)** - An HA restart re-creates entities and resets `last_changed`, so the recovery message announced a **22-hour** outage as "22 min" (restart 23:24, recovery 23:46), and would have *suppressed entirely* any recovery landing under the debounce after a restart. `input_datetime.vinylstreamer_offline_since` survives restarts and is stamped only on a genuine `on -> off` edge — `from: "on"` is load-bearing, since a restart walks every entity through `unavailable -> off` and would otherwise overwrite the real start time. 🔴 **An unset `input_datetime` does not read as null: it defaults to TODAY AT MIDNIGHT**, a perfectly valid timestamp, so a naive "have we stamped?" test passes on a value nobody wrote — measured, it would have reported 21.8 h. Guarded with a pre-2000 sentinel (`initial: "1970-01-01 00:00:00"`)
- **A check that cannot persist state must fail, not pass (2026-08-24)** - `check_nic_stalls.sh` alerts on a delta, so without a writable state file every run is a first run: green, exit 0, structurally incapable of alerting. It happened immediately — `/var/log/monitoring-state` is created by the **proxmox** platform role and therefore does not exist on a Pi, and the check ran clean twice on dockassist while being inert. It now refuses to run rather than pass. Two adjacent traps, both found by forcing the condition rather than reading the code: `grep -c` prints `0` **and exits 1** when there are no matches, so a `|| echo 0` fallback yields `"0\n0"` and reports a *journal read error* on precisely the healthy hosts that have never stalled; and "cannot read the journal" must be probed separately from "found nothing", or a blind check reports a clean bill of health. **Delta checks alert on the delta, never on presence** — the journal keeps historical lines forever, so a presence test fires about the same old event until it is muted
- **Reachability checks take three samples, not one (2026-08-23)** - `check_vpn.sh` used a bare `ping -c 1`, so a single dropped packet paged the watched channel; ICMP loss inside a UDP-encapsulated WireGuard tunnel is normal, not a fault. Measured on cobra: old form exits 1 after **10 s** (reproducing the alert's "Duration: 10 seconds" exactly), new `-c 3 -W 2` exits 1 after 4 s and 0 after 2 s. Per `man 8 ping`, exit 1 requires receiving *no* reply at all — the "fewer than count" clause applies only with a deadline (`-w`), which is deliberately not used — so one or two lost packets still pass. Matches `binary_sensor.vinylstreamer_online`, which already probed this way
- **Journald cap on cwwk: explicit 4G (2026-07-16)** - Same drop-in pattern via `platform/proxmox`. cwwk was already persistent but only bounded by systemd's implicit min(10% fs, 4G); made it explicit at 4G (~3 months at the observed ~1.2G/month) — cwwk is the forensics-critical host (THERMTRIP history), disk cost is ~2%. unifi-lxc persists at ~100M; opnsense is FreeBSD syslog (persistent by default) — neither needs action
- **SMART monitoring is NVMe-health, not ATA-attributes (2026-07-26)** - The two non-redundant data drives (cwwk `rpool` `/dev/nvme0n1`, cobra Plex `/dev/sda`) are both NVMe, so `check_smart_health.sh` parses the NVMe health log (`smartctl -j -x`, JSON) — `critical_warning`, `available_spare` vs the drive's own threshold, `percentage_used`, `media_errors`, temperature — not ATA attributes like reallocated-sector count. Gated per-host via `enable_smart_monitoring` + `smart_devices` (a cross-cutting `smart_monitoring` role, same shape as `agent_access`)
- **cobra T7 needs `-d sntasmedia` (2026-07-26)** - The Samsung T7 is an NVMe SSD behind an ASMedia USB bridge; plain smartctl and `-d sat` both fail to pass SMART through. Device specs carry an explicit type prefix (`sntasmedia:/dev/sda`, `nvme:/dev/nvme0n1`) so no fragile auto-detection. Boot media (SD card, USB-flash recovery) is out of scope — no useful SMART, and the recovery drive is covered by backup-freshness monitoring
- **smartd daemon masked (2026-07-26)** - The `smartmontools` package auto-enables the `smartd` daemon; we poll on-demand via cron instead, so the role masks `smartmontools.service` and clears its failed state. smartd was failing on cobra (default `DEVICESCAN` can't reach the T7 through its USB bridge) — the "failing smartmontools unit" the agent LXC surfaced. One SMART path (cron), no redundant daemon

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

## Wireless — PMF on the IoT SSID is refused, not pending

*Decided 2026-09-02, after testing. Do not re-propose.*

The IoT SSID runs `pmf_mode=disabled` while the other four are `optional`. This is
a real weakness — without 802.11w, management frames are unauthenticated and clients
can be deauthenticated by anyone in RF range — and the segment it fronts carries the
devices that switch **heating and mains power**.

🔴 **It stays that way. The IoT devices cannot associate with PMF enabled** —
verified by the operator, not assumed from the ESP32 datasheet. Enabling it does not
harden the segment; it **removes the segment**, taking the heating and the mains
plugs offline. A control that disables what it protects is not a control.

📌 **The argument that will be made again, and why it does not reopen this.** A
future reader will notice the weakness is still present and propose fixing it. That
reasoning is *correct and already weighed*: the finding is accurate, the severity is
accurate, and the fix was tested and rejected on availability grounds. **This is an
accepted trade-off, not an oversight and not a backlog item.** It was carried as
TODO item 31 and discarded rather than deferred, precisely so nobody schedules work
that breaks the house.

**What actually limits the residual risk**, none of which depends on PMF:
- The IoT VLAN is the most restricted segment in the estate — its gateway does not
  even answer ICMP from inside it (see `docs/NETWORK.md`).
- The attack requires **RF proximity**. It is not remotely reachable.
- `pmf_mode` is advertised in the beacon, so redacting the SSID name never hid this
  from anyone in range — see the disclosure-tiering rule below for why the name was
  moved anyway.

**What would legitimately revisit it:** replacing the IoT devices with PMF-capable
hardware, or moving the mains-switching devices to a different SSID that can run
`optional`. Both are hardware/topology changes, not a toggle.

## Disclosure tiering — what goes in a public repo

*Adopted 2026-08-30, closing TODO item 24.*

This repo is **public on purpose**: it is a portfolio as much as an automation
tree. It is also the only written record of a real home network. Those two jobs
pull in opposite directions, and "write less" resolves them badly — a document
nobody can use is not a security control, it is just a worse document.

The rule is therefore **not** *how sensitive is this fact*, which produces
endless argument. It is a single discriminator:

> 🎯 **Does this line shorten the path from *"stand within radio or physical
> range"* to *"know which specific weakness to hit"*?**

A fact that is already broadcast, printed on the box, or resolvable in DNS costs
nothing to publish. A fact that **correlates** two of those — this name lands in
that segment, that segment holds the mains-power devices, this one has the weaker
setting — is the thing an attacker would otherwise have to be on site to learn.
Publish the mechanism; keep the correlation local.

**Tier 0 — publish.** Design intent, mechanisms, reasoning, failure modes,
corrections. RFC1918 subnets and VLAN purposes. Host names, roles and their
Ansible config. Decisions and the arguments behind them. Public DNS names.
*This is the tier that makes the repo worth showing, and it should stay generous.*

**Tier 1 — `docs/local/` (gitignored).** Correlations and target lists:
- SSID → VLAN → isolation → PMF mapping, and which SSID carries which weakness
- console URLs, ports, and their observed auth state (`docs/local/CONSOLES.md`)
- MAC addresses and any device↔person↔room mapping
- third parties' names, wherever they appear as identifiers
- anything that reads as "here is the soft spot, and here is where it lives"

**Tier 2 — vault only.** Keys, tokens, password hashes, PSKs, WAN addressing,
WireGuard public keys and endpoints. Never in a tracked file, encrypted or not,
and never in `docs/local/` either.

📌 **A redaction in a Tier 0 file must say what it hid and where it went**, or
the document rots into hints. Leave the finding, its mechanism and its severity
in place; move only the identifier. `docs/NETWORK.md` findings 8 and 9 are the
worked example.

⚠️ **Redaction narrows future exposure only.** Anything that was ever committed
stands in git history, in every clone and in every fork, and GitHub serves the
old blob at its commit SHA. A history rewrite is a separate, deliberate decision
with its own costs — it force-pushes a public repo and still cannot recall what
has been read. **Never treat a redaction as a remediation for the underlying
weakness**: the fix for "PMF is disabled on that SSID" is enabling PMF.

🔒 **`docs/local/` is untracked, not unbacked — and the difference matters.**
Gitignored means *out of the public repo*, not *confined to this machine*: the
tree lives under `~/Documents`, which syncs to iCloud Drive (verified 2026-09-01
— `docs/local/` is visible there). So the tier boundary is "never in public git",
and iCloud is an acceptable home for correlations. **It is not an acceptable home
for secrets** — those stay in `vault.yml`, which is encrypted before it ever
touches any sync. If `docs/local/` ever grows something that would be expensive
to re-derive *and* must survive an Apple-account loss, put it in the R2 backup
set — see `docs/BACKUP_AND_RECOVERY.md`.

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

- **The Thread border router must be on a VLAN dockassist is on-link with** (2026-08-23)
  - dockassist has no 802.15.4 radio, so every Matter-over-Thread packet crosses
    a border router — today the HomePod "Bano"
  - The BR announces the route to the Thread mesh prefix in a **Router
    Advertisement**. RAs are link-local: they do not cross a VLAN boundary, and
    no firewall rule can substitute for one. OPNsense carries no IPv6 at all —
    three IPv6 routes, all loopback — so nothing else can supply that route
  - Moving the BR to another VLAN therefore severs every Thread device from HA,
    silently and completely. It happened on 2026-08-17; see `archive/DONE.md`
  - The HomePod stays on VLAN 20 for AirPlay reasons, so dockassist holds a
    second **IPv6-only** `wlan0` leg onto VLAN 20 (`thread_wifi_link` in the
    homeassistant role) to stay on-link with it
  - ⚠️ `ipv4.method=disabled` on that profile is load-bearing. Docker sets
    `net.ipv4.ip_forward=1` on this host; the only thing stopping dockassist
    from bridging the IoT VLAN to VLAN 20 is that `wlan0` holds no IPv4 address

- **Presence detection via Companion App + Tado fallback** - Robust dual-source tracking
  - Primary: Mobile Companion App device trackers (real-time GPS)
  - Fallback: Tado device trackers (30-minute freshness window)
  - Combined presence sensors: one `binary_sensor.<person>_presence` per tracked person,
    named from `ha_*_person_display`. Those values are vaulted — see TODO item 33 for why
    the entity IDs themselves were deliberately left alone
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
- **Passphrase-free SSH key outside `touchid-agent`** — Ed25519 key at `~/.ssh/read_agent_ed25519` on the control machine. A Secure-Enclave agent blocks unattended access *by design*, so the agent key sits outside it and carries **no passphrase** — a passphrase would reintroduce the human this account exists to remove. ⚠️ This entry previously claimed the key was passphrase-encrypted via `vault_agent_ssh_passphrase`; **that was never implemented** and the claim is corrected here rather than deleted. The real compensating controls are `from=` pinning, a forced `ssh_alert.sh` command that Slack-alerts every connection, and read-only sudo. See `docs/AGENT_ACCESS.md`.
- **IP-restricted authorized_keys** — `from=` pinning on every host, set per key in `roles/agent_access/templates/authorized_keys.j2`. ⚠️ **In practice this is `10.30.0.0/16`, not a single IP** — the laptop has no fixed address (see `docs/NETWORK.md`). So it constrains the key to the estate's RFC1918 space, not to one machine; treat it as a blast-radius limit, not an identity check. Narrowing it is TODO item 12.
- **Phased API rollout** — Phase 2: SSH + HA API + Proxmox API. Phase 3: OPNsense/UniFi/Plex APIs. Start lean, expand once SSH-based investigation proves the pattern.
- **No secret access for agents** — Agent cannot read vault files, `.tado_tokens`, `secrets.yaml`, `.netrc`, or any credential files belonging to other users.
- **SSH config aliases bypass the biometric agent** — Generic `Host *-agent` pattern uses `ProxyCommand` to strip the `-agent` suffix and **`IdentityAgent none`** (not `SSH_AUTH_SOCK`) to bypass `touchid-agent` entirely, with `IdentitiesOnly yes` so only the agent key is offered. No per-host config — `ssh anyhost-agent` works for any resolvable hostname.
- **OPNsense sshd reload, not restart** — `service openssh onereload` (SIGHUP) instead of restart. Full restart regenerates host keys and risks config overwrites by OPNsense's auto-generator.
- **`read_agent` on OPNsense is `pw`-managed and expected to be wiped by upgrades — do not try to move it into `config.xml`** — Settled 2026-07-21 after testing the config.xml route and hitting a hard wall. A firmware upgrade (26.1.9, 2026-06-13) silently deleted the Ansible-created account, leaving agent access to the firewall broken for ~3 months: `local_sync_accounts` (`auth.inc`) enumerates accounts with uid ≥ 2000 and reconciles them against `config.xml`, deleting anything not there. The obvious fix — create the user in the OPNsense user manager so it lives in `config.xml` — **does not work for a least-privilege account**: `local_user_set` (`auth.inc:351`) forces `shell` to `/usr/sbin/nologin` for any user failing `userIsAdmin()`, which is `userHasPrivilege(…, 'page-all')` — full GUI administrator. OPNsense has no concept of a non-admin account with a login shell; the `<shell>` field in `config.xml` is ignored unless the user is an admin. Tested live: the UI-created user authenticated by key and then died on `This account is currently not available`. Worse, a config.xml-managed account gets its shell reset on *every* config apply, not just upgrades. So the account stays `pw`-managed and out-of-band by design. Mitigations: recovery is one idempotent command (`ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense`, ~9s from a fully wiped state, verified), and detection rides on the Agent LXC's Tier 1 reachability sweep. The alternative, if the repair ever becomes annoying, is to drop SSH for opnsense and use a privilege-scoped OPNsense API key (durable in config.xml, needs no shell) at the cost of losing `service -e` / `cscli` / `pfctl` diagnostics.
- **OPNsense sshd overrides live in `sshd_config.d/`, never in `sshd_config`** — `openssh.inc` regenerates `/usr/local/etc/ssh/sshd_config` from config.xml with a hardcoded `AllowGroups wheel`, so the role's former `lineinfile` edit was erased by upgrades *and* by any SSH settings change. The generated config `Include`s `/usr/local/etc/ssh/sshd_config.d/*.conf` at the very top and sshd takes the first value per keyword, so a fragment there wins. `agent_access` now ships `10-read_agent.conf`; `sshd_config` itself is left at OPNsense's native `AllowGroups wheel`, making a regeneration a no-op. Verified with `sshd -T` and a live login after reverting sshd_config to its native state.
- **Root shell hardening is Debian-only** — `ssh_hardening.yml` sets `shell: /sbin/nologin` on root only when `os_family == 'debian'` (via `omit` elsewhere). On OPNsense root's shell is `/usr/local/sbin/opnsense-shell`, the VGA/serial console admin menu; replacing it would remove the console recovery path. `password_lock` still applies on both platforms.
- **HA non-admin is not read-only** — HA non-admin users can call entity services (lights, switches). Only system operations (restart, add-ons) are blocked. Read-only is enforced by convention (GET requests only), not by HA permissions.
- **Proxmox privsep requires user + token ACLs** — With `--privsep 1`, effective permissions = intersection of user and token. Both must have PVEAuditor role assigned, not just the token.
- **Debounce at the detector, not in HA** — vinyl phantom-start filtering lives in `detect_audio` (3 consecutive active chunks, ~1s), which sees the raw signal; HA automations trigger instantly. Defense in depth is a cycling watchdog alert (plug on >3×/h), never a `for:` delay that would tax every real listening session.
- **MQTT push over HA polling for latency-sensitive state** — HA's MPD config entry polls (~10s, no scan_interval knob); detect_audio publishes retained play state to Mosquitto instead, cutting needle-drop→amp-on from ~10s to ~1–2s. Same pattern as raspotify's `spotify_event.sh`.
- **Broadlink codes: HA owns, Ansible seeds** — learned IR codes live in HA's `.storage` (rewritten on every `remote.learn_command`), so Ansible deploys the captured copy only when the file is missing (`force: false`) — disaster-recovery seed, not enforced state. Re-capture into the role after learning new positions.

## Test Environments (2026-08-18)

> Goals, status and gaps: [TESTING_GOALS.md](TESTING_GOALS.md). Read that before
> building anything test-related; this section is the standing rules only.

- **The test environment has four written goals, and work must map to one** — playbook e2e against a create/destroy host, a quick throwaway host, agent self-testing, and monitoring-script regression. They were unwritten until 2026-08-18, and the consequence was a green, carefully-reviewed rig that answered a *different question* from the one that motivated building it. Nothing contradicted anything, so the drift was invisible. **A goal that is not written down cannot be missed, only forgotten.**
- **Two inventories, and neither may name the other's hosts** — the rig lives in `ansible/inventory/test_hosts.yml`, never in `hosts.yml`. `is_test_environment: true` unlocks behaviour that must not reach production: hardening keeps a spare key, root stays reachable, and the Slack tokens are deliberately dead so a rig can never post to `#home-logging` or `#home-alerts`. A container heartbeating into the fleet's channels is indistinguishable from a fleet host doing it.
- **The test inventory connects as the infrastructure user over sudo, not as root** — connecting as root makes `become` a no-op, so every privilege-escalation path in every playbook goes untested, and it drags `scripts_dir`/`logs_dir` to `/home/root` because they derive from `ansible_user`. The one deliberate exception is `TEST_CT_BARE=1` plus `-e ansible_user=root`, which is the only state in which `bootstrap.yml`'s user-creation branch runs at all.
- **Test targets are chosen on OS release, not CPU** — CT 198 (Debian 12) is the proxy for the four Raspberry Pis because the gap that a POSIX shell script trips over is coreutils/util-linux flags, `systemctl` output and python version — two major versions — not aarch64. **aarch64 and Pi hardware (ALSA, `vcgencmd`, thermal sysfs) are unfixable here**: LXC shares the host kernel, so no aarch64 container runs on x86_64 cwwk.
- **The provisioning script is deliberately not a playbook** — the container must be creatable when the inventory, the vault, or the playbooks themselves are what is being tested, so it takes no dependency on any of them. `provision_agent_lxc.yml` remains the pattern for real infrastructure.
- **Cases ARRANGE as root and EXERCISE as the infrastructure user** — arranging a fault means stopping cron, filling disks and chowning root-owned logs, so an end-to-end unprivileged run cannot even set up (measured: 8/10 `PRECONDITION FAILED`). But the fleet's checks run as the unprivileged user under cron, so a root-only exercise is blind to every permission fault. **The earlier prescription — connect as the user and `sudo` up — is backwards and stays refused.**
- **Agents propose ephemeral tests; a human runs them (2026-08-18, option (a))** — agent-lxc gets **no** `pct create/destroy/exec` and **no** Linux-reachable vault. Scoped `pct` on the 198/199 range would be a narrow grant, but the vault half is not: `bin/vault_pass.sh` is macOS Keychain, and making it reachable on Linux moves fleet secrets from "behind a Touch ID prompt on one laptop" to "readable by a long-running network service that executes model output" — buying only the removal of a human tap. **Reassess once goal 1's one-command loop exists**; do not widen it incrementally without re-deciding in TESTING_GOALS.md.

## Agent LXC — Fleet Observer (CT 103, 2026-07-22)

- **`pct` over the Proxmox API for provisioning** — `community.general.proxmox` needs an API token with CT-create rights plus `proxmoxer` on the control node, to drive the same operations `pct` already exposes over the SSH path every other play in this repo uses. One provisioning playbook (`provision_agent_lxc.yml`) targeting `proxmox_hosts` keeps the credential surface unchanged. Idempotency comes from guarding each mutating step on live `pct`/`pveam` state, so a re-run is `changed=0`.
- **Provisioning hands over a key-reachable host, not a password-reachable one** — `bootstrap.yml` only creates `.ssh` and installs GitHub keys inside its "connected as root" block, but it runs "Lock password authentication" and sets `PasswordAuthentication no` unconditionally. A container adopted as the infrastructure user therefore locks itself out. Provisioning now seeds `authorized_keys` via `pct push` before bootstrap runs, removing the ordering hazard. **This failure is invisible for ~10 minutes**: SSH multiplexing (`ControlPersist=10m`) keeps serving the already-authenticated session, so the host looks reachable until the socket expires. Verify key auth with `-o ControlPath=none`.
- **Three-mode privilege model** — Monitor (Tier 1, shell, no credential beyond the container key) → Investigate (Tier 2, same read-only key, writes remediation plans, never mutates) → Operate (future, a *separate* passphrase-protected admin key, only while a human is present). Each mode is a distinct credential, not a flag on one credential, so the blast radius of the always-on box stays at read-only.
- **Tier 1 reads the journal, not the wrapper state file** (⚠️ Linux only — see the opnsense section below; FreeBSD's cron logs no job executions, so the firewall's freshness is answered from healthchecks.io instead) — the plan called for checking `enhanced_monitoring_wrapper` state-file freshness, but those live under the primary user's `0700` home and `read_agent` cannot read them (verified on cobra). `sudo journalctl -u cron` is already permitted by the existing sudoers and records every wrapper invocation, answering the same question: did this host's monitoring actually run recently?
- **Guest checks are onboot-aware** — a stopped guest is only an anomaly if it was meant to be running. CT 102 (pihole) is deliberately `onboot: 0`; comparing status against `onboot` rather than against "running" keeps it from alarming forever.
- **No Slack ping for the container's key** — `ssh_alert.sh` is a real control for the laptop key, whose use is occasional and therefore meaningful. The container sweeps all 7 hosts hourly, so alerting on it would post ~168×/day to the watched channel and anomalous use would hide inside expected traffic. The container key is authorized with `alert: false`; its accountability comes from `from=` pinning, read-only sudo, one-run revocation, and the sshd journal, which records source IP and key fingerprint persistently (`Accepted publickey ... SHA256:<fp>`).
- **ssh_alert cooldown is per sender** — the state file was a single `/tmp/read_agent_ssh_alert.last` per *host*, so any one client's traffic suppressed every other client's alert for 30 minutes. A chatty key could mask the key the control exists to watch.
- **OpenCode as the Phase B runtime (not Claude Code)** — chosen for its per-tool permission system with bash glob patterns (`allow`/`ask`/`deny`), which lets an always-on box holding fleet keys be scoped to `ssh *-agent *` with `edit`/`write` denied outright. Per-agent permission profiles are native, so the future read-only investigator and privileged operator are two markdown definitions rather than new machinery. Provider-portable via `ANTHROPIC_API_KEY` today.

### opnsense is read over the API, not a shell (L-H, 2026-08-17)

- **The firewall is checked over HTTPS, never SSH** — OPNsense rewrites every non-admin account's shell to `/usr/sbin/nologin` whenever it regenerates users from `config.xml` (`auth.inc:351`), so a shell for `read_agent` is on loan and was reclaimed twice. An API key/secret needs no login shell, so there is nothing for a regeneration to take away. It also retires the CrowdSec self-ban risk class rather than backing off from it: nothing in the sweep authenticates over SSH at the gateway any more. **Two alternatives are refused and must not be reopened**: `pw usermod` (bypasses an intentional control and self-reverts) and dropping opnsense from the sweep (its own crons only report while it is well).
- **Scoped API privileges, measured not assumed** — *Lobby: Dashboard*, *Diagnostics: Routing tables*, *Diagnostics: Logs: System*, plus *System: Deny config write*. `page-all` is **not** needed on 26.1.9. ⚠️ A 403 during that measurement matched opnsense/core#9093 exactly — whose documented workaround is granting `page-all` — but was an unsaved privilege. The discriminator was that the legacy camelCase URL 403'd *too*, which that bug does not predict. **A known upstream bug matching a symptom is a hypothesis, not a diagnosis**, and workarounds for privilege bugs are privilege grants.
- **Pin the public key, not the certificate** — OPNsense serves a self-signed certificate and does **not** auto-renew it (core#4567, #7385 open), so `--cacert` guaranteed a page on its expiry date: an alert about a calendar, not about the firewall. `-k --pinnedpubkey` has no expiry cliff and still refuses a substituted certificate — measured against a purpose-built expired cert (correct pin → 200; wrong pin → curl 90; `--cacert` → curl 60). **Certificate lifecycle is the software's problem; a pre-warning was proposed and declined.** General rule: cert pinning couples an alert to a *calendar*, key pinning to an *event*.
- **A 200 and a JSON body are both required** — measured on this firewall: an unauthenticated call answers **302** (an HTML redirect to the login page, not 401), and a *wrong* credential answers **401 with a body that is itself valid JSON**. So `--location` is forbidden (with `-L` the 302 returns 200 plus a login form) and neither check alone is sufficient.
- **Freshness comes from healthchecks.io, not from the box** — the Tier 1 rule above ("read the journal") has no FreeBSD analogue: **FreeBSD's cron does not log job executions at all**, unlike Debian's which syslogs every `CMD`. Verified: the firewall's entire system log held five cron lines, all of them the service starting at boot. Answering from outside is also strictly stronger — it does not depend on the firewall being well enough to reply, nor on the container.
- **The freshness heartbeat pings unconditionally** — `heartbeat_monitoring.sh` deliberately checks nothing, because anything it checked would become a reason not to ping. The two pre-existing opnsense heartbeats are conditional (WAN reachable / DNS resolving), so reusing them would conflate "monitoring stopped" with "the thing it checks is down" — the two states a freshness check exists to separate. Same reasoning as the sweep's own dead-man's switch.
- **Three outcomes for a third-party signal, never two** — down/stale is a finding; *"we could not ask"* is **UNKNOWN**, worded to disclaim any statement about the firewall; up is silence. A healthchecks.io outage or an expired key must never render as "opnsense monitoring is dead" — the same class of lie as a silent check, pointed the other way. Read with a **read-only** key, matched by check *name* (a read-only key omits `uuid`).

### Phase B — Tier 2 investigation (built + live 2026-07-25/26)

- **`deny`, never `ask`, in headless mode** — OpenCode's `--auto` promotes every `ask` to `allow`, and with no TTY there is nobody to prompt anyway. So anything the agent must not do is `deny` outright; `investigate.sh` never passes `--auto`. `ask` is reserved for the Phase C operator, where a human is present by construction. Verified live: a denied write auto-rejects and the file is absent.
- **Two OpenCode permission footguns, both load-bearing** — (1) `bash` defaults to **allow** when no pattern matches and no `"*"` catch-all exists; omitting it leaves an open shell on a key-holding box. (2) Rules are **last-match-wins**, so `"*": "deny"` must come *first* and the specific allows after it. Reversed, everything is denied and the sweep silently dies. The glob is a coarse filter, not the security boundary — the real constraint is the key (`from=` pinned, read-only account, one-run revocable).
- **The `steps` cap is a real runtime limit** — `agent.<name>.steps` in `opencode.json` is enforced by the runtime (forces a summary at the limit), not just prompt guidance. Set to 40 as a runaway bound.
- **Wrap the OpenCode call in a hard `timeout`** — observed: a run can finish its reasoning but the process fails to exit. Unwrapped, that hangs `investigate.sh` forever while it holds the flock, stalling *all* Tier 2 work. `timeout -k 15 600` + a stray-process sweep (safe under the flock).
- **Config prose lives in Jinja comments, not JSON** — OpenCode validates its config and *rejects unrecognized top-level keys*, and silently accepts junk keys inside `permission.bash` as glob patterns. A `_comment` field either breaks the file or degrades the permission block. Also: a stray apostrophe (`wrapper's`) inside a `python3 -c '...'` block closes the shell quote and aborts the whole script under dash — the authoritative check is `sh -n` **on the box**, since macOS `/bin/sh` is lenient bash.
- **Sonnet 5 for investigation, not Haiku** — investigations run 1–3/day, so Sonnet costs ~$0.30–0.60/mo more (noise) while being materially better at cross-host correlation and root cause — demonstrated: with the scoped-read helpers, Sonnet read the actual check script and found the exact `amixer 'Master'`-vs-`DAC` mismatch, where Haiku had reconstructed a fuzzier theory. Model is a per-agent, provider-qualified variable, so switching (incl. to an open-weight provider) is a var change, not a re-architecture.
- **Cost reality** — a healthy fleet costs ≈ the weekly digest only (~$2/mo). Tier 1 and the anomaly/Slack triggers are free when nothing is wrong; each *new* real problem is a one-off ~$0.30–0.55 and is then content-deduped for 7 days. Fix a recurring alert and its cost goes to zero. The one-time backlog burst that cleared three accumulated problems ($1.32) is not the run rate.
- **Slack-alert triage is a trusted script, not an agent MCP** — the hourly sweep can't see per-service wrapper failures or HA alerts (they only reach `#home-alerts`). A Slack MCP would (a) put cost-control dedup in the model's non-deterministic hands and (b) widen the sandboxed agent's reach to slack.com with permission semantics OpenCode doesn't document. Instead `investigate.sh --slack` does the read deterministically — content-signature dedup (one plan per distinct problem per 7 days), a per-run cap, and the agent stays SSH-only and never sees the read token. MCP is the right tool for Phase C (human-present, interactive), not for unattended cost-capped triage.
- **The agent is fully read-only; the trusted script persists its output** — rather than carve a scoped write hole into a key-holding box, the agent writes nothing anywhere. It emits the plan bounded by `===PLAN===`/`===SUMMARY===` markers on stdout; `investigate.sh` (running as the primary user, outside OpenCode's permission layer) extracts between the markers and writes the file. Bounding by explicit markers means correctness doesn't depend on the model suppressing preamble/code-fences. Consume `--format json` and keep only the final message — text mode dumps the whole ANSI-wrapped session.
- **Scoped-read helpers over filesystem ACLs** — closing the 0700-home gap (the agent couldn't read *why* a check failed) used root-owned `sudo` helpers (`agent_read`, `ha_state`) with name validation, not ACLs: `acl` isn't installed fleet-wide, and this fits the existing `read_agent` sudo pattern. Name validation (reject `/` and `..`) makes them traversal-proof, unlike a `sudo cat .../*` glob whose `*` spans `/`. Helpers are root-owned and not writable by `read_agent` — the load-bearing detail, or the account could edit what it sudo-runs. `ha_state` is GET-only against `/api/states`, so the agent reads HA entity state without the token and cannot control devices (also avoids the 401-failed-login alert an unauthenticated probe trips).
- **`flock` so Tier 2 never runs concurrently with itself** — one OpenCode run fans SSH out to all 7 hosts and leaves a short-lived server; two or three at once saturate the 1-CPU/2GB box until sshd can't schedule a login (learned the hard way). The anomaly, Slack, and digest modes share one lock, so they serialize.
