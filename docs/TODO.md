# Infrastructure TODO — Prioritized Action List

Updated: 2026-03-30 | Validated against live hosts

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

---

---

## Priority 5 — Refactor `monitor_dns_failover.sh` for Wrapper Consistency

**Risk:** Low. The script works correctly but bypasses the `enhanced_monitoring_wrapper` pattern used by all other monitoring scripts across all hosts. It's a 244-line state machine with its own Slack alerting, local logging fallback (`/var/log/dns_failover_alerts.log`), and state file tracking (`/tmp/dns_failover_state`). Token order is reversed from the wrapper convention (alert first, logging second) — documented in the role with comments.

### Why It Matters
Inconsistency makes the monitoring setup harder to reason about. Every other cron on every host uses the wrapper for Slack notifications, state tracking, and heartbeats. This is the one exception.

### Why It's Non-Trivial
- The script modifies `/conf/config.xml` directly to switch DNS forwarders — it's not a passive check
- Exit code semantics differ: a successful failover to Cloudflare is exit 0 (correct behavior), not a failure
- Has its own duplicate-alert suppression and recovery notification logic
- Wrapping naively would cause double Slack notifications
- Any bug during refactor risks DNS resolution (internet access)

### Next Steps
1. Evaluate whether `enhanced_monitoring_wrapper` can be extended to support state-machine scripts, or whether the script's alerting should be stripped and replaced with wrapper calls
2. Test thoroughly in a non-production context before deploying

---

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

---

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

## Lower Priority

These items have value but are not urgent. Revisit quarterly.

- **Slack Notification Strategy Review** — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies: train notifications go to `alert` (arguably informational), away mode goes to `alert` but home arrival goes to `notify`, DNS failover sends to both channels simultaneously, device offline alerts are split inconsistently between channels. A focused review session to audit all ~20 notification sources and reassign channels would improve signal-to-noise. Low effort, low urgency — current setup is functional and understood. May conclude that current state is good enough for a single-user system.
- **Autonomous Infrastructure Agent** — Ambitious vision: an agent that monitors Slack alerts, host logs, and service health in real-time, then autonomously diagnoses, proposes solutions, and applies fixes without human intervention. Would need: Slack integration for alert intake, SSH access to hosts, diagnostic playbooks per failure type, a decision framework for when to auto-fix vs. notify, and safety guardrails to prevent cascading failures. High complexity — this is effectively building an SRE agent. Recommend scoping as a phased project: Phase 1 (alert aggregation + pattern matching), Phase 2 (diagnostic automation), Phase 3 (auto-remediation with approval gates). Worth exploring after Priorities 1-4 stabilize the monitoring foundation.
- **Mullvad DoT Fallback** — Encrypting DNS during full VPN outage. Low urgency with 4-tunnel architecture; full VPN outage is rare. Would only affect the Cloudflare fallback path.
- **Certificate Expiration Monitoring** — Monitor Proxmox + OPNsense web certs. Low effort, medium value. Alert at 30 days warning, 7 days critical.
- **SMART Disk Health Monitoring** — Predict disk failures on Proxmox (ZFS) and cobra (media storage). Low effort, medium value.
- **Full Infrastructure as Code (Proxmox/OPNsense)** — High complexity for rarely-changing configs. Good config backups (Priority 1) may be sufficient.
- **Cobra Media Config Consolidation** — Merge separate cobra repo into media role. Cosmetic improvement.
- **Tidal and Qobuz Receiver on hifipi** — Add Tidal and Qobuz receiver alongside existing Shairport/Raspotify. Never been necessary; hifipi already covers AirPlay and Spotify Connect. Low effort if a good open-source receiver emerges.

---


## Resolved Items

