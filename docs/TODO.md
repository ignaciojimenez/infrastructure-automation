# Infrastructure TODO — Prioritized Action List

Updated: 2026-03-23 | Validated against live hosts

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

---

## Priority 3 — Backup Freshness Monitoring

**Risk:** Backups are now automated, but there is no alerting if they silently fail. The `enhanced_monitoring_wrapper` catches script failures via Slack, but if the cron itself doesn't fire (host rebooted, crontab corrupted), there is zero visibility.

### Verified State (2026-03-22)
- No backup age monitoring exists for any host
- All backups upload to curlbin — success/failure is only visible via Slack notifications from `enhanced_monitoring_wrapper`
- If the cron doesn't fire or the wrapper itself crashes, there is zero visibility

### Recommended Approach: healthchecks.io Backup Heartbeats
Add a healthchecks.io ping at the end of each successful backup. Healthchecks.io natively supports expected schedules — set "expect daily" with a grace period, and it alerts (via email/push) if the ping never comes. This catches silent cron failures, host reboots, and broken backup scripts — and works even when Slack itself is down.

### Next Steps
1. Create 5 healthchecks.io checks (one per backup host: HA daily, OPNsense daily, Proxmox weekly, Plex weekly, UniFi daily)
2. Add vault variables (`vault_healthcheck_backup_*`) for each check URL
3. Append `&& curl -fsS -m 10 "$HC_URL"` to each backup cron job (or create small heartbeat wrappers)
4. Configure expected periods and grace on healthchecks.io (daily: 24h period + 6h grace, weekly: 7d + 2d)

### Acceptance Criteria
- [ ] Each backup host has a healthchecks.io check with correct expected period
- [ ] Successful backup triggers a ping; missed backup triggers healthchecks.io alert
- [ ] Alert channel is independent of Slack (email or push notification)

---

## Priority 4 — Proxmox USB Recovery Kit + Backup Restore Testing

**Risk:** All Proxmox data — OS, VM disk images, and vzdump backups — lives on a single 512GB NVMe (`rpool`). A drive failure loses everything including the local backup copies. The offsite curlbin backups cover service configs (config.xml, .unf, HA backup), but the fast-path recovery using vzdump snapshots would be gone. Additionally, no backup has ever been test-restored.

### Verified State (2026-03-22)
- Single NVMe pool `rpool`: 254G used / 472G total
- vzdump runs daily at 03:00 for active guests (VM 100 + LXC 101), 15-day retention — **not Ansible-managed**, configured in Proxmox `jobs.cfg`
- Latest vzdump sizes: OPNsense VM ~12G, UniFi LXC ~1.1G
- vzdump backups consume 201G in `/var/lib/vz/dump/` — all on the same NVMe (consider removing stopped LXC 102/pihole from vzdump schedule)
- No offsite or separate-media copy of vzdump snapshots exists
- No backup restore has ever been tested end-to-end

### Next Steps

**Part A — USB Recovery Drive**
1. Purchase a 64GB USB drive (fits latest vzdump of each guest ×3 days + Proxmox ISO + `/etc/pve/` backup, with room to grow)
2. Format as ext4, mount on Proxmox (e.g., `/mnt/usb-recovery`)
3. Create a script that copies the latest vzdump for each guest + `/etc/pve/` to the USB, run weekly via cron
4. Include Proxmox installer ISO on the drive
5. Add a recovery checklist text file on the drive itself

**Part B — Quarterly Backup Restore Test**
1. Pick one backup (rotate through hosts each quarter)
2. Download from curlbin, decrypt, inspect contents
3. For vzdump: test-restore to a temporary VM/LXC on Proxmox, verify it boots
4. Document results and any issues found
5. First test: OPNsense config.xml restore into a throwaway VM

### Acceptance Criteria
- [ ] USB drive mounted and receiving weekly copies of latest vzdump snapshots
- [ ] Recovery checklist on the USB drive matches `docs/BACKUP_AND_RECOVERY.md`
- [ ] At least one backup restore test completed and documented

