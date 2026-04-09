# Infrastructure TODO — Prioritized Action List

Updated: 2026-04-09 | Validated against live hosts via read_agent autonomous assessment

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
- **Slack Notification Strategy Review** `V:Low E:Low` — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies. A focused audit of ~20 notification sources to reassign channels would improve signal-to-noise.

### Medium Value/Effort — Worth planning

- **Backup Integrity Verification** `V:Med-High E:Med` — Backup freshness monitoring confirms "the script ran recently" but never validates that backups are actually restorable. A periodic script that downloads the latest backup, runs `age -d`, and validates tarball contents would close the gap. Could run weekly on Proxmox.
- **Cobra Post-Processing Monitoring** `V:Med E:Med` — Plex, Transmission, and Samba are all monitored with hourly health checks. The gap is the tvnamer/rename pipeline: if RSS downloads content but post-processing fails to organize it, nothing alerts. Needs design work — what does "tvnamer failed" look like? (stale files in download dir? log parsing?)

### Low Value/Effort — Deferred

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
