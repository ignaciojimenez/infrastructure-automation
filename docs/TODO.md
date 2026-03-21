# Infrastructure TODO — Prioritized Action List

Updated: 2026-03-17 | Validated against live hosts

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

---

## Priority 1 — Backup Automation (OPNsense + Proxmox)

**Risk:** Firewall config loss = full manual rebuild of WireGuard tunnels, DNS rules, CrowdSec, and all firewall rules. Proxmox host loss = loss of OPNsense VM + UniFi LXC with no offsite config copy.

### Verified State (2026-03-17)
- `do_backup` is deployed and functional on both hosts:
  - OPNsense: `/usr/local/bin/do_backup` (Nov 2025)
  - Proxmox: `/home/choco/.scripts/do_backup` (Mar 2026)
- Backup scripts exist on `feat/backup-scripts` branch (1 commit: `79c336e`):
  - `scripts/services/opnsense/backup_opnsense.sh` (137 lines, POSIX sh — FreeBSD compatible)
  - `scripts/services/proxmox/backup_proxmox_config.sh` (173 lines, bash)
- Neither script is deployed to its target host
- No Ansible role or cron exists for either script
- `do_backup` uses bash syntax (`[[`, `=~`, `set -o pipefail`) — works on OPNsense because bash is installed at `/usr/local/bin/bash` (GNU bash 5.3.9)

### Next Steps
1. Merge `feat/backup-scripts` branch to main
2. Add Ansible tasks to OPNsense platform role (`ansible/roles/platform/opnsense/tasks/main.yml`) to deploy `backup_opnsense.sh` and schedule daily cron
3. Add Ansible tasks to Proxmox platform role (`ansible/roles/platform/proxmox/tasks/main.yml`) to deploy `backup_proxmox_config.sh` and schedule weekly cron
4. Add vault vars for any missing webhook tokens or GPG email references
5. Deploy to both hosts and verify first backup completes end-to-end (encryption + upload to curlbin)

### Acceptance Criteria
- [x] Both scripts deployed via Ansible with `#Ansible:` cron prefix
- [x] First backup from each host visible in curlbin
- [ ] Slack notification received on success (verified via cron on next scheduled run)

### Notes
- Proxmox configs rarely change — weekly schedule is sufficient
- OPNsense config changes more often (firewall rules, DNS) — daily is appropriate
- Home Assistant backup already runs daily at 04:00 via Ansible cron on dockassist
- UniFi backup already runs daily at 03:00 via Ansible cron on unifi-lxc
- Plex backup already runs every 7 days at 04:00 via Ansible cron on cobra

---

## Priority 2 — OPNsense Ansible Consolidation

**Risk:** Running Ansible on OPNsense could create duplicate crons or deploy conflicting wrapper scripts. Manual crons lack the `#Ansible:` prefix and will not be managed by Ansible.

### Verified State (2026-03-17)
- **9 legacy monitoring scripts** (hyphenated names, root-owned, Oct 2025) coexist with 10 current scripts:
  - Legacy: `check-crowdsec.sh`, `check-ddns.sh`, `check-ddns-age.sh`, `check-disk-space.sh`, `check-gateway.sh`, `check-interface.sh`, `check-memory.sh`, `check-system-load.sh`, `check-wg.sh`
  - Current (Ansible-managed): `check_crowdsec.sh`, `check_ddns.sh`, `check_dns_health.sh`, `check_gateway.sh`, `check_guest_agent.sh`, `check_system_health.sh`, `check_vpn_gateway.sh`, `check_wg.sh`, `heartbeat_opnsense_wan.sh`, `monitor_dns_failover.sh`
- **2 manual cron entries** (no `#Ansible:` prefix):
  - `# DNS failover monitoring (VPN-based)` — runs every minute
  - `# DNS resolution health check` — runs every 5 minutes
- **Two Ansible deployment paths**:
  1. Role: `ansible/roles/platform/opnsense/tasks/main.yml` — deploys 8 scripts + crons with `#Ansible:` prefix
  2. Playbook tasks: `ansible/playbooks/tasks/opnsense_monitoring.yml` — uses legacy `scripts/freebsd/` paths and hardcoded `root` user
- The role (path 1) is the active/correct one. The playbook tasks file (path 2) appears to be legacy.

### Next Steps
1. Add the 2 manual cron entries (DNS failover + DNS health) to the OPNsense Ansible role so they become Ansible-managed
2. Add `state: absent` tasks in the role to remove the 9 legacy hyphenated scripts from `/usr/local/bin/monitoring/`
3. Remove or archive `ansible/playbooks/tasks/opnsense_monitoring.yml` (legacy path)
4. Verify with `--check --diff` that no duplicates would be created
5. Deploy and confirm crontab matches expected state

