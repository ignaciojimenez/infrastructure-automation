# Infrastructure TODO — Prioritized Action List

Updated: 2026-07-21 | Validated against live hosts via read_agent autonomous assessment

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

---

## cwwk Thermal Stability — Root Cause + Headroom (mitigations deployed)

**Risk:** High operational impact — cwwk hosts the OPNsense firewall (VM 100, onboot), so a cwwk crash takes down all internet. Recurring silent resets.

### Root cause (investigated 2026-06-30)
cwwk hard-reset at 18:50 on 2026-06-30 with **no kernel log, panic, MCE, OOM, or thermal trip recorded** — the journal just stops mid-write. Whole fleet was fine (only cwwk dropped), no software/kernel/package change, temps/RAM/ECC/storage all clean. The smoking gun: `package_throttle_count` = **22,841** since the 18:51 boot (a healthy box reads ~0), proving the CPU repeatedly slammed Tjmax (105°C). Cause: girlfriend turned off the fan facing cwwk during a heatwave → thermal runaway → silicon-level **THERMTRIP** (instant power-off, leaves no log). Note: the per-event syslog throttle line is rate-limited/suppressed on this kernel, so *only the hardware counter* reveals throttling — instantaneous `sensors` reads a calm 56°C between throttle cycles. Distinct from the 2026-06-29 ~10:17 event, which was fleet-wide (real house power blip).

### Done — thermal logging (#2)
`save_temps.sh` (root cron `*/2`) logs temps + `package_throttle_count` + delta to `/var/log/diagnostics/thermal-history.log` (~3 days retained, 644 so read_agent can read it). Deployed + verified on cwwk. Fills the gap that made today's crash un-quantifiable. Role: `platform/proxmox`.

