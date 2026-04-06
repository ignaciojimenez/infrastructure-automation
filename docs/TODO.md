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

**Risk:** All SSH keys are in Secretive (Secure Enclave), requiring biometric auth for every use. This blocks any unattended access — AI agents, automation tools, and cron-driven scripts cannot SSH to hosts or query APIs without a human physically present.

### Current State (2026-04-06)
- **Phase 2 SSH deployed and validated** — `read_agent` user on all 7 hosts
- Full design and implementation guide in [`docs/AGENT_ACCESS.md`](AGENT_ACCESS.md)

### Remaining Work
1. Create HA read-only user + long-lived token (manual, one-time in HA UI)
2. Create Proxmox `read_agent@pve` user + PVEAuditor API token (manual, one-time via `pveum`)
3. Store API tokens in vault
4. Validate: file access denial, IP restriction from outside `10.30.0.0/16`

### Acceptance Criteria
- [x] `read_agent` user deployed on all production hosts via Ansible
- [x] Agent can SSH to any host and run read-only diagnostics without biometric auth
- [x] SSH key restricted to LAN via `from=` in authorized_keys
- [x] Sudo commands outside allowlist are denied
- [x] Documentation complete: [`docs/AGENT_ACCESS.md`](AGENT_ACCESS.md)
- [ ] Agent can query HA and Proxmox APIs using read-only tokens
- [ ] Agent cannot read secrets belonging to other users (validated)

---

## Lower Priority

These items have value but are not urgent. Revisit quarterly.

- **Agent API Expansion (Phase 3)** — Add read-only API access for OPNsense (key+secret, monitoring-api group), UniFi (session-based, read-only admin), and optionally Plex (account-scoped token, no role scoping). Depends on Priority 11 Phase 2 completion. Design notes already in `docs/AGENT_ACCESS.md` under "Future: API Expansion". SSH access to all three hosts is covered by Phase 2 — API access adds richer diagnostics on top.

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