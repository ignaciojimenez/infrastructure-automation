# Infrastructure TODO — Prioritized Action List

Updated: 2026-04-07 | Validated against live hosts

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

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

## Priority 6 — Autonomous Agent LXC

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

**Note on Priority 8 overlap:** The LXC creation step (using `community.general.proxmox`) is also the core pattern needed for the Ephemeral Testing Environment (Priority 8). Implementing Priority 6 first proves out the Ansible provisioning pattern with a real production container. Priority 8 can then extend it to dynamic ephemeral containers without building the provisioning layer from scratch.

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

## Priority 8 — Ephemeral Ansible Testing Environment

**Risk:** Ansible playbooks are only validated via `--check --diff` against live hosts. A full reprovision from scratch is untested — broken dependency ordering, missing template variables, or service startup failures would only surface during a real rebuild, which is exactly the worst time to discover them.

### Verified State (2026-03-17)
- No testing infrastructure exists
- GitHub Actions CI runs `ansible-lint` (syntax/lint only, no execution)
- Proxmox is available as a hypervisor and can create LXC containers and VMs via API
- Current host types to simulate:
  - **Debian-based RPi hosts** (dockassist, cobra, hifipi, vinylstreamer) — LXC containers are a close match (same OS, ARM differences are minor for config management)
  - **Debian Proxmox** — LXC container with Proxmox packages is partial but useful
  - **FreeBSD OPNsense** — requires a FreeBSD VM; hardest to simulate accurately (OPNsense-specific tooling like `configctl`, Unbound, WireGuard)
  - **LXC containers** (unifi-lxc) — nested LXC or a regular container works
- Ansible inventory already uses variable-driven configuration (`enable_*` toggles, `primary_function`) which makes test inventory creation straightforward

**Note on Priority 6 overlap:** Both this and the Agent LXC (Priority 6) need `community.general.proxmox` for Ansible-driven container creation. Implement Priority 6 first — it establishes the provisioning pattern with a real production container. This testing environment then builds dynamic/ephemeral provisioning on top of the same pattern.

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
3. Consider whether config backup/restore makes this less critical

### What This Enables
- Confident reprovisioning of any host from scratch
- Safe testing of major refactors (e.g., Priority 5's DNS failover refactor)
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

## Lower Priority

These items have value but are not urgent. Revisit quarterly.

- **Agent API Expansion (Phase 3)** — Add read-only API access for OPNsense (key+secret, monitoring-api group), UniFi (session-based, read-only admin), and optionally Plex (account-scoped token, no role scoping). SSH access to all three hosts is covered — API access adds richer diagnostics on top.
- **Slack Notification Strategy Review** — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies. A focused audit of ~20 notification sources to reassign channels would improve signal-to-noise. Low effort, low urgency.
- **Mullvad DoT Fallback** — Encrypting DNS during full VPN outage. Low urgency with 4-tunnel architecture.
- **Certificate Expiration Monitoring** — Monitor Proxmox + OPNsense web certs. Alert at 30/7 days. Low effort, medium value.
- **SMART Disk Health Monitoring** — Predict disk failures on Proxmox (ZFS) and cobra (media storage). Low effort, medium value.
- **Full Infrastructure as Code (Proxmox/OPNsense)** — High complexity for rarely-changing configs. Good config backups are likely sufficient.
- **Cobra Media Config Consolidation** — Merge separate cobra repo into media role. Cosmetic.
- **Tidal and Qobuz Receiver on hifipi** — Low effort if a good open-source receiver emerges.

---

## Resolved Items

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
