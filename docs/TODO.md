# Infrastructure TODO — Prioritized Action List

Updated: 2026-05-11 | Validated against live hosts via read_agent autonomous assessment

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

---

## Priority 1 — Deploy disable-hdmi Fix (hifipi + vinylstreamer)

**Risk:** Low operational impact but masks real failures. The `disable-hdmi.service` on Raspberry Pi hosts uses `/usr/bin/tvservice -o` which was removed in Debian Trixie. Both Trixie hosts (hifipi, vinylstreamer) show a permanent failed service.

### What Changed
Codebase fix in `raspberrypi.yml`: replaced `tvservice -o` with `vcgencmd display_power 0` (confirmed available on all Pi hosts). Added daemon-reload + restart on change.

### Next Steps (requires biometric/Touch ID)
```bash
ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook ansible/playbooks/platform/raspberrypi.yml \
  --tags hdmi --diff
```

### Acceptance Criteria
- [ ] `disable-hdmi.service` active (not failed) on hifipi and vinylstreamer
- [ ] No failed systemd units on either host

---

## Priority 2 — Deploy read_agent Sudoers Expansion

**Risk:** None operational. Expanding read-only diagnostic access enables fully autonomous infrastructure assessment. Current gaps discovered during the 2026-04-08 assessment: can't read fail2ban logs, unattended-upgrades logs, check failed services, view Docker disk usage, check crontabs, or query CrowdSec on opnsense.

### What Changed
Debian sudoers template additions:
- `systemctl --failed`, `systemctl list-timers`
- `journalctl -p * --no-pager *` (filter by priority, not just unit)
- `cat /var/log/fail2ban.log`, `cat /var/log/unattended-upgrades/*`
- `crontab -l -u *`
- `docker system df *` (homeassistant host only)

FreeBSD sudoers template additions:
- `service * status`, `service -e`
- `cscli decisions list`, `cscli alerts list`, `cscli metrics`

### Next Steps (requires biometric/Touch ID)
```bash
ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook ansible/playbooks/system/agent_access.yml --diff
```

### Acceptance Criteria
- [ ] Sudoers deployed to all 7 hosts
- [ ] `ssh cwwk-agent "sudo systemctl --failed --no-pager"` works
- [ ] `ssh dockassist-agent "sudo cat /var/log/fail2ban.log"` works
- [ ] `ssh opnsense-agent "sudo service crowdsec status"` works
- [ ] `ssh opnsense-agent "sudo cscli decisions list"` works

---

## Priority 3 — Deploy system_health_check.sh Update

**Risk:** Low. The health check script monitors `ssh` and `cron` but not `fail2ban`. This is why fail2ban was broken for 6 months without alerting.

### What Changed
Added `fail2ban` to the `SERVICES` list in `check_services()` in `system_health_check.sh`.

### Next Steps (requires biometric/Touch ID)
```bash
ANSIBLE_LOCAL_TEMP="$TMPDIR/ansible-tmp" ansible-playbook ansible/playbooks/deploy_monitoring.yml --diff
```

### Acceptance Criteria
- [ ] system_health_check.sh deployed to all Debian hosts
- [ ] Script checks fail2ban status on all hosts

---

## Priority 4 — cwwk Memory Optimization (OPNsense VM)

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

## Priority 5 — Autonomous Agent LXC

**Risk:** Medium. New production container with network access to all hosts via SSH and read-only API tokens. Compromise would expose read-only infrastructure visibility. Scoped by IP restriction on authorized_keys and NOPASSWD-only sudo rules.

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

## Priority 6 — SMART Disk Health Monitoring

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

## Lower Priority

These items have value but are not urgent. Ranked by value-to-effort ratio to help pick low-hanging fruit. Revisit quarterly.

### High Value/Effort — Quick wins worth picking up