### Done — thermal headroom (#3, deployed 2026-06-30)
All as code in the `platform/proxmox` role (toggle `enable_proxmox_power_tuning`):
- **RAPL power cap:** PL1 (sustained) 35W → **20W**, PL2 (burst) left at 35W. Applied at boot via `cwwk-power-tuning.service`. Verified live: `PL1=20000000`, `PL2=35000000`. No throughput cost at 1 Gbps WAN.
- **Governor:** `performance` → **`powersave`** (intel_pstate; still boosts under load). Verified: all 8 cores `powersave`.
- **Dedicated thermal alert:** `check_thermal.sh` (cron `*/5`, via `enhanced_monitoring_wrapper` → #home-alerts) alerts on throttle-counter **delta**. Logic verified across OK/WARN/CRIT/reboot. Temp alerting moved out of `check_proxmox_health.sh` (no double-alerts).

### Next Steps — remaining
- **Fan:** ensure the cwwk fan can't be casually switched off (physical / labelling). *Still the actual fix — the cap only widens the margin.*
- **Validate under load:** `stress-ng` comparison at 35W vs 20W to quantify the temp drop (brief router-core load — schedule for a quiet window).
- **Live-fire the alert:** trigger a synthetic throttle delta and confirm the #home-alerts message + recovery end-to-end.
- **BIOS:** currently 5.27 (2024-11-26), board reports "Default string" — check CWWK for a newer release.
- **Forensics for hangs vs power:** consider netconsole / pstore-ramoops + a panic watchdog so a *hang* (vs power cut) is distinguishable next time.

### Acceptance Criteria
- [x] Power cap + governor applied as code and documented in decisions log
- [x] Throttle-aware dedicated alert deployed (logic verified)
- [x] Alert proven end-to-end — synthetic WARNING delivered a real #home-alerts message; returns to OK silently (no `--notify-fixed`, consistent with other checks — add it if closure pings are wanted)
- [x] cwwk holds throttle-free under summer load — validated over 2 days (2026-06-30→07-02, 1445 samples): package temp mean 46.7°C, peak 70°C (vs 105°C throttle point), **zero throttle events**; counter flat at 22,841.

### Incidental findings (this session)
- ✅ **cwwk cron/mail drift reconciled** (2026-07-01): adopted `save-dmesg` + `arc_summary` into the `platform/proxmox` role as managed root crons; removed the stale `Proxmox health check` cron (its target `proxmox_health.sh` didn't exist → failed every 4h). Root cause of the deferred-mail pileup was the 6 monitoring crons emitting the wrapper's stdout every run → now redirected to `~/.logs/proxmox_*.log` (matches the backup crons). Built `/etc/aliases.db` and flushed 2201 stale cron mails. cwwk root crontab is now 100% Ansible-managed.
- ⚠️ **Move webhook tokens out of cron arg lines** (elevated) — the Slack tokens are literal in every monitoring cron `job`, so they leak into `crontab -l`, `--diff` output, and cron-mail subjects (seen repeatedly this session). Move to a sourced env file read by `enhanced_monitoring_wrapper`. Given the repeated exposure, **consider rotating the two webhooks**. Cross-host (all monitored hosts).
- Monitoring logs (`~/.logs/proxmox_*.log`) and `zfs-arc.log` have no rotation — add logrotate if they grow.
- ✅ **cobra timezone skew — RESOLVED 2026-07-21.** cobra was on `Europe/London` (BST, 1h behind the rest of the fleet). No code change was needed: `timezone: "Europe/Madrid"` already lives in `group_vars/all/main.yml` and `debian_baseline.yml --tags timezone` already applies it — cobra had simply drifted and was the only outlier (all 6 other hosts verified `Europe/Madrid`/CEST). Applied with `ansible-playbook ansible/playbooks/platform/debian.yml --tags timezone --limit cobra`. **Gotcha worth remembering:** `cron` caches the timezone at process start and does *not* pick up a `/etc/localtime` change on its own, and `community.general.timezone` did not restart it here — cobra's cron was still 901s old (pre-change) after the module reported `changed`, so every cobra cron would have kept firing an hour off. **Now codified** (2026-07-21): `debian_baseline.yml` registers the timezone task and restarts cron only when it actually changed — verified idempotent (`changed=0`, restart skipped, on a second run against cobra). Note the FreeBSD path (`freebsd_baseline.yml`, `tzsetup`) has the same latent gap and was deliberately left alone — opnsense is the firewall and its timezone is managed through `config.xml` anyway; revisit only if its zone ever needs changing.
- No UPS monitoring (NUT/apcupsd) on cwwk; the 2026-06-30 split (cwwk down, Pis up) suggests cwwk may not share the Pis' power protection — worth confirming UPS topology.

---


## Priority 1 — Autonomous Agent LXC

**Risk:** Medium. New production container with network access to all hosts via SSH and read-only API tokens. Compromise would expose read-only infrastructure visibility. Scoped by IP restriction on authorized_keys and NOPASSWD-only sudo rules.

> **Prerequisite met 2026-07-21.** The `read_agent` foundation this depends on is now actually deployed and verified on all 7 hosts (expanded sudoers + opnsense access restored — see Resolved). Before that date the April rollout existed only in the repo, and opnsense had no `read_agent` account at all. Read Priority 2 before building Tier 1: agent access is not self-healing, and today nothing alerts when it breaks.

### What It Is
A permanent Debian 12 LXC (`vmid 103`, hostname `agent`, `onboot: 1`) running **Claude Code** on a schedule. It SSHs to all hosts using a container-resident key (not the laptop's read_agent key), calls Proxmox and HA APIs, and posts findings to Slack.

### Why a Separate LXC (Not an Existing Host)
- Always on — no laptop dependency, no Secretive auth required
- Isolated blast radius — a compromised container's key gets revoked via one Ansible run
- Can be rebuilt from Ansible end-to-end without touching other hosts
- Clean separation: "infrastructure observer" is not an application host

### Two-Tier Design
**Tier 1 — shell (free, runs hourly):** SSH to each host, check disk space, service status, last monitoring wrapper run, ZFS health, container/VM status. Send Slack alert on anomaly. No Claude API call.

**Tier 2 — Claude Code (API cost, runs on anomaly or on-demand):** When Tier 1 finds something anomalous, or you trigger it from Slack, Claude Code runs a structured investigation: correlates findings across hosts, checks HA entity states, queries Proxmox API, and produces a natural-language summary with actionable conclusions.

**Cost estimate:** ~1–3 API calls per day at ~$0.01–0.05 each → under $2/month.

### Resource Spec
| Resource | Value | Reasoning |
|----------|-------|-----------|
| vCPU | 1 | Claude Code is single-threaded for most operations |
| RAM | 2GB | Node.js + claude binary + SSH sessions |
| Disk | 16GB | OS + Claude Code + logs |
| Storage | local-zfs | Same pool as other CTs |
| onboot | 1 | Must be 24/7 |
| Network | vmbr0, 10.30.40.203 (static) | On same bridge as other CTs |

### SSH Key Design
New key pair generated inside the container: `agent_lxc_ed25519`. Added to `read_agent`'s `authorized_keys` on all hosts with `from="10.30.40.203"`. Retiring the container = one Ansible run to remove its key.

### Ansible Implementation
New Ansible role `roles/services/agent_lxc`:
1. Creates LXC on Proxmox via `community.general.proxmox` module
2. Bootstraps it via `site.yml`
3. Installs Claude Code (`npm install -g @anthropic-ai/claude-code`) + sets `ANTHROPIC_API_KEY` from vault
4. Deploys the container-resident SSH key
5. Deploys Tier 1 shell scripts + cron

The `agent_access` role gets a new task to add the container's key to `read_agent`'s `authorized_keys` on all hosts.

**Note on Ephemeral Testing overlap:** The LXC creation step (using `community.general.proxmox`) is also the core pattern needed for the Ephemeral Ansible Testing Environment (see Lower Priority). Implementing this first proves out the Ansible provisioning pattern with a real production container, making that testing environment nearly free to build later.

### What It Enables (Not Possible Today)
1. **Cross-host correlation** — one observer for the whole fleet, not 7 isolated scripts
2. **Unattended investigation** — trigger `ssh agent "claude investigate"` from your phone, no laptop needed
3. **Periodic digest** — weekly natural-language summary of fleet health
4. **Escalating alerts** — Tier 1 detects, Tier 2 explains

### What It Doesn't Change
Existing `enhanced_monitoring_wrapper` + healthchecks.io setup stays as-is for real-time per-host alerting. The agent LXC is a diagnostic layer on top, not a replacement.

### Next Steps
1. Assign static IP `10.30.40.203` to the container in OPNsense/UniFi
2. Write `roles/services/agent_lxc` role using `community.general.proxmox` to create the CT
3. Add `ANTHROPIC_API_KEY` to vault
4. Write Tier 1 health check scripts
5. Add container key to `agent_access` role's `authorized_keys` template

### Acceptance Criteria
- [ ] Container created and bootstrapped via Ansible (single `ansible-playbook` run)
- [ ] Tier 1 cron runs hourly and alerts on anomaly without any API cost
- [ ] Claude Code installed and reachable via `ssh agent-lxc "claude --version"`
- [ ] Container SSH key in `read_agent` authorized_keys on all 7 hosts, IP-restricted
- [ ] Container can be fully destroyed and recreated by Ansible with no manual steps

---

## Priority 2 — Make read_agent Durable on OPNsense (create it as a real OPNsense user)

**Risk:** Medium. Silently removes the firewall — the single most diagnostically valuable host — from all autonomous tooling, with no alert. Directly undermines Priority 1: the Agent LXC's whole premise is uniform `read_agent` SSH to all 7 hosts.

### What Happened (found 2026-07-21)
`ssh opnsense-agent` failed `Permission denied (publickey)` while the other 6 hosts were fine. Diagnosis on the host:
- `id read_agent` → **no such user** — the account was gone
- `/home/read_agent/` and `.ssh/authorized_keys` survived, owned by an orphaned numeric uid/gid `2001`
- `sshd_config` had reverted to `AllowGroups wheel` (the role sets `AllowGroups wheel read_agent`)
- The pubkey in the surviving `authorized_keys` still matched the laptop's key exactly (`SHA256:DV7ROy6mw1XXqUiZIxasQc8aBdSFqYv/JSK6BiS2TAk`)

### Root Cause — confirmed 2026-07-21
**A firmware upgrade rebuilt the system from `config.xml` and dropped the account.** Evidence:

1. **`/conf/config.xml` contains exactly two users: `root` (uid 0) and `choco` (uid 2000).** `read_agent` (uid 2001) is *not* among them — it only ever existed in `/etc/passwd`, created out-of-band by Ansible's `pw`. OPNsense treats `config.xml` as authoritative and regenerates `/etc/passwd` and `/usr/local/etc/ssh/sshd_config` from it, so anything absent from `config.xml` is discarded.
2. **Timing fits.** `pkg query` puts the install of **OPNsense 26.1.9 at 2026-06-13 13:03** — squarely between the 2026-04-07 rollout (validated working, home dir created Apr 8 18:16) and today's discovery. `choco` survived the same event precisely *because* it lives in `config.xml`.
3. **The home directory survived** because it is not part of that regeneration — which is exactly the asymmetry observed (dir + authorized_keys intact, account gone).

This is a **recurring failure, not a one-off**: it will happen again on the next firmware upgrade, and OPNsense upgrades are routine and UI-initiated.

**Good news — the blast radius is narrower than feared.** `/usr/local/etc/sudoers.d/` is *not* regenerated: the file `opnsense` there is dated 2026-06-02, i.e. it survived the 2026-06-13 upgrade. So only the **user account itself** is fragile; sudoers rules and the home directory persist. The fix only needs to make the account durable.

### Fix Forward — decided 2026-07-21
**Create `read_agent` as a real OPNsense user, in the console (UI) or via the API, so it lives in `config.xml`.** That makes it durable by construction and removes the recurring break entirely — no monitoring for it, no re-apply step, no post-upgrade checklist. Deliberately chosen over detect-and-recreate: recreating on every firmware upgrade would be treating a self-inflicted, fully fixable problem as a permanent fact of life.

The API path is confirmed available on this box: `/usr/local/opnsense/mvc/app/controllers/OPNsense/Auth/Api/UserController.php` extends `ApiMutableModelControllerBase` and exposes `searchAction`, `getAction`, `addAction`, `setAction`, `delAction` (verified on 26.1.9). `search` makes an idempotent create-if-missing Ansible task straightforward. The `config.xml` schema is visible in the two existing entries: `<uid>`, `<name>`, `<disabled>`, `<scope>user</scope>`, `<shell>`, `<authorizedkeys>` — the SSH key lives there too, so key rotation would go through the same path.

Doing it once by hand in the UI is a legitimate first step; the account only needs creating once, and it is durable from then on. Converting it to an idempotent Ansible task is the follow-up that keeps the box reproducible from the repo.

**Decisions still open when implementing:**
- UI once vs. Ansible-via-API — UI is faster now, Ansible keeps `agent_access` the single source of truth for all 7 hosts.
- Whether the `agent_access` FreeBSD branch drops `pw` entirely once the account is durable, or keeps it as a fallback.
- OPNsense API access needs an API key; confirm whether it can be scoped narrowly to user management.

**Do not assume the payload shape** — read `/usr/local/opnsense/mvc/app/models/OPNsense/Auth/User.xml` for the exact fields and validation before writing the task.

### Note on detection
With the account durable, this specific failure disappears, so no monitoring is planned for it. Worth knowing what stays uncovered: **nothing currently alerts when agent access to any host breaks, for any reason.** That is what let this sit unnoticed for ~3 months on the firewall. Not being tracked as work here — but it is close to free to fold into the Agent LXC's Tier 1 sweep (Priority 1), which already SSHs to every host on a schedule; a failed login there is an anomaly it could report for nothing extra.

### Acceptance Criteria
- [ ] `read_agent` exists as an OPNsense user in `config.xml` (visible in the UI user manager)
- [ ] `ssh opnsense-agent` still works after the next firmware upgrade
- [ ] If automated: the creating task is idempotent (`changed=0` on a second run)

---

## Priority 3 — Healthchecks.io + Slack Tokens Out of Cron Command Lines

**Risk:** Medium (hygiene, not exploitable in place). Promoted from Lower Priority on 2026-07-21: it should land *before* the Agent LXC bakes another consumer of `enhanced_monitoring_wrapper` into the fleet, rather than after.

Every monitoring cron across the fleet embeds both healthchecks.io tokens and the Slack webhook as positional args to `enhanced_monitoring_wrapper`. Tokens surface in `ps`, `crontab -l`, `--diff` output, and cron-mail subjects — observed repeatedly during the 2026-07-01 cwwk session. For a personal box with no untrusted users it's tolerable (the tokens only authorize pings to a public endpoint), but it is not portfolio-clean.

Cleaner pattern: env file at `/etc/monitoring/tokens.env` (`0600`) sourced by the wrapper. Scope: refactor the wrapper with a positional-arg fallback during rollout, deploy `tokens.env` from vault before any cron task uses it, strip token args from every `cron:` task across roles, then a coordinated redeploy. Given the repeated exposure, **rotate the two webhooks** as part of this.

See `memory/followup_tokens_in_cron.md` for the full kickoff context.

---

## Priority 4 — SMART Disk Health Monitoring

**Risk:** Medium. Proxmox's ZFS pool (`rpool`) is the single storage layer for all VMs and containers. A disk failure with zero early warning means potential data loss and full infrastructure outage. Cobra's media storage (`/dev/sda`) is similarly unmonitored.

### Why It Matters
ZFS checksumming catches silent corruption, but SMART attributes predict mechanical failure *before* it happens — reallocated sectors, pending sectors, temperature trends. Without SMART monitoring, the first sign of disk trouble is a ZFS scrub error or a complete drive failure.

### Scope
| Host | Disk(s) | Why |
|------|---------|-----|
| `proxmox` | NVMe/SSD under `rpool` | All VMs, containers, and backups live here |
| `cobra` | USB/SATA media drive | Plex library, irreplaceable if not backed up elsewhere |

RPi hosts (dockassist, hifipi, vinylstreamer) use SD cards — SMART doesn't apply. OPNsense runs as a VM (virtual disk). UniFi is an LXC (Proxmox storage).

### Implementation
1. Install `smartmontools` on proxmox and cobra via Ansible (package task in platform/bootstrap)
2. Create `check_smart_health.sh` — parse `smartctl -a` for key attributes (Reallocated_Sector_Ct, Current_Pending_Sector, Offline_Uncorrectable, temperature), exit non-zero on warning thresholds
3. Schedule via `enhanced_monitoring_wrapper` cron (daily is sufficient — SMART degradation is gradual)
4. Deploy to proxmox and cobra only (conditional on `enable_smart_monitoring: true`)

### Acceptance Criteria
- [ ] `smartmontools` installed on proxmox and cobra
- [ ] `check_smart_health.sh` alerts on concerning SMART attributes
- [ ] Cron runs daily via `enhanced_monitoring_wrapper`
- [ ] Slack alert fires on test with simulated threshold breach
- [ ] All related changes have been implemented in the infrastructure-automation codebase

---

## Priority 5 — cwwk Memory Optimization (OPNsense VM)

**Risk:** Low. OPNsense is allocated 12GB but only uses ~3.5GB (175M active + 2GB wired + 1.3GB ZFS ARC). 8.6GB is completely free inside the VM. Reducing the allocation from 12GB to 6GB would free 6GB for the hypervisor while leaving OPNsense with ~2.5GB headroom. Requires VM restart = brief network outage.

### Current cwwk Memory Allocation
| Resource | Allocated | Actual Use | Notes |
|----------|-----------|------------|-------|
| OPNsense (VM 100) | 12 GB | ~3.5 GB | 8.6GB free inside VM |
| UniFi (LXC 101) | 4 GB | ~1.4 GB | Java 1.1G + MongoDB 270M |
| pihole (LXC 102) | 2 GB | Stopped | `onboot: 0` |
| ZFS ARC | 10.7 GB max | ~10.2 GB | Shrinks on demand |
| **Total host** | **32 GB** | **~26 GB** | 5.4 GB available |

### Recommended Changes
- Reduce OPNsense from 12GB → 6GB (saves 6GB, requires VM restart)
- Optionally reduce UniFi from 4GB → 2GB (saves 2GB, requires LXC restart)
- Net result: ~13GB additional headroom for ZFS ARC and future LXCs

### Next Steps
1. Schedule a brief maintenance window (VM restart = ~30s network outage)
2. `sudo qm set 100 -memory 6144` on cwwk
3. Restart VM: `sudo qm shutdown 100 && sudo qm start 100`
4. Verify OPNsense starts normally and all WireGuard tunnels come up
5. Optionally: `sudo pct set 101 -memory 2048 && sudo pct restart 101`

---

## Lower Priority

These items have value but are not urgent. Ranked by value-to-effort ratio to help pick low-hanging fruit. Revisit quarterly.

### High Value/Effort — Quick wins worth picking up

- **TV idle auto-off for the amp** `V:Low E:Med` — A left-on TV keeps the amp powered (by design: TV `on` → `amp_source_active`). If it bothers in practice, `cobi_tv_3` exposes `is_volume_muted`/`volume_level`/`app_id` (optimistic `assumed_state`) as candidate idle signals. First confirm the exact OFF value of `cobi_tv_3` (off vs standby vs unavailable) with the TV powered down — it sat `unavailable` overnight 2026-07-14→15. Context: `docs/AUDIO_AUTOMATION.md` + memory `now-playing-ir-automation-plan`.

- **`detect_audio.log` empty after ~10h of active service — RESOLVED 2026-07-20** — Root cause found and fixed on `fix/detect-audio-journal-only-logging`. `DirectLogger` (`detect_audio.py.j2`) opened `~/.logs/detect_audio.log` once at process start (`mode='a'`) and held that file descriptor for the service's entire uptime — often many days (`Restart=always`, uptime observed at 4+ days). `/etc/logrotate.d/choco` rotates `~/.logs/*.log` **daily**. Rotation renames the inode out from under the held-open handle: the old fd keeps writing to what's now `detect_audio.log.1`, while the *current path* `detect_audio.log` sits at 0 bytes until the process restarts — which for a long-lived service can be days. Confirmed live: `detect_audio.log` was 0 bytes since the 2026-07-16 00:16 rotation while `detect_audio.log.1` had content through 2026-07-19 19:16, matching the PID's actual start time (2026-07-15). This fully explains the 2026-07-12 observation as a routine instance of the pattern, not a one-off.
  Fix: `detect_audio.py.j2`'s `DirectLogger` replaced with `JournalLogger` (stdout only, `flush=True`); the systemd unit already sets `StandardOutput=journal`, so persistent journald (merged 2026-07-14, see above) is now the sole durable record — sidesteps the whole held-open-fd-vs-logrotate class of bug rather than working around it. `vinylstreamer_monitor.sh.j2`'s `check_log_errors` updated to `journalctl -u detect_audio -o cat` instead of tailing the file (verified `choco`'s `adm` group grants non-root journal read access; output format matches the old grep pattern exactly). `logs_dir` directory-creation task retargeted to serve the cron logs that still use it (`vinylstreamer_monitoring.log`, `root_disk_space.log` — these are safe: each cron invocation opens/closes the file fresh, no held-open handle across rotation). Deployed + live-verified: service restarted clean, `vinylstreamer_monitor.sh` run manually confirms journal-based error check passes. Old `.logs/detect_audio.log*` files left in place (harmless, `missingok` covers them); will age out via existing `rotate 7`.
- **`/var/log/liquidsoap/phono.log` has no logrotate entry** `V:Low E:Low` — Surfaced 2026-07-20 while investigating the item above. Liquidsoap logs to `/var/log/liquidsoap/phono.log` (`liquidsoap-native.liq.j2`, `log.file.path`) but no `/etc/logrotate.d/` entry covers it — `/etc/logrotate.d/choco` only globs `~/.logs/*.log`, and there's no liquidsoap-specific rule. File was ~110KB after months of runtime, so growth is slow and not urgent, but it's unbounded. Fix: add a logrotate stanza for `/var/log/liquidsoap/*.log` (liquidsoap reopens its log on rotation via its own signal handling, so this shouldn't hit the same held-fd bug as detect_audio — verify before relying on that assumption).
- **Unattended-Upgrades Config Drift (cobra + unifi)** `V:Med E:Low` — Both hosts have manually configured `/etc/apt/apt.conf.d/50unattended-upgrades` with `"origin=*"` wildcard (upgrades ALL packages). Ansible template enforces security-only origins. Re-running `site.yml` on these hosts will overwrite their configs. Decision needed: adopt the Ansible template (security-only, matching all other hosts) or update the template to support a toggle for full-upgrade mode. Recommend aligning to security-only — the 145-173 pending non-security packages on hifipi/vinylstreamer confirm that security-only is sufficient.
- **Claude Code Autonomy — Sandbox Configuration** `V:Med E:Low` — SSH commands from Claude Code are blocked by the network sandbox proxy (can't resolve SSH config aliases like `dockassist-agent`). Fix already identified and tested: add `"excludedCommands": ["ssh", "scp", "ansible", "ansible-playbook", "ansible-vault", "ansible-lint"]` to `.claude/settings.local.json` sandbox config. This was used successfully via `dangerouslyDisableSandbox` workaround in the 2026-04-08 session but the settings watcher didn't pick up the config change mid-session. Will work in fresh sessions.
- **Vinylstreamer Session-Aware Monitoring** `V:Med E:Low` — `vinylstreamer_monitor.sh` currently alerts when `phono_liquidsoap.service` is inactive, but liquidsoap is intentionally off when not streaming. This generates false positives and unnecessary restart attempts. Fix: make liquidsoap/icecast checks conditional on `detect_audio` indicating an active streaming session. One script change.
- **`ssh_hardening` "Disable root user login" breaks OPNsense console — RESOLVED 2026-07-21** — Surfaced 2026-05-12; fixed 2026-07-21. The task in `ansible/playbooks/tasks/ssh_hardening.yml` set `shell: /sbin/nologin` on root unconditionally. On OPNsense root's shell is `/usr/local/sbin/opnsense-shell` — the console admin menu on VGA/serial — so applying it would have removed the console recovery path. Fixed by making the shell conditional on the inventory `os_family` var (the repo's own convention, used elsewhere in the same file) rather than the `ansible_os_family` fact: `shell: "{{ '/sbin/nologin' if os_family == 'debian' else omit }}"`. `omit` leaves the existing shell untouched on FreeBSD while `password_lock` still applies everywhere. Verified in check mode against opnsense: root's shell stays `/usr/local/sbin/opnsense-shell`. `--tags ssh` is now safe to run on opnsense. Note the task still reports `changed` on every run there — that is `password_lock` alone (see the FreeBSD idempotency wart below), not the shell.
- **`ssh_hardening` uri fetch skips in check mode → misleading diffs — RESOLVED 2026-07-21** — Surfaced 2026-05-12; fixed 2026-07-21 by adding `check_mode: false` to the `Fetch authorized keys from GitHub` uri task. It is a read-only fetch, so it must run in check mode too; previously `--check --diff` skipped it, `github_keys_fetched.content | default('')` collapsed to `""`, and the follow-up task rendered a diff that looked like "wipe all authorized keys" — a false positive indistinguishable from a real one.
- **Fresh-laptop bootstrap doc** `V:Low E:VLow` — The vault-password handoff (`bin/vault_pass.sh` → keychain item `ansible-vault-master`) is now documented as a one-liner in `docs/ARCHITECTURE_DECISIONS.md`. Consider adding a short "Set up a new control laptop" section to `README.md` (or a dedicated `docs/SETUP.md`) that lists the full handoff: clone repo → restore iCloud Keychain → done. So future-you doesn't have to grep decisions.md.
- **unifi-lxc not fully standardized via codebase** `V:Med E:Med` — Surfaced 2026-05-12 while recovering SSH access. Several signals suggest unifi-lxc drifts from what Ansible would render: it was missing the touchid-agent ssh key in `authorized_keys` (so `services.yml` clearly hasn't been re-applied since the keychain rotation); the 2026-05-10/11 log-path audit explicitly listed verification across cobra, dockassist, hifipi, vinylstreamer, cwwk — unifi-lxc not in that list; the already-noted "Unattended-Upgrades Config Drift (cobra + unifi)" item is another instance of unifi drifting from the template. Audit: run `ansible-playbook ansible/playbooks/site.yml --limit unifi-lxc --check --diff`, review every changed task, decide per-item whether to align the host to the codebase or update the codebase to match the host (LXC-specific quirks may justify the latter). Note: container migrated from a dedicated Pi to LXC under Proxmox, which is when the divergence probably started.
- **Slack Notification Strategy Review** `V:Low E:Low` — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies. A focused audit of ~20 notification sources to reassign channels would improve signal-to-noise.

- **Dead `docker-compose.yml.j2` in homeassistant role** `V:Low E:VLow` — Surfaced 2026-07-12 while adding the Mosquitto broker. `roles/services/homeassistant/templates/docker-compose.yml.j2` is never deployed — no task templates it to the host (confirmed: no compose file exists in `~/homeassistant` on dockassist), and the running containers are all created by individual `community.docker.docker_container` tasks. Its only referrer is the unused `stop homeassistant` handler (`docker_compose_v2`, never notified). The template even drifts from reality (missing the Mosquitto service the container tasks now deploy). Delete both the template and the dead handler, or — if a compose-based model is preferred — migrate all containers to it and wire it in. Recommend deleting; git has history.

- **Shelly Gen1 device config (CoIoT peer, AP-roaming) not captured in IaC** `V:Low E:Med` — Surfaced 2026-06-30. The CoIoT unicast peer + `ap_roaming=false` set on the four Gen1 Shellys (`…f510`, `…fb5f` gas; `.229`, `.243` lights) live only on device flash — a factory reset or unit swap silently loses them and reintroduces the unavailable-flap → phantom-alert bug. Consider a small idempotent script/playbook asserting `coiot.peer` and `ap_roaming.enabled=false` per Gen1 device via its HTTP API, run opportunistically. Low urgency; documented so the dependency is known.

### Medium Value/Effort — Worth planning

- **Healthchecks.io Tokens out of Cron Command Lines** — *Promoted to Priority 3 on 2026-07-21* so it lands before the Agent LXC adds another consumer of `enhanced_monitoring_wrapper`. See above.
- **CI: Undefined Jinja Variable Detection** `V:Med E:Med` — The Jinja2 syntax check added 2026-05-11 (`scripts/ci/check_jinja_syntax.py`) catches parse errors like the `{{ .Names }}` Docker-format collision that bit `stop_run_ha.j2`. It does NOT catch undefined variables like the `{{ container_name }}` reference that escaped to production for months — those need actual rendering against an inventory. Enhancement: extend CI to render every `.j2` against the `.example` inventory (vault dummified) and fail on `UndefinedError`. Closes the bigger bug class.
- **Backup Integrity Verification** `V:Med-High E:Med` — Backup freshness monitoring confirms "the script ran recently" but never validates that backups are actually restorable. A periodic script that downloads the latest backup, runs `age -d`, and validates tarball contents would close the gap. Could run weekly on Proxmox.
- **Cobra Post-Processing Monitoring** `V:Med E:Med` — Plex, Transmission, and Samba are all monitored with hourly health checks. The gap is the tvnamer/rename pipeline: if RSS downloads content but post-processing fails to organize it, nothing alerts. Needs design work — what does "tvnamer failed" look like? (stale files in download dir? log parsing?)

### Low Value/Effort — Deferred

- **`user` module reports perpetual `changed` for `password_lock` on FreeBSD** `V:VLow E:Low` — Surfaced 2026-07-21 while fixing the OPNsense root-shell gate. `Disable root user login` reports `changed` on every run against opnsense even with the shell now left alone; isolating the module (`-m user -a "name=root state=present password_lock=true"`) reproduces it with no other attribute set. The module can't reliably read back the locked state on FreeBSD, so it always assumes a change. Purely cosmetic `--diff` noise, but it's the same class of "perpetually changed" wart cleaned up in the 2026-05 SSH-play idempotency pass, and it makes real diffs on opnsense harder to spot. Consider `changed_when: false` with a comment, or a `getent`-based guard.

- **`scripts/ci/check_jinja_syntax.py` can't run under system python3** `V:VLow E:VLow` — Surfaced 2026-07-21. The script imports `jinja2`, which the Homebrew system `python3` doesn't have, so a local pre-push run dies with `ModuleNotFoundError` even though CI passes (CI's `pip install ansible-lint` pulls jinja2 in). Ran it locally via the ansible-lint venv's interpreter instead. Worth a one-line note in `AGENT_INSTRUCTIONS.md`, or a shebang/venv guard, so the local check isn't quietly skipped.


- **`deploy_monitoring.yml` restarted cron unconditionally — FIXED 2026-07-21** `V:Med E:VLow` — The task literally named "Restart monitoring services if needed" had no condition on anything having changed, so every run of the playbook bounced `cron` on all 6 Debian hosts and reported `changed=1` per host forever. Two real costs: the permanent non-zero `changed` count masked genuine diffs (the playbook could never be used as a drift check), and it needlessly restarted cron fleet-wide. It also confused the cobra timezone diagnosis in this same session — cobra's cron looked "recently restarted" only because a `deploy_monitoring.yml` run 15 minutes earlier had bounced it. Fixed by registering the script-copy loop and gating the restart on `is changed`; the playbook now reports `changed=0` across all 7 hosts on a second run. **Open question:** the restart is probably unnecessary *at all* — cron re-reads modified crontabs by itself, and deployed shell scripts are read fresh at each invocation, so nothing is cached that a restart would clear. Left in place (now correctly gated) rather than deleted, because "cron never needs a restart here" is a claim worth verifying before acting on it. Delete if confirmed.
- **Backup-State File Path Inconsistency** `V:Low E:Low` — Multiple roles (`platform/proxmox`, `platform/opnsense`, `services/homeassistant`, `services/unifi`, `services/plex`) write JSON state files to `{{ home_dir }}/.log/<script>.json` (singular `.log`), while all logs now live under `{{ logs_dir }}` (`.logs` plural). Surfaced during 2026-05 log-path audit. Decision: keep the split (state files ≠ logs, separate concern) or align under one directory. Working as intended today; cosmetic.
- **Cobra Media Config Consolidation** `V:Low E:Low` — Merge separate cobra repo into media role. Cosmetic, single-source-of-truth hygiene.
- **Bathroom Radiator flapping `unavailable` → "Heating offline" alert storm** `V:Med E:Low` — Surfaced 2026-07-12. `homekit_tado_climate_offline_alert` fired ~9× in 24h for **Bathroom Radiator** (`climate.tado_smart_radiator_thermostat_va0612513536`). Root cause is device-isolated: over an 18h window the bathroom head flapped `heat`↔`unavailable` in ~10–90 min bursts while **all 5 other Tado heads on the same Internet Bridge logged 0 unavailable** — so it's not the bridge, HA, or the network, it's that one thermostat's RF link to the bridge. Onset 2026-07-11 ~15:54 (rock-stable before). Heating itself is fine (runs its schedule locally; Tado app shows no issue). Two fixes: (1) **device — done 2026-07-12/13, validated**: batteries swapped ~17:30 CEST Jul 12 (the 3-min `unavailable` at 15:27 UTC is the swap itself). Post-swap: ~21h fully clean, then only 3 short blips in 24h (10/4/2 min vs the pre-swap 56–102 min hourly bursts) — one of them (Jul 13 18:08 UTC) was **all 8 entities simultaneously** (bridge/HA-side blip, not the bathroom). Tado cloud API cross-check (via `/homes/{id}/devices` inside the HA container, token rotation persisted): `batteryState=NORMAL`, `connectionState=true` for all devices. Residual: the bathroom still has occasional minutes-long RF blips its peers don't — marginal link (distance/tiles), harmless, heating unaffected; re-seat head / move bridge only if it worsens. (2) **monitoring — done 2026-07-12, validated end-to-end 2026-07-13**: global 6h cooldown condition on `homekit_tado_climate_offline_alert` via `this.attributes.last_triggered`. The Jul 13 13:01 UTC firing (a 10-min outage landing exactly on the `for:` threshold) proved trigger + condition + alert delivery live. Deliberately chose the one-line global cooldown over per-entity timer helpers — rejected as overengineered: HomeKit Tado entities are monitoring-only (heating runs locally when HA sees `unavailable`), so the worst case of the shared cooldown is one page delayed ≤6h if a *second* device fails inside another's window — acceptable. Upgrade to per-entity timers only if multi-device flapping ever becomes real. **Threshold bumped `for:` 10→20 min (2026-07-13), validated against 10 days of recorder history (37 outages / 8 entities):** healthy devices' blips are *all* <5 min (22 events, mostly bridge-wide) → zero pages at any threshold ≥10; the degraded bathroom head produced 10–102 min outages. At 20 min the blip class (≤10 min residual RF drops) never pages while a real episode still pages within ~30 min; 15 and 20 min are empirically identical against this dataset, 20 chosen for margin. With the 6h cooldown the threshold's only job is blip-vs-episode discrimination, so detection delay is immaterial (monitoring-only entities). Gas/smoke offline checks deliberately untouched (life-safety, tighter thresholds are correct there).
- **Stale `unavailable` Tado automations in HA `.storage`** `V:Low E:VLow` — Surfaced 2026-07-12 investigating the "bathroom Tado battery" alerts. Five UI-created automations persist in `.storage` but sit permanently `unavailable` (reference services/entities that no longer exist): `automation.tado_away_schedule`, `automation.scheduled_mon_tue_tado_home`, `automation.tado_integration_down_alert`, `automation.tado_integration_recovery_alert`, `automation.tado_health_check`. Superseded by the current IaC automations (`homekit_tado_climate_offline/online`, shell_command presence, `check_tado_health.sh` cron). Harmless but they clutter the automations list and are not captured in the repo. Delete via HA UI (they're `.storage`, not template-managed).
- **Agent API Expansion (Phase 3)** `V:Low-Med E:Med` — Add read-only API access for OPNsense, UniFi, and optionally Plex. SSH access to all three hosts already covers the same ground — API access adds richer diagnostics on top, not new capability.
- **Ephemeral Ansible Testing Environment** `V:High E:High` — Provision ephemeral LXC containers on Proxmox for end-to-end playbook testing. High payoff for major refactors, but current CI lint + `--check --diff` workflow has been sufficient. Revisit after Priority 5 proves out the `community.general.proxmox` provisioning pattern, which makes Phase 1 nearly free.

### Very Low Value/Effort — Revisit only if conditions change

- **Tidal and Qobuz Receiver on hifipi** `V:Low E:Blocked` — Depends on a good open-source receiver emerging. Not actionable today.
- **DNS Failover Wrapper Consistency** `V:VLow E:High` — `monitor_dns_failover.sh` is intentionally standalone: it resolves Slack by IP when DNS is down, which the wrapper can't do. Risk of refactoring outweighs cosmetic benefit.
- **Mullvad DoT Fallback** `V:VLow E:Med` — Encrypting DNS during full VPN outage. Near-irrelevant with 4-tunnel architecture.
- **Full Infrastructure as Code (Proxmox/OPNsense)** `V:Med E:VHigh` — High complexity for rarely-changing configs. Good config backups are sufficient.

---

## Resolved Items

- **April 2026 deployment backlog — deployed and verified 2026-07-21** — Three items (old Priorities 1–3) had been written, linted, and committed on 2026-04-08, then never applied: each one's "Next Steps" was gated on a Touch ID-backed Ansible run that never happened. They sat as *code in the repo describing infrastructure that did not exist* for ~3.5 months, while the doc read as though the work were essentially done. All now deployed and live-verified:
  - **disable-hdmi fix** — `tvservice -o` → `vcgencmd display_power 0`. Deployed to hifipi (vinylstreamer had somehow already received it). **The April scoping was wrong on two counts:** it named only the two Trixie hosts, but `dockassist` (Bookworm) had the identical `status=203/EXEC` failure — `tvservice` is absent there too, so this was never Trixie-specific. Fixed on dockassist as well. Fleet now reports **0 failed systemd units on all 6 Debian hosts** (was 3).
  - **read_agent sudoers expansion** — deployed to all 7 hosts. All four April acceptance criteria now PASS (`systemctl --failed` on cwwk, `fail2ban.log` on dockassist, `service crowdsec status` and `cscli decisions list` on opnsense). Two bugs found and fixed while verifying: the new `cscli decisions list *` / `alerts list *` / `metrics *` and `systemctl --failed *` / `list-timers *` rules all had a **trailing `*`, which sudo requires to match at least one argument** — so the bare, most obvious invocation (`sudo cscli decisions list`) still prompted for a password. Added explicit no-args variants alongside each wildcard rule, matching the pattern already used for `zpool list`/`zfs list` after the same bug was found there in April. Lesson: a trailing `*` in a sudoers rule is not "optional arguments".
  - **system_health_check.sh** — `SERVICES="ssh cron fail2ban"` deployed to all 6 Debian hosts (verified by reading the rendered file on each). opnsense correctly keeps the FreeBSD branch (`sshd cron`) — it runs CrowdSec, not fail2ban.

  The `read_agent` sudo expansion paid for itself immediately: the first fleet-wide `systemctl --failed` sweep it enabled is what surfaced the dockassist HDMI failure above, which no existing monitoring reported.

  **Process takeaway:** "code merged" was recorded as "done". The acceptance criteria in this document were the right ones and would have caught all of it — they were simply never run. Prefer verifying against live hosts over trusting the doc; where a change can't be applied in-session, the item should stay conspicuously open rather than reading as complete.

- **opnsense `read_agent` access restored** — 2026-07-21. Found fully broken (`Permission denied (publickey)`); root cause was the account having been dropped by OPNsense config regeneration, not a key problem. Re-running `agent_access.yml --limit opnsense` recreated the user, restored `AllowGroups wheel read_agent`, and reinstalled sudoers; verified `id`, `service crowdsec status`, and `cscli decisions list`. **This will recur** — tracked as Priority 2, which is about durability and detection, not this one-off recovery.

- **Now-Playing Amp Control (power + IR input switching)** — Completed 2026-07-18, physical E2E verified same day. Full architecture + behavior documented in `docs/AUDIO_AUTOMATION.md`. Power control merged #4 (2026-07-13), phantom-start/night-cycling fix merged #6, input switching merged #10 (signed `dafc92a`): `automation.amp_input_select` drives the 4-way RCA switcher via the RM4 Mini (`rca_switcher/input_pi`|`input_tv`, 3s debounce on source change, instant re-align on plug power-on); learned codes checked into the role and seeded to `.storage` only-if-missing. Physical verification with the amp wired (recorder data 2026-07-18): instant power-on with ~12W idle draw, three full 5-min-grace auto-offs (13:06/13:11/14:19 UTC), input switching fired on real source changes (pi↔tv including the both-active Pi-wins case), cycling watchdog silent, zero Broadlink errors. Remaining ideas tracked separately: TV idle auto-off (Lower Priority), extra switcher positions only if new sources get wired.

- **Shelly Gas false "back to normal" alert storm — root cause + fix** — Resolved 2026-06-30. The kitchen gas detector spammed `#home-alerts` with `✅ Gas detector back to normal` (14 in 6 days) despite no real event and the Shelly app showing every device online. Traced via the recorder DB + HA log: the two Shelly **Gen1** gas units (`SHGS-1` — `…f510` Kitchen, `…fb5f` Boiler Room), plus the two Gen1 lights, had CoIoT in **multicast** mode (`coiot.peer` empty), so HA got no reliable push and fell back to HTTP polling — every timed-out poll flipped the entity `unavailable` for a few seconds, and `shelly_gas_fault_recovery` fired on each `unavailable→normal` with **no debounce** (the FAULT side has `for: 5min`; recovery had none). Two-part fix: (1) **device** — set CoIoT unicast peer `10.30.100.100:5683` on all four Gen1 devices (`GET /settings?coiot_peer=…`), the HA-recommended config for Gen1; confirmed push flowing via raw-socket capture of device→HA:5683, which also empirically proved there's no client isolation on the `…_iot` SSID. (2) **automation** — added a symmetric `condition: template` to `shelly_gas_fault_recovery` so recovery only alerts when the prior unavailable/fault lasted ≥300 s, mirroring the FAULT debounce; deployed via ad-hoc `template` module + HA restart, `check_config` clean, and verified the restart's own `unavailable→normal` blip fired the recovery automation **0 times** (pre-fix this produced a phantom alert per restart). **Caveat — self-inflicted incident:** an AP-roaming tweak attempted mid-session (`/settings/ap_roaming?enabled=true`) knocked both gas units off Wi-Fi (no AP stronger than the −70 threshold → scan/drop loop); recovered by reverting `ap_roaming=false` from the OPNsense gateway (authoritative cross-VLAN ARP/reach) and the device's own `shellygas-XXXX` recovery AP. **Do not enable AP roaming on marginal-signal Gen1 devices.** Device-side CoIoT/roaming config lives only on device flash — see new Lower Priority items.
- **Shelly smoke + gas detector Slack alerts** — Completed 2026-06-13. Added HA automations for two Shelly Gas units (`shellygas-…f510`, `…fb5f`) and one Shelly Plus Smoke (`shellyplussmoke-3076f523fd68`) in `automations.yaml.j2`. Gas: alarm (mild/heavy)/cleared/sensor-fault/recovered → `slack_alert` (#home-alerts), self-test → `slack_notify`. Smoke: alarm/cleared/low-battery(<15%)/offline(26h debounce) → `slack_alert`, back-online → `slack_notify`. Trigger states verified against live entities; `area_name()` templating resolves the gas unit to "Kitchen". Verified end-to-end via Slack: self-test fired the automation and posted correctly. Key finding: the system *looked* broken only because routine messages were going to `#home-logging` (a firehose with a `Script Execution: SUCCESS` every ~10 min) instead of the watched `#home-alerts` — see memory `slack-alert-channels`. The smoke detector's "broken integration entry" errors were just the battery/sleeping device having been added while asleep; waking it populated all entities. Offline detection for the sleeping smoke unit uses a deliberately long (26h) `for:` debounce — may need tuning once its real reporting cadence is observed. Not live-fire tested: a real mild/heavy gas alarm and a real smoke alarm (would require injecting a fake reading or pressing the physical test button) — alarm path proven by composition (alert-channel delivery + identical automation mechanism both confirmed).
- **unifi-lxc + opnsense SSH key recovery + vault password handoff** — Completed 2026-05-12. After rotating to a new touchid-agent ssh key, `ssh unifi` and `ssh opnsense` both failed `Permission denied (publickey)` — these two hosts had drifted off the GitHub key set while the others had been re-synced by a recent `services.yml` run. Recovered access by appending the touchid-agent pubkey to `/home/choco/.ssh/authorized_keys` via `sudo pct exec 101` (unifi LXC) and `sudo qm guest exec 100` (opnsense VM with QEMU guest agent). Then re-ran `services.yml --tags keys --limit unifi-lxc,opnsense` to canonicalize authorized_keys against `https://github.com/ignaciojimenez.keys` — verified `changed=0` on second pass, so both hosts now match the codebase and consume GitHub as source of truth going forward. Side fixes: vault password handoff moved from missing `~/.ansible/vault_pass` to repo-tracked `bin/vault_pass.sh` (calls `security find-generic-password -s ansible-vault-master`); ansible.cfg updated; ARCHITECTURE_DECISIONS.md documents the iCloud-Keychain handoff. Also fixed: `/usr/local/bin/update_keys` shebang was `#!/bin/bash`, which is missing on FreeBSD — changed to `#!/bin/sh` in `ssh_hardening.yml` (body is a single curl call, fully POSIX). Several deferred findings captured in Lower Priority above: root-shell lock breaking OPNsense console, uri fetch skipping in check mode, fresh-laptop setup doc, full unifi-lxc standardization audit.
- **Monitoring log-path audit + SSH-play idempotency + CI Jinja check** — Completed 2026-05-10/11. Investigated `update_ha` cron alert (`tee: /home/choco/logs/ha_update.log: No such file or directory`) and uncovered a structural bug in the HA role: `with_fileglob` was deploying both `update_ha` (plain, hardcoded `$HOME/logs/`) and `update_ha.j2` (templated, correct path) side-by-side — the plain script was the one running. Audit found the same pattern in `backup_ha`, `stop_run_ha`, `dockassist_monitor.sh`, `vinylstreamer_monitor.sh`. All converted to templates rendering `LOG_FILE` against `{{ logs_dir }}`. Templates moved from `roles/.../files/` to `roles/.../templates/`. Standardized `detect_audio.log` onto `logs_dir`. Deleted orphan `scripts/services/homeassistant/backup_ha.sh`. Added `scripts/ci/check_jinja_syntax.py` to the lint workflow — would have caught the `{{ .Names }}` Docker-format/Jinja2 collision in `stop_run_ha.j2`. Fixed `services.yml` auto-discover `include_role` so `--tags <role>` works without also passing `services`. Resolved SSH hardening play perpetually-`changed` noise: removed `ansible_date_time.iso8601` from `sshd_config.j2`, folded `TCPKeepAlive`/`LoginGraceTime` into the template (was fighting `lineinfile`), dropped the redundant standalone backup task (the template module already does `backup: true`). Verified `changed=0` on second pass across cobra, dockassist, hifipi, vinylstreamer, cwwk. Codified script-location convention in `AGENT_INSTRUCTIONS.md` (lifecycle scripts → role templates/, monitoring → `scripts/services/`, cross-service → `scripts/common/`). Commits: `3687808`, `63b63bf`, `4ea62c3`.
- **fail2ban Backend Fix (dockassist + cobra)** — Resolved 2026-04-08. fail2ban 1.0.2 on Bookworm needs `backend = systemd` because auth logs go to journald, not `/var/log/auth.log`. SSH brute-force protection was absent since October 2025 — fail2ban crashed on every boot with `"Have not found any log file for sshd jail"`. Fix: added task in `install_base_software.yml` to deploy `/etc/fail2ban/jail.d/sshd.conf` with `backend = systemd`. Deployed via Ansible ad-hoc and verified active on both hosts. Also added fail2ban to `system_health_check.sh` critical services list. Note: Trixie hosts (hifipi, vinylstreamer) run fail2ban 1.1.0 which auto-detects this — unaffected.
- **Read-Only Agent Access (Priority 11)** — Completed 2026-04-07. `read_agent` user deployed on all 7 hosts. SSH access validated from control machine via `Host *-agent` pattern bypassing Secretive. HA API (read + admin rejection validated), Proxmox API (read + write rejection validated). Secret files inaccessible. Documentation complete in `docs/AGENT_ACCESS.md`. Sudo blind spots fixed: added `zfs get`, `zpool iostat`, no-args variants for `zfs list`/`zpool list`/`zpool status`. One item not validated: `from=` IP restriction from outside LAN (requires off-network test — opportunistic, not blocking).
- **Proxmox Performance Tuning** — Completed 2026-04-07. ZFS ARC cap raised from 3.1GB to 10GB (`/etc/modprobe.d/zfs.conf`). ARC config now managed by Ansible (`platform/proxmox.yml`, `zfs_arc_max_gb` var in inventory). `zpool upgrade rpool` completed (all features enabled). Compression already on for all datasets (LZ4, 1.76–2.09x ratio on key datasets).
- **Ansible Playbook CI (Syntax + Lint)** — Completed 2026-04-04. `.github/workflows/ansible-lint.yml` implemented, running `ansible-lint` on push/PR.
- **Proxmox USB Recovery Kit + Backup Restore Testing** — Completed 2026-03-30. 128GB USB drive at `/mnt/usb-recovery`, syncing weekly (Sunday 05:00) via `sync_usb_recovery.sh`. Two-generation rotation (`current/` + `previous/`), RECOVERY.txt checklist, MANIFEST.txt with checksums. First restore test passed: UniFi LXC 101 vzdump → temporary CT 999, filesystem verified intact. LXC restores require `--storage local-zfs` — documented in RECOVERY.txt and BACKUP_AND_RECOVERY.md.
- **Backup Freshness Monitoring** — Completed 2026-03-28. Added `heartbeat_backup.sh` reusable template, deployed as standalone heartbeat scripts (one per backup host). Each checks the `enhanced_monitoring_wrapper` state file for recent success, pings healthchecks.io every 2 hours. 5 checks: HA/OPNsense/UniFi daily (26h max age), Proxmox/Plex weekly (172h max age).
- **Backup Encryption Portability (GPG → age)** — Completed 2026-03-23. Migrated all 5 backup pipelines from GPG to age asymmetric encryption. Recovery: `brew install age` + paste secret key from password manager.
- **Backup Automation (OPNsense + Proxmox)** — Completed 2026-03-22. Both scripts deployed via Ansible cron, first backups verified in curlbin. Recovery guide: `docs/BACKUP_AND_RECOVERY.md`.
- **VPN Country Switcher UUIDs** — All 4 UUIDs verified in `/conf/config.xml`. Script functional.
- **Plex on Cobra** — Active since 2026-03-15. Monitoring and backup crons deployed.
- **DNS Resilience** — 4-tunnel Mullvad + Cloudflare fallback operational. Failover every minute, health check every 5 minutes.
- **OPNsense Ansible Consolidation** — Completed 2026-04-01. All 15 OPNsense crons now have `#Ansible:` prefixes. DNS failover cron brought under Ansible management. 9 legacy scripts removed. Dead playbook deleted, `freebsd.yml` cleaned up.
- **TADO/HA Presence Notification Elegance** — Completed 2026-04-02. Removed unconditional Slack alert from away automation. Notification now fires only when AWAY is actually applied.
- **Proxmox WebUI User Migration** — Completed 2026-04-02. `choco@pam` granted Administrator role on `/`. Stop using `root@pam` for routine access.
- **Tado Presence Health Check** — Completed 2026-03-31. Deployed to `/home/choco/.scripts/check_tado_health.sh`, cron every 30min with `enhanced_monitoring_wrapper`.
- **Tado SQLite migration** — Completed (commit `a7f6221`). Uses HA REST API.
- **vinylstreamer liquidsoap inactive** — Expected. Runs only during active streaming sessions.