### Notes
- 64GB is sufficient: latest vzdump total is ~14G per snapshot, ×3 days = ~42G plus ~5G for ISOs and overhead
- The USB is not a replacement for curlbin offsite backups — it's a fast-path for the "NVMe died, ZFS data gone" scenario
- vzdump backup schedule is in Proxmox `jobs.cfg`, not Ansible — consider managing it via Ansible in a future iteration
- This complements Priority 3 (freshness monitoring): freshness catches silent cron failures, this catches hardware failure of the backup medium itself

---

## Priority 5 — OPNsense Ansible Consolidation

**Risk:** Tech debt, not active breakage. Legacy scripts and a legacy playbook file coexist with the current role-based deployment. The legacy cron section has `enable_cron_monitoring | default(false)` so it won't fire accidentally, but the 9 old scripts waste disk space and 2 manual cron entries lack the `#Ansible:` prefix.

### Verified State (2026-03-17)
- **9 legacy monitoring scripts** (hyphenated names, root-owned, Oct 2025) coexist with 10 current scripts:
  - Legacy: `check-crowdsec.sh`, `check-ddns.sh`, `check-ddns-age.sh`, `check-disk-space.sh`, `check-gateway.sh`, `check-interface.sh`, `check-memory.sh`, `check-system-load.sh`, `check-wg.sh`
  - Current (Ansible-managed): `check_crowdsec.sh`, `check_ddns.sh`, `check_dns_health.sh`, `check_gateway.sh`, `check_guest_agent.sh`, `check_system_health.sh`, `check_vpn_gateway.sh`, `check_wg.sh`, `heartbeat_opnsense_wan.sh`, `monitor_dns_failover.sh`
- **2 manual cron entries** (no `#Ansible:` prefix):
  - `# DNS failover monitoring (VPN-based)` — runs every minute
  - `# DNS resolution health check` — runs every 5 minutes
- **Two Ansible deployment paths**:
  1. Role: `ansible/roles/platform/opnsense/tasks/main.yml` — deploys 8 scripts + crons with `#Ansible:` prefix (active)
  2. Playbook tasks: `ansible/playbooks/tasks/opnsense_monitoring.yml` — uses legacy `scripts/freebsd/` paths, hardcoded `root` user, `enable_cron_monitoring | default(false)` (inert)

### Next Steps
1. Add the 2 manual cron entries (DNS failover + DNS health) to the OPNsense Ansible role so they become Ansible-managed
2. Add `state: absent` tasks in the role to remove the 9 legacy hyphenated scripts from `/usr/local/bin/monitoring/`
3. Remove `ansible/playbooks/tasks/opnsense_monitoring.yml` (legacy path, inert)
4. Verify with `--check --diff` that no duplicates would be created
5. Deploy and confirm crontab matches expected state

### Acceptance Criteria
- [ ] All OPNsense crons have `#Ansible:` prefix
- [ ] Legacy `check-*.sh` scripts removed from host
- [ ] `opnsense_monitoring.yml` playbook tasks removed
- [ ] `ansible-playbook deploy_monitoring.yml --limit opnsense --check --diff` shows clean state

---

## Priority 6 — Tado Health Check Ansible Integration

**Risk:** `check_tado_health.sh` is the only monitoring script not managed by Ansible. If dockassist is rebuilt, this monitoring silently disappears. However, the script is not currently deployed or running, and nobody has noticed — the heating system works regardless.

### Verified State (2026-03-17)
- Script exists in repo: `scripts/services/homeassistant/check_tado_health.sh`
- Script was migrated from SQLite to HA REST API (commit `a7f6221`, Jan 2026)
- Script is NOT deployed on dockassist — `ls /home/choco/scripts/check_tado_health.sh` returns NOT FOUND
- No Ansible cron entry exists for it on dockassist
- Script checks device tracker freshness via HA REST API (person.choco, person.candela, device trackers)

### Next Steps
1. Add script deployment to homeassistant role (`ansible/roles/services/homeassistant/tasks/main.yml`)
2. Add cron scheduling (suggest every 30 minutes, using enhanced_monitoring_wrapper)
3. Deploy and verify script runs successfully on dockassist

### Acceptance Criteria
- [ ] Script deployed to `/home/choco/.scripts/check_tado_health.sh` on dockassist
- [ ] Ansible cron with `#Ansible:` prefix in dockassist crontab
- [ ] Script returns OK when Tado devices are reporting

