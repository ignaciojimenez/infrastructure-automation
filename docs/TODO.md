# Prioritized Next Steps
*Updated: March 2026*

Tasks ordered by impact and urgency. Check git log for recently completed work.

---

## Priority 1 — Critical Gaps

### 1. Automate OPNsense Config Backup
**Status:** No backup exists for OPNsense configuration
**Risk:** Firewall config loss = full manual rebuild (WireGuard tunnels, DNS rules, CrowdSec, firewall rules)
**Approach:**
- Use OPNsense REST API (`/api/core/backup/download`) to export config XML
- Encrypt with GPG (short-term) or age (long-term) and push to curlbin
- Deploy via Ansible `roles/services/` for opnsense; schedule as daily cron
- Reference: `scripts/services/homeassistant/backup_ha.sh` as a pattern to follow

### 2. Automate Proxmox VM/LXC Backup to Offsite
**Status:** Local vzdump only; no offsite copy
**Risk:** Single point of failure — Proxmox host loss = loss of OPNsense VM + UniFi LXC
**Approach:**
- Extend `check_proxmox_health.sh` or add a dedicated backup script
- Use `vzdump` to export VM 100 (OPNsense) and LXC 101 (UniFi) snapshots
- Push encrypted archives to curlbin or another offsite destination
- Consider weekly schedule (VMs don't change often)

---

## Priority 2 — Security & Access

### 3. Replace GPG with Age for Portable Encryption
**Status:** Backup encryption relies on a GPG key that lives only on the laptop
**Risk:** Laptop loss/failure = cannot decrypt backups or run backup scripts elsewhere
**Approach:**
- Generate an [age](https://github.com/FiloSottile/age) key pair
- Store public key in repo (safe to commit); private key in secure offsite location (password manager)
- Update `do_backup` and service backup scripts to use `age -r <pubkey>` instead of GPG
- Update `import_gpg_github.sh` or replace with age key distribution pattern

### 4. Create `choco` User on Proxmox (Stop Using Root)
**Status:** Proxmox is managed as `root`; all other hosts use `choco`
**Risk:** Root SSH access is a security anti-pattern; no audit trail
**Approach:**
- Update `ansible/playbooks/system/bootstrap.yml` to handle Proxmox user creation
- Set `ansible_user: root` only for the initial bootstrap run on proxmox
- After bootstrap, switch to `choco` with sudo (matching other hosts)
- Verify `proxmox_hosts` group vars don't hardcode root

---

## Priority 3 — Operational Reliability

### 5. Fix VPN Country Switcher UUID Alignment
**Status:** `switch_vpn_country.sh` has hardcoded firewall rule UUIDs — needs verification
**Risk:** Script silently does nothing if UUIDs don't match current OPNsense config.xml
**Approach:**
- SSH to opnsense and run: `grep -o 'uuid="[^"]*"' /conf/config.xml | head -20`
- Cross-check against UUIDs in `scripts/services/opnsense/switch_vpn_country.sh` lines 13–16
- Update script UUIDs if mismatched; add a `status` smoke-test to the monitoring wrapper

### 6. Reactivate Plex on Cobra
**Status:** Plex is installed but currently inactive (noted in CURRENT_INFRASTRUCTURE_STATE.md)
**Risk:** Media library inaccessible; storage monitoring runs but nothing to monitor
**Approach:**
- SSH to cobra and check: `systemctl status plexmediaserver` or `docker ps`
- Determine if issue is service crash, disk mount, or intentional disable
- Re-enable via Ansible: `ansible-playbook ansible/playbooks/services.yml --limit cobra`

### 7. Fix devpi DNS / Connectivity
**Status:** `devpi` host unreachable (noted in MONITORING_DEPLOYMENT.md)
**Action:** Determine if host still exists or should be removed from inventory/docs

---

## Priority 4 — Improvements

### 8. Ansible Playbook Smoke Tests in CI
**Status:** No automated testing; changes are validated manually with `--check --diff`
**Approach:**
- Add a GitHub Actions workflow that runs `ansible-playbook --syntax-check` on all playbooks
- Optionally add `ansible-lint` for style enforcement
- Low bar, high value — catches broken YAML and undefined variables before deploy

### 9. Keep CURRENT_INFRASTRUCTURE_STATE.md Up to Date
**Status:** Last updated December 2025; now 3 months stale
**Approach:** After any significant infrastructure change, update the state doc as part of the commit

---

## Completed (Recent)
- ✅ 4-tunnel DNS resilience (4 Mullvad resolvers with Cloudflare fallback)
- ✅ Tado health check migrated from SQLite to HA REST API
- ✅ External drive storage monitoring for media hosts
- ✅ Internet speed monitoring for dockassist
- ✅ Tado cross-check before setting AWAY (prevents false away triggers)
- ✅ Mobile dashboard rebuilt; Tado entities renamed
- ✅ Bootstrap GitHub keys fixed for `--check` mode
- ✅ Curlbin auth credentials added (`.netrc`)
- ✅ DNS migrated from PiHole LXC to OPNsense Unbound (Nov 2025)