### Acceptance Criteria
- [ ] All OPNsense crons have `#Ansible:` prefix
- [ ] Legacy `check-*.sh` scripts removed from host
- [ ] `opnsense_monitoring.yml` playbook tasks removed or archived
- [ ] `ansible-playbook deploy_monitoring.yml --limit opnsense --check --diff` shows clean state

---

## Priority 3 — Backup Freshness Monitoring

**Risk:** Once backups are automated (Priority 1), there is no alerting if they silently fail. This is the #1 monitoring gap.

### Verified State (2026-03-17)
- No backup age monitoring exists for any host
- All backups upload to curlbin — success/failure is only visible via Slack notifications from `do_backup`
- If `do_backup` itself crashes or the cron doesn't fire, there is zero visibility

### Next Steps
1. Create a `check_backup_freshness.sh` script that queries curlbin (or local backup timestamps) for each service
2. Alert if last successful backup exceeds threshold (24h for daily, 8 days for weekly)
3. Deploy via Ansible to the monitoring host (dockassist or proxmox)
4. Schedule as daily cron

### Acceptance Criteria
- [ ] Script deployed and running via Ansible cron
- [ ] Slack alert fires when backup is stale (test by temporarily moving last backup)

---

## Priority 4 — Tado Health Check Ansible Integration

**Risk:** `check_tado_health.sh` is the only monitoring script not managed by Ansible. If dockassist is rebuilt, this monitoring silently disappears.

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

## Priority 5 — GPG to age Encryption Migration

**Risk:** GPG key lives only on laptop. Laptop loss or failure means cannot decrypt backups or run backup scripts from any other device. Recovery from backups becomes impossible in the scenario where you most need it.

### Verified State (2026-03-17)
- All backup encryption uses GPG (do_backup calls `gpg --encrypt`)
- SSH keys are in Secretive (Secure Enclave) — not exportable
- Two YubiKeys exist with SSH keys (untested recently)
- User rarely decrypts backups in practice — the portability problem is theoretical but the bus-factor risk is real
- age has not been tested yet — research needed on compatibility with existing SSH key infrastructure

### Next Steps
1. Research: test `age` encryption/decryption locally, verify it works with SSH keys from Secretive
2. Generate age key pair; store public key in repo, private key in password manager
3. Update `scripts/common/do_backup` to support age as encryption backend (consider feature flag during transition)
4. Migrate all backup scripts from GPG to age
5. Verify decryption works from a different device (phone or secondary machine)

### Acceptance Criteria
- [ ] age key pair generated and private key stored securely offsite
- [ ] `do_backup` uses age for encryption
- [ ] At least one backup successfully decrypted from a non-laptop device

---

## Priority 6 — Ansible Playbook CI (Syntax + Lint)

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

## Priority 7 — Ephemeral Ansible Testing Environment

**Risk:** Ansible playbooks are only validated via `--check --diff` against live hosts. A full reprovision from scratch is untested — broken dependency ordering, missing template variables, or service startup failures would only surface during a real rebuild, which is exactly the worst time to discover them.

### Verified State (2026-03-17)
- No testing infrastructure exists
- No GitHub Actions CI (see Priority 6 for basic lint)
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
- Safe testing of major refactors (e.g., Priority 2's OPNsense consolidation)
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

## Priority 8 — Proxmox WebUI User Migration

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

## Resolved Items (Validated 2026-03-17)

Items previously flagged as issues that are confirmed working:

- **VPN Country Switcher UUIDs** — All 4 UUIDs (`1a80d8ce`, `352f80d2`, `342fd91c`, `8029390a`) verified present in `/conf/config.xml` on OPNsense. Script is functional. No action needed.
- **Plex on Cobra** — `plexmediaserver.service` is active and running (since 2026-03-15). Ansible crons for monitoring and backup are deployed. Transmission, Samba, VPN checks all running. No action needed.
- **devpi host** — Not in Ansible inventory. Likely decommissioned. Remove any stale references if found in docs.
- **DNS Resilience** — 4-tunnel Mullvad architecture with Cloudflare fallback operational. DNS failover runs every minute, health check every 5 minutes. Fully functional.
- **Tado SQLite migration** — Completed (commit `a7f6221`). Script uses HA REST API. But note: script is not yet deployed (see Priority 4).
- **vinylstreamer liquidsoap inactive** — Expected behavior. Liquidsoap only runs during active vinyl streaming sessions. Icecast is active and ready.

---

## Priority 9 — TADO/HA Presence Notification Elegance

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

## Priority 10 — Read-Only Agent Access for Autonomous Investigation

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
- **Keep CURRENT_INFRASTRUCTURE_STATE.md Updated** — Last updated March 2026. Update after completing Priority 1-2.