---

## Priority 7 — Ansible Playbook CI (Syntax + Lint)

**Risk:** Broken YAML or undefined variables are only caught during manual deploys. Low probability but easy to prevent.

### Verified State (2026-03-17)
- No `.github/workflows/` directory exists
- `.ansible-lint` config exists (skips yaml[line-length], no-changed-when; warns on command-instead-of-shell)
- No automated testing of any kind

### Next Steps
1. Create `.github/workflows/ansible-lint.yml` with `ansible-playbook --syntax-check` on all playbooks
2. Add `ansible-lint` run using existing `.ansible-lint` config
3. Optionally add YAML validation for inventory and group_vars

### Acceptance Criteria
- [ ] GitHub Actions workflow runs on push/PR
- [ ] All playbooks pass syntax check
- [ ] ansible-lint passes with current config

---

## Priority 8 — Ephemeral Ansible Testing Environment

**Risk:** Ansible playbooks are only validated via `--check --diff` against live hosts. A full reprovision from scratch is untested — broken dependency ordering, missing template variables, or service startup failures would only surface during a real rebuild, which is exactly the worst time to discover them.

### Verified State (2026-03-17)
- No testing infrastructure exists
- No GitHub Actions CI (see Priority 7 for basic lint)
- Proxmox is available as a hypervisor and can create LXC containers and VMs via API
- Current host types to simulate:
  - **Debian-based RPi hosts** (dockassist, cobra, hifipi, vinylstreamer) — LXC containers are a close match (same OS, ARM differences are minor for config management)
  - **Debian Proxmox** — LXC container with Proxmox packages is partial but useful
  - **FreeBSD OPNsense** — requires a FreeBSD VM; hardest to simulate accurately (OPNsense-specific tooling like `configctl`, Unbound, WireGuard)
  - **LXC containers** (unifi-lxc) — nested LXC or a regular container works
- Ansible inventory already uses variable-driven configuration (`enable_*` toggles, `primary_function`) which makes test inventory creation straightforward

### Approach

**Phase 1 — Debian LXC test harness (medium effort, high value)**
1. Create an Ansible playbook (`test_environment.yml`) that provisions ephemeral LXC containers on Proxmox via `community.general.proxmox` module
2. Use a Debian 12 template matching RPi hosts — containers get temporary IPs and a test inventory
3. Run `bootstrap.yml` + `services.yml` against test containers
4. Run validation scripts that check expected state: services running, crons present, scripts deployed, config files rendered correctly
5. Destroy containers after test completes (or on failure, for debugging)

**Phase 2 — Validation framework (medium effort, high value)**
1. Create per-role validation scripts (e.g., `validate_homeassistant.sh` checks Docker containers running, crons present, HA config rendered)
2. These double as post-deploy smoke tests on real hosts
3. Integrate with CI: provision → deploy → validate → destroy

**Phase 3 — FreeBSD VM for OPNsense (high effort, medium value)**
1. FreeBSD VM template on Proxmox for OPNsense role testing
2. Cannot fully simulate OPNsense (no `configctl`, no Unbound config path) but can validate script deployment, cron scheduling, and POSIX compatibility
3. Consider whether config backup/restore (Priority 1) makes this less critical