- **Ansible Playbook CI (Syntax + Lint)** — Completed 2026-04-04. `.github/workflows/ansible-lint.yml` implemented, running `ansible-lint` on push/PR.
- **Proxmox USB Recovery Kit + Backup Restore Testing** — Completed 2026-03-30. 128GB USB drive at `/mnt/usb-recovery`, syncing weekly (Sunday 05:00) via `sync_usb_recovery.sh`. Two-generation rotation (`current/` + `previous/`), RECOVERY.txt checklist, MANIFEST.txt with checksums. First restore test passed: UniFi LXC 101 vzdump → temporary CT 999, filesystem verified intact. LXC restores require `--storage local-zfs` — documented in RECOVERY.txt and BACKUP_AND_RECOVERY.md.
- **Backup Freshness Monitoring** — Completed 2026-03-28. Added `heartbeat_backup.sh` reusable template in `scripts/common/`, deployed as standalone heartbeat scripts (one per backup host) following the existing healthchecks.io pattern. Each checks the `enhanced_monitoring_wrapper` state file for recent success, pings healthchecks.io every 2 hours. 5 checks: HA/OPNsense/UniFi daily (26h max age), Proxmox/Plex weekly (172h max age). Independent of Slack — catches silent cron failures, host reboots, and broken scripts.
- **Backup Encryption Portability (GPG → age)** — Completed 2026-03-23. Migrated all 5 backup pipelines from GPG asymmetric to age asymmetric encryption. Decision: age keypair chosen over GPG (complex recovery), age passphrase (symmetric = security downgrade), openssl enc (no AEAD), and age+SSH keys (incompatible with Secretive). Recovery path: `brew install age` + paste one-line secret key from password manager → decrypt. Old `.gpg` backups remain decryptable with the GPG key.
- **Backup Automation (OPNsense + Proxmox)** — Completed 2026-03-22. Both scripts deployed via Ansible cron (OPNsense daily 04:15, Proxmox weekly 04:00), first backups verified in curlbin. Recovery guide: `docs/BACKUP_AND_RECOVERY.md`.
- **VPN Country Switcher UUIDs** — All 4 UUIDs verified in `/conf/config.xml`. Script functional.
- **Plex on Cobra** — Active since 2026-03-15. Monitoring and backup crons deployed.
- **DNS Resilience** — 4-tunnel Mullvad + Cloudflare fallback operational. Failover every minute, health check every 5 minutes.
- **OPNsense Ansible Consolidation** — Completed 2026-04-01. All 15 OPNsense crons now have `#Ansible:` prefixes. DNS failover cron brought under Ansible management (runs directly, not via wrapper — state machine with own alerting). 9 legacy hyphenated scripts + old `monitoring-wrapper.sh` removed from host. Dead `opnsense_monitoring.yml` playbook deleted, `freebsd.yml` cleaned up. Monitoring gap evaluation: `check-interface.sh` not needed (OPNsense is a VM, interface health covered by gateway/WG checks), `check-ddns-age.sh` not needed (IP match check sufficient). Remaining: wrapper refactor for `monitor_dns_failover.sh` (tracked as separate TODO).
- **TADO/HA Presence Notification Elegance** — Completed 2026-04-02. Removed unconditional Slack alert from `away_mode_everyone_left` automation. Moved success notification into `tado_presence.sh` so it only fires when AWAY is actually applied. Now exactly one notification per event: AWAY applied, AWAY skipped (device at home), or error. Note: `input_select.tado_mode` is still set to "Away" unconditionally by the automation — minor inaccuracy when AWAY is skipped, cosmetic only.
- **Proxmox WebUI User Migration** — Completed 2026-04-02. `choco@pam` had no ACL permissions despite existing as a PVE user. Granted `Administrator` role on `/` with propagation. WebUI now accessible via `choco@pam` — stop using `root@pam` for routine access.
- **Tado Presence Health Check** — Completed 2026-03-31. Fixed broken heredoc syntax, updated stale device tracker entity IDs (`nexuschoky`, `iphone_de_candela_2`), rewrote as POSIX sh running on host (not Docker). Deployed to `/home/choco/.scripts/check_tado_health.sh` via Ansible, cron every 30min with `enhanced_monitoring_wrapper`. Alerts on `unavailable` tracker or `unknown`/`unavailable` person entity — complements the existing HA automations that monitor Tado climate device availability.
- **Tado SQLite migration** — Completed (commit `a7f6221`). Uses HA REST API.
- **vinylstreamer liquidsoap inactive** — Expected. Runs only during active streaming sessions.