- **Unattended-Upgrades Config Drift (cobra + unifi)** `V:Med E:Low` — Both hosts have manually configured `/etc/apt/apt.conf.d/50unattended-upgrades` with `"origin=*"` wildcard (upgrades ALL packages). Ansible template enforces security-only origins. Re-running `site.yml` on these hosts will overwrite their configs. Decision needed: adopt the Ansible template (security-only, matching all other hosts) or update the template to support a toggle for full-upgrade mode. Recommend aligning to security-only — the 145-173 pending non-security packages on hifipi/vinylstreamer confirm that security-only is sufficient.
- **Claude Code Autonomy — Sandbox Configuration** `V:Med E:Low` — SSH commands from Claude Code are blocked by the network sandbox proxy (can't resolve SSH config aliases like `dockassist-agent`). Fix already identified and tested: add `"excludedCommands": ["ssh", "scp", "ansible", "ansible-playbook", "ansible-vault", "ansible-lint"]` to `.claude/settings.local.json` sandbox config. This was used successfully via `dangerouslyDisableSandbox` workaround in the 2026-04-08 session but the settings watcher didn't pick up the config change mid-session. Will work in fresh sessions.
- **Vinylstreamer Session-Aware Monitoring** `V:Med E:Low` — `vinylstreamer_monitor.sh` currently alerts when `phono_liquidsoap.service` is inactive, but liquidsoap is intentionally off when not streaming. This generates false positives and unnecessary restart attempts. Fix: make liquidsoap/icecast checks conditional on `detect_audio` indicating an active streaming session. One script change.
- **`ssh_hardening` "Disable root user login" breaks OPNsense console** `V:Med E:Low` — Surfaced 2026-05-12 during the unifi+opnsense key-recovery work. The task in `ansible/playbooks/tasks/ssh_hardening.yml` sets `shell: /sbin/nologin` on root unconditionally. On OPNsense, root's shell is `/usr/local/sbin/opnsense-shell` — the console admin menu shown on VGA/serial. Replacing it with `nologin` would lock you out of console recovery. Fix: gate the shell change with `when: ansible_os_family != "FreeBSD"` (or read the current shell and skip if it's opnsense-shell). Until then, avoid running `--tags ssh` (which includes this task) on opnsense; `--tags keys` is the safe subset.
- **`ssh_hardening` uri fetch skips in check mode → misleading diffs** `V:Low E:VLow` — Surfaced 2026-05-12. `Fetch authorized keys from GitHub` is an `ansible.builtin.uri` task with no `check_mode: false`, so in `--check --diff` it skips. The follow-up `Set authorized keys` task then sees `github_keys_fetched.content | default('')` → `""` and renders a diff that looks like "wipe all keys". It's a false positive but it's exactly the kind of diff you'd want to act on if you didn't know better. Fix: add `check_mode: false` to the uri task.
- **Fresh-laptop bootstrap doc** `V:Low E:VLow` — The vault-password handoff (`bin/vault_pass.sh` → keychain item `ansible-vault-master`) is now documented as a one-liner in `docs/ARCHITECTURE_DECISIONS.md`. Consider adding a short "Set up a new control laptop" section to `README.md` (or a dedicated `docs/SETUP.md`) that lists the full handoff: clone repo → restore iCloud Keychain → done. So future-you doesn't have to grep decisions.md.
- **unifi-lxc not fully standardized via codebase** `V:Med E:Med` — Surfaced 2026-05-12 while recovering SSH access. Several signals suggest unifi-lxc drifts from what Ansible would render: it was missing the touchid-agent ssh key in `authorized_keys` (so `services.yml` clearly hasn't been re-applied since the keychain rotation); the 2026-05-10/11 log-path audit explicitly listed verification across cobra, dockassist, hifipi, vinylstreamer, cwwk — unifi-lxc not in that list; the already-noted "Unattended-Upgrades Config Drift (cobra + unifi)" item is another instance of unifi drifting from the template. Audit: run `ansible-playbook ansible/playbooks/site.yml --limit unifi-lxc --check --diff`, review every changed task, decide per-item whether to align the host to the codebase or update the codebase to match the host (LXC-specific quirks may justify the latter). Note: container migrated from a dedicated Pi to LXC under Proxmox, which is when the divergence probably started.
- **Slack Notification Strategy Review** `V:Low E:Low` — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies. A focused audit of ~20 notification sources to reassign channels would improve signal-to-noise.
- **`wyze_bulb_offline_alert` has observability gaps** `V:Med E:Low` — Surfaced 2026-05-13 investigating "Wyze lights stopped working after HA 2026.5.1 upgrade." Two distinct failure modes the current alert misses: (a) state-trigger gap — `to: "unavailable"` doesn't fire on `unknown → unavailable` transitions at container startup; (b) optimistic-state lying — the `ha-wyzeapi` integration sets `self._bulb.on = False/True` after a successful API call without verifying the bulb physically responded, so HA's recorder logged clean on/off transitions throughout the 2026-05-11→13 outage even though the bulbs weren't actually toggling. (a) is cheap to fix (broaden triggers + add a stale-`last_reported` template trigger). (b) is harder — needs an external verification signal HA doesn't have natively; might be addressable by polling the Wyze API for actual device state on a schedule and alerting on divergence from HA's view, or by upstream patching the integration to verify post-command. Worth doing (a) standalone; (b) only if the failure mode recurs.

### Medium Value/Effort — Worth planning

- **Healthchecks.io Tokens out of Cron Command Lines** `V:Med E:Med` — Every monitoring cron across the fleet embeds both healthchecks.io tokens (logging + alert) as positional args to `enhanced_monitoring_wrapper`. Tokens surface in `ps`, `crontab -l`, and `/var/spool/cron/*`. For a personal box with no untrusted users it's tolerable (tokens only authorize pings to a public endpoint), but not portfolio-clean. Cleaner pattern: env file at `/etc/monitoring/tokens.env` (`0600`) sourced by the wrapper. Scope: refactor wrapper with positional-arg fallback during rollout, deploy `tokens.env` from vault before any cron task uses it, strip token args from every `cron:` task across roles, coordinated redeploy. See `memory/followup_tokens_in_cron.md` for the full kickoff context.
- **CI: Undefined Jinja Variable Detection** `V:Med E:Med` — The Jinja2 syntax check added 2026-05-11 (`scripts/ci/check_jinja_syntax.py`) catches parse errors like the `{{ .Names }}` Docker-format collision that bit `stop_run_ha.j2`. It does NOT catch undefined variables like the `{{ container_name }}` reference that escaped to production for months — those need actual rendering against an inventory. Enhancement: extend CI to render every `.j2` against the `.example` inventory (vault dummified) and fail on `UndefinedError`. Closes the bigger bug class.
- **Backup Integrity Verification** `V:Med-High E:Med` — Backup freshness monitoring confirms "the script ran recently" but never validates that backups are actually restorable. A periodic script that downloads the latest backup, runs `age -d`, and validates tarball contents would close the gap. Could run weekly on Proxmox.
- **Cobra Post-Processing Monitoring** `V:Med E:Med` — Plex, Transmission, and Samba are all monitored with hourly health checks. The gap is the tvnamer/rename pipeline: if RSS downloads content but post-processing fails to organize it, nothing alerts. Needs design work — what does "tvnamer failed" look like? (stale files in download dir? log parsing?)

### Low Value/Effort — Deferred

- **Backup-State File Path Inconsistency** `V:Low E:Low` — Multiple roles (`platform/proxmox`, `platform/opnsense`, `services/homeassistant`, `services/unifi`, `services/plex`) write JSON state files to `{{ home_dir }}/.log/<script>.json` (singular `.log`), while all logs now live under `{{ logs_dir }}` (`.logs` plural). Surfaced during 2026-05 log-path audit. Decision: keep the split (state files ≠ logs, separate concern) or align under one directory. Working as intended today; cosmetic.
- **Cobra Media Config Consolidation** `V:Low E:Low` — Merge separate cobra repo into media role. Cosmetic, single-source-of-truth hygiene.
- **Agent API Expansion (Phase 3)** `V:Low-Med E:Med` — Add read-only API access for OPNsense, UniFi, and optionally Plex. SSH access to all three hosts already covers the same ground — API access adds richer diagnostics on top, not new capability.
- **Ephemeral Ansible Testing Environment** `V:High E:High` — Provision ephemeral LXC containers on Proxmox for end-to-end playbook testing. High payoff for major refactors, but current CI lint + `--check --diff` workflow has been sufficient. Revisit after Priority 5 proves out the `community.general.proxmox` provisioning pattern, which makes Phase 1 nearly free.

### Very Low Value/Effort — Revisit only if conditions change

- **Tidal and Qobuz Receiver on hifipi** `V:Low E:Blocked` — Depends on a good open-source receiver emerging. Not actionable today.
- **DNS Failover Wrapper Consistency** `V:VLow E:High` — `monitor_dns_failover.sh` is intentionally standalone: it resolves Slack by IP when DNS is down, which the wrapper can't do. Risk of refactoring outweighs cosmetic benefit.
- **Mullvad DoT Fallback** `V:VLow E:Med` — Encrypting DNS during full VPN outage. Near-irrelevant with 4-tunnel architecture.
- **Full Infrastructure as Code (Proxmox/OPNsense)** `V:Med E:VHigh` — High complexity for rarely-changing configs. Good config backups are sufficient.

---

## Resolved Items

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