### What This Enables
- Confident reprovisioning of any host from scratch
- Safe testing of major refactors (e.g., Priority 5's OPNsense consolidation)
- Pre-merge validation in CI (Phase 2+)
- New host onboarding without fear of breaking existing patterns

### Limitations to Accept
- ARM vs x86 differences won't be caught (RPi-specific hardware like GPIO, USB DAC passthrough)
- Network topology differences (test LXCs won't have VPN tunnels, WireGuard, or real DNS)
- Service-level integration (e.g., actual Tado API, curlbin uploads) can't be tested without mocking
- OPNsense simulation will always be incomplete — real validation still needs the live host

### Next Steps
1. Create `ansible/playbooks/testing/provision_test_env.yml` using `community.general.proxmox` module
2. Create test inventory template (`ansible/inventory/test_hosts.yml`) with `enable_*` toggles matching a target host
3. Write a wrapper script (`scripts/testing/run_test.sh`) that orchestrates: create → provision → validate → destroy
4. Start with one host type (dockassist/homeassistant) as proof of concept
5. Expand to other host types incrementally

### Acceptance Criteria
- [ ] Phase 1: Can provision a test LXC, run bootstrap + services playbook, and destroy it via a single command
- [ ] Phase 1: At least one host type (homeassistant) fully testable
- [ ] Phase 2: Validation scripts exist for homeassistant, media, and audio roles
- [ ] Phase 2: CI integration runs on PR

---

## Priority 9 — Proxmox WebUI User Migration

**Risk:** WebUI uses `root@pam` which is a security anti-pattern. Low practical risk in home network but poor hygiene.

### Verified State (2026-03-17)
- `choco` Linux user exists on Proxmox (`choco:x:1000:1000`)
- `choco@pam` exists in Proxmox user management (confirmed via `pveum user list`)
- SSH already uses `choco` user (all Ansible crons run as choco)
- `root@pam` still exists and is likely used for WebUI login
- No `choco@pve` user exists (PVE realm user, which would be separate from PAM)
- Unclear what permissions `choco@pam` has in Proxmox WebUI

### Next Steps
1. Check current `choco@pam` permissions: `pveum acl list` on cwwk
2. Grant `choco@pam` appropriate PVE permissions (Administrator or PVEAdmin role on `/`)
3. Test WebUI login with `choco@pam`
4. If working, stop using `root@pam` for WebUI access
5. Update Ansible bootstrap to handle this if not already covered

### Acceptance Criteria
- [ ] WebUI accessible via `choco@pam` with sufficient permissions
- [ ] `root@pam` no longer used for routine WebUI access

### Notes
- This is the lowest-priority active item because `choco@pam` already exists and SSH is already non-root
- The only gap is WebUI login habit, not infrastructure configuration

---

## Resolved Items

- **Backup Encryption Portability (GPG → age)** — Completed 2026-03-23. Migrated all 5 backup pipelines from GPG asymmetric to age asymmetric encryption. Decision: age keypair chosen over GPG (complex recovery), age passphrase (symmetric = security downgrade), openssl enc (no AEAD), and age+SSH keys (incompatible with Secretive). Recovery path: `brew install age` + paste one-line secret key from password manager → decrypt. Old `.gpg` backups remain decryptable with the GPG key.
- **Backup Automation (OPNsense + Proxmox)** — Completed 2026-03-22. Both scripts deployed via Ansible cron (OPNsense daily 04:15, Proxmox weekly 04:00), first backups verified in curlbin. Recovery guide: `docs/BACKUP_AND_RECOVERY.md`.
- **VPN Country Switcher UUIDs** — All 4 UUIDs verified in `/conf/config.xml`. Script functional.
- **Plex on Cobra** — Active since 2026-03-15. Monitoring and backup crons deployed.
- **DNS Resilience** — 4-tunnel Mullvad + Cloudflare fallback operational. Failover every minute, health check every 5 minutes.
- **Tado SQLite migration** — Completed (commit `a7f6221`). Uses HA REST API. Not yet deployed on host (see Priority 6).
- **vinylstreamer liquidsoap inactive** — Expected. Runs only during active streaming sessions.

---

## Priority 10 — TADO/HA Presence Notification Elegance

**Risk:** Cosmetic — no functional impact. Current behavior sends two contradictory Slack notifications when user is nearby (~500m from home): HA fires "AWAY mode activated" after 10min debounce, then `tado_presence.sh` fires "TADO says device still home, skipping AWAY". Expected behavior producing confusing double-alerts.

### Current State (2026-03-21)
- HA automation `away_mode_everyone_left` triggers after 10min of `group.persons != home`
- The automation immediately sends a Slack alert ("Away mode activated") AND calls `tado_set_away`
- `tado_presence.sh` queries Tado's `mobileDevices` API before applying `presenceLock`
- If any Tado device reports `atHome: true` (within ~500m geofence), the script skips AWAY and sends its own Slack alert
- Result: user sees "AWAY activated" immediately followed by "TADO AWAY skipped — device still home"
- No cron job involved — both notifications are triggered by the same HA automation action sequence

### Proposed Fix
Restructure the away automation to defer the Slack notification until after the TADO script confirms the away was applied:
1. Remove the `slack_alert` call from the automation's action sequence
2. Have `tado_presence.sh` send the appropriate notification based on outcome:
   - AWAY applied → "Away mode activated, TADO set to AWAY"
   - AWAY skipped → "HA detected away, but TADO device still home — heating unchanged"
3. This way exactly one notification is sent, and it reflects the actual outcome
4. Alternative: keep both notifications but downgrade the "skipped" message to the logging channel (since it's informational, not an alert)

### Acceptance Criteria
- [ ] Only one Slack notification when leaving home (whether TADO away succeeds or is skipped)
- [ ] Notification accurately reflects the final state (TADO away vs. still home)
- [ ] No functional change to the presence detection or TADO control logic

---

## Priority 11 — Read-Only Agent Access for Autonomous Investigation

**Risk:** Currently, Claude agents require manual SSH authentication (Secretive biometric) or web API tokens to investigate issues. This blocks autonomous, real-time diagnostics across the infrastructure. Goal is to enable agents to investigate any system (SSH, web UIs, logs) without requiring human intervention or biometric auth, while maintaining strict read-only guarantees.

### Verified State (2026-03-21)
- All SSH keys in Secretive (Secure Enclave) — non-exportable, require biometric auth for each use
- Home Assistant API token exists and can be read from `/home/choco/homeassistant/secrets.yaml` on dockassist
- Proxmox WebUI accessible via `choco@pam` with admin permissions (likely)
- OPNsense WebUI accessible via SSH tunnel (requires SSH auth) or direct HTTPS
- UniFi API documented but not tested for read-only access
- No dedicated read-only SSH user or limited-privilege API tokens exist

### Approach

**Phase 1 — Discovery & Planning (low effort)**
1. Inventory all systems needing agent access:
   - SSH: dockassist, cobra, hifipi, vinylstreamer (RPi), opnsense (FreeBSD), proxmox (Debian), unifi-lxc (LXC)
   - Web UIs: Home Assistant, Proxmox, OPNsense, UniFi, Plex
   - Log files: syslog/journald on each host, HA logs
2. For each system, identify read-only access method:
   - **SSH**: create dedicated agent-only user (e.g., `claude_agent`) with sudo access to specific read commands, shell restricted to `/bin/sh` or similar
   - **Web APIs**: generate long-lived read-only API tokens where possible (HA, Proxmox, UniFi, Plex)
   - **Logs**: either agent SSH user can read logs directly, or set up `tail -f` endpoints via authenticated HTTP proxy
3. Document required authentication: which tokens/users go in repo vs. password manager vs. created at bootstrap time
4. Security model: agent access is IP-scoped (Claude's IPs only) or uses API token rate limiting / audit logging

**Phase 2 — Implementation (medium effort)**
1. Create `claude_agent` user on each host with minimal sudo privileges: `sudo grep -r`, `sudo journalctl`, `sudo netstat`, `sudo ps`, read-only systemctl status
2. Generate or configure read-only API tokens:
   - Home Assistant: read-only token (already supports scoped tokens)
   - Proxmox: PVE API token with read-only role (no VM/LXC control)
   - UniFi: read-only API token (need to verify API supports this)
   - Plex: read-only API token
3. Store tokens in password manager or project secrets, document format for agent use
4. Ansible bootstrap tasks: deploy user account, configure sudo rules, create tokens during initial setup
5. Test agent can:
   - SSH to each host, run read-only diagnostic commands
   - Query each web API without human intervention
   - Return meaningful diagnostics (service status, recent errors, resource usage)

**Phase 3 — Agent Integration (medium effort)**
1. Provision agent access credentials to Claude via environment or MCP server
2. Create diagnostic playbooks/scripts agents can invoke: `check_host_health.sh`, `diagnose_service.sh`, etc.
3. Document what information agents are authorized to collect (logs, metrics, config—no secrets)
4. Set up audit logging so all agent actions are logged to a notification channel (for visibility)

### What This Enables
- **Real-time diagnosis**: agents can SSH to any host, check systemd status, tail logs, query APIs without waiting for user auth
- **Faster incident response**: "the homeassistant Docker container is down" → agent can SSH, run `docker ps`, check logs, and propose a fix without human context-switching
- **Pattern detection**: agents can correlate events across hosts (e.g., "cobra rebooted at 03:45, vinylstreamer lost connectivity at 03:46, both recovered by 04:00")
- **Scheduled diagnostics**: agents can run periodic health checks and surface trends (disk usage growth, error rates, dependency version drift)

### Safety Guardrails
- Read-only enforcement: agent users cannot `sudo reboot`, `sudo systemctl restart`, `sudo rm`, etc.
- SSH key restriction: agent keys accept commands via forced command in authorized_keys (if using key-based auth)
- API token scoping: read-only tokens, optionally rate-limited
- Audit trail: all agent access logged (syslog, API audit logs)
- No secret access: agent cannot read vault.yml, .tado_tokens, SSL certs, API keys

### Limitations to Accept
- Agent cannot make changes; fixes still require human confirmation or separate privileged access
- Agent access is one-way (agents can observe, not control)
- Some diagnostics require running privileged commands (e.g., packet captures); agents can only read summaries
- Network topology issues (VPN outage, gateway unreachable) may prevent agent SSH access to affected hosts

### Next Steps
1. Document all systems and required read-only access methods (SSH user, API tokens)
2. Design sudo rules for agent user on each host
3. Create Ansible bootstrap tasks for agent user deployment
4. Generate read-only API tokens where supported (HA, Proxmox, UniFi, Plex)
5. Test agent can invoke all planned diagnostic commands

### Acceptance Criteria
- [ ] `claude_agent` user deployed on all production hosts via Ansible
- [ ] Agent can SSH to any host and run read-only diagnostics without human auth
- [ ] Agent can query HA, Proxmox, UniFi, Plex APIs using long-lived read-only tokens
- [ ] Audit trail visible for all agent access (logged to Slack notification channel)
- [ ] Documentation: what agent can access, how to revoke access, how to audit actions

---

## Deferred / Low Priority

These items have value but are not urgent. Revisit quarterly.

- **Slack Notification Strategy Review** — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies: train notifications go to `alert` (arguably informational), away mode goes to `alert` but home arrival goes to `notify`, DNS failover sends to both channels simultaneously, device offline alerts are split inconsistently between channels. A focused review session to audit all ~20 notification sources and reassign channels would improve signal-to-noise. Low effort, low urgency — current setup is functional and understood. May conclude that current state is good enough for a single-user system.
- **Autonomous Infrastructure Agent** — Ambitious vision: an agent that monitors Slack alerts, host logs, and service health in real-time, then autonomously diagnoses, proposes solutions, and applies fixes without human intervention. Would need: Slack integration for alert intake, SSH access to hosts, diagnostic playbooks per failure type, a decision framework for when to auto-fix vs. notify, and safety guardrails to prevent cascading failures. High complexity — this is effectively building an SRE agent. Recommend scoping as a phased project: Phase 1 (alert aggregation + pattern matching), Phase 2 (diagnostic automation), Phase 3 (auto-remediation with approval gates). Worth exploring after Priorities 1-4 stabilize the monitoring foundation.
- **Mullvad DoT Fallback** — Encrypting DNS during full VPN outage. Low urgency with 4-tunnel architecture; full VPN outage is rare. Would only affect the Cloudflare fallback path.
- **Certificate Expiration Monitoring** — Monitor Proxmox + OPNsense web certs. Low effort, medium value. Alert at 30 days warning, 7 days critical.
- **SMART Disk Health Monitoring** — Predict disk failures on Proxmox (ZFS) and cobra (media storage). Low effort, medium value.
- **Eve Sensor Matter Pairing** — Prerequisites met (Matter Server deployed, batteries replaced). Manual pairing process via Apple Home.
- **Full Infrastructure as Code (Proxmox/OPNsense)** — High complexity for rarely-changing configs. Good config backups (Priority 1) may be sufficient.
- **Cobra Media Config Consolidation** — Merge separate cobra repo into media role. Cosmetic improvement.
- **Tidal Receiver on hifipi** — Add Tidal Connect receiver alongside existing Shairport/Raspotify. Never been necessary; hifipi already covers AirPlay and Spotify Connect. Low effort if a good open-source receiver emerges.
