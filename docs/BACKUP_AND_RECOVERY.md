# Backup & Recovery Guide

Complete reference for what is backed up, where backups live, and how to recover each host from scratch.

---

## Backup Inventory

| Host | What | Frequency | Time | Script | Retention |
|------|------|-----------|------|--------|-----------|
| dockassist | HA native `.tar.gz` backup | Daily | 04:00 | `backup_last_mod` | 7 backups (weekly cleanup) |
| cobra | Plex config (Preferences, Plug-ins) | Every 7 days | 04:00 | `backup_plex_config` | Latest per upload |
| unifi-lxc | UniFi `.unf` autobackup | Daily | 03:00 | `backup_unifi` | Latest per upload |
| proxmox | `/etc/pve/` + host configs | Every 7 days | 04:00 | `backup_proxmox_config.sh` | Latest per upload |
| proxmox | vzdump snapshots (VM 100, LXC 101) → USB | Weekly (Sunday) | 05:00 | `sync_usb_recovery.sh` | 2 generations on USB |
| opnsense | `/conf/config.xml` | Daily | 04:15 | `backup_opnsense.sh` | Latest per upload |
| hifipi | — | — | — | Pure IaC, no unique state | — |
| vinylstreamer | — | — | — | Pure IaC, no unique state | — |

All backups are age-encrypted (asymmetric, public key on hosts) and uploaded to curlbin. Success/failure notifications go to Slack.

## Prerequisites for Any Recovery

Before recovering any host, you need:

1. **This repository** — cloned locally with Ansible installed
2. **Ansible Vault password** — stored in macOS Keychain (`security find-generic-password -s ansible-vault-master -w`)
3. **age secret key** — one line (`AGE-SECRET-KEY-1...`), stored in password manager
4. **SSH access** — key-based auth via Secretive (Secure Enclave)
5. **Slack webhook tokens** — in vault, needed for post-recovery monitoring

## How to Decrypt a Backup

Backup URLs are posted to Slack on successful upload. **Save these URLs** — they cannot be recovered if lost (IDs are random, not discoverable).

```bash
# Download the encrypted backup from curlbin (no auth required for downloads)
curl -o backup.age "https://curlbin.ignacio.systems/FILE_ID"

# Decrypt (key.txt contains the age secret key from password manager: one line, AGE-SECRET-KEY-1...)
age --decrypt -i key.txt -o backup.tar.gz backup.age

# Extract
tar -xzf backup.tar.gz
```

On a fresh machine, recovery is: `brew install age` (or `apt install age` / `pkg install age`), paste the secret key from password manager into a file, decrypt.

If the curlbin upload failed, `do_backup` saves a local fallback at `/tmp/backup_*.age` on the source host, and logs the URL to `/tmp/backup_url_*.txt` (volatile — retrieve before reboot).

> **Old backups:** Backups created before 2026-03-23 use GPG encryption (`.gpg` extension). Decrypt with: `gpg --import <key-from-password-manager> && gpg --decrypt -o backup.tar.gz backup.gpg`

---

## Per-Host Recovery Procedures

Ordered by rebuild complexity (highest risk first).

### OPNsense (opnsense)

**Risk:** Highest. Loss means full manual rebuild of 13 WireGuard tunnels, all firewall rules, Unbound DNS, CrowdSec, and DDNS.

**What's in the backup:** `/conf/config.xml` — the entire OPNsense configuration (interfaces, firewall rules, WireGuard, DNS, DHCP, CrowdSec, VPN gateway groups).

**Recovery steps:**

1. Install OPNsense on the VM (or restore VM from Proxmox backup)
2. Access the WebUI at `https://<ip>`
3. **System > Configuration > Backups** — restore `config.xml` from the decrypted backup
4. Reboot — all interfaces, firewall rules, WireGuard tunnels, and DNS config will be restored
5. Verify WireGuard tunnels come up: `wg show` via SSH
6. Verify DNS resolution: `dig @localhost example.com`
7. Run Ansible to deploy monitoring and backup scripts:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit opnsense
   ```
8. Verify crons: `crontab -l` on opnsense — all entries should have `#Ansible:` prefix

**Post-recovery checks:**
- CrowdSec enrollment may need re-registration if the machine ID changed
- DDNS will update automatically on next cron run
- Mullvad WireGuard keys are in config.xml — they survive restore

### Proxmox (proxmox / cwwk)

**Risk:** High. Loss means rebuilding VM/LXC definitions, storage layout, and network config.

**What's in the backup:** `/etc/pve/` (VM/LXC configs, storage definitions, user/role setup, network), plus `/etc/network/interfaces`, `/etc/fstab`, ZFS pool info (status text, not actual data), and crontabs. ZFS data itself is on disk — not in the backup.

**Recovery steps:**

1. Install Proxmox VE on the CWWK hardware
2. Restore network config from backup (`host/interfaces` → `/etc/network/interfaces`), then reboot
3. Import ZFS pools: `zpool import <poolname>` (data is on disk, survived reinstall)
4. Restore `/etc/pve/` contents from backup — consult the [official Proxmox restore docs](https://pve.proxmox.com/wiki/Proxmox_Cluster_File_System_(pmxcfs)) for the correct procedure; naive `cp` into `/etc/pve/` while the cluster filesystem is mounted may not work as expected
5. Verify VMs and LXCs appear in WebUI
6. Start VMs/LXCs — each guest has its own recovery procedure below
7. Run Ansible to restore monitoring and backup automation:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit proxmox
   ```

**Post-recovery checks:**
- Verify ZFS pool health: `zpool status`
- Check all VMs/LXCs started: `qm list` and `pct list`
- OPNsense VM must start before other guests (it provides networking)

### Home Assistant (dockassist)

**What's in the backup:** HA native backup (`.tar.gz`) — includes all YAML config, automations, integrations database, and custom components.

**Recovery steps:**

1. Flash Raspberry Pi OS to SD card, ensure SSH is accessible, then deploy:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit dockassist
   ```
   This runs bootstrap + baseline + deploys Docker, Home Assistant container, Matter Server, and Cloudflared tunnel.
2. Access HA at `http://dockassist:8123` — initial onboarding screen
3. **Settings > System > Backups > Upload Backup** — upload the decrypted `.tar.gz`
4. Restore from the uploaded backup
5. HA will restart with all config, automations, history, and integrations
6. Re-authenticate Tado — the script is not deployed by Ansible; run it from the repo:
   ```bash
   ssh dockassist
   bash /path/to/repo/scripts/services/homeassistant/tado_setup.sh
   ```
   This runs the OAuth2 flow and creates `/home/choco/homeassistant/.tado_tokens`
7. Verify Cloudflared tunnel is active: `docker logs cloudflared`

**Post-recovery checks:**
- HomeKit Controller devices may need re-pairing (Apple Home → Settings → Hubs)
- Check `group.persons` shows correct tracking
- Verify Slack notifications fire on next presence change

### UniFi (unifi-lxc)

**What's in the backup:** UniFi `.unf` backup file — contains network site config, device adoption records, client data, and network settings.

**Recovery steps:**

1. Create a new LXC on Proxmox (or restore from Proxmox backup)
2. Ensure SSH is accessible, then deploy:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit unifi-lxc
   ```
3. Access UniFi at `https://unifi:8443`
4. During setup wizard, choose **Restore from Backup** and upload the decrypted `.unf` file
5. Devices should auto-adopt if the controller IP hasn't changed

**Post-recovery checks:**
- Verify all APs and switches show as "Connected" in UniFi UI
- If controller IP changed, devices need manual re-adoption (set-inform via SSH to each device)

### Plex (cobra)

**What's in the backup:** Selected Plex config files — `Preferences.xml`, `Plug-in Support/Preferences`, and `Plug-ins`. Watch history and library metadata are **not** included. Media files are **not** backed up.

**Recovery steps:**

1. Flash Raspberry Pi OS to SD card, ensure SSH is accessible, then deploy:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit cobra
   ```
2. Stop Plex: `sudo systemctl stop plexmediaserver`
3. Extract the decrypted backup to the Plex library root:
   ```bash
   sudo tar -xzf plex_config_backup.tar.gz -C "/var/lib/plexmediaserver/Library/"
   ```
4. Fix ownership: `sudo chown -R plex:plex /var/lib/plexmediaserver/`
5. Start Plex: `sudo systemctl start plexmediaserver`
6. Reconnect USB media drives — check `/etc/fstab` entries (managed by Ansible)

**Post-recovery checks:**
- Verify libraries appear in Plex WebUI — metadata will need to be re-fetched
- Plex claim token may need re-linking at plex.tv/claim
- Samba shares (managed by Ansible) should be operational after deploy

### hifipi / vinylstreamer

**No backup needed.** These hosts are pure IaC — all configuration is in Ansible.

**Recovery steps:**

1. Flash Raspberry Pi OS to SD card, ensure SSH is accessible, then deploy:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit hifipi  # or vinylstreamer
   ```
2. Done. MPD/Shairport/Raspotify (hifipi) or Icecast/Liquidsoap (vinylstreamer) will be running.

---

## USB Recovery Drive

A 128GB ext4 USB drive mounted at `/mnt/usb-recovery` on the Proxmox host provides fast-path recovery for the "NVMe died" scenario. This supplements (does not replace) the curlbin offsite backups.

**Contents:**
- `current/` — Latest vzdump snapshots for each active guest + `/etc/pve/` backup
- `previous/` — Previous week's copy (fallback if current is corrupt)
- `RECOVERY.txt` — Standalone recovery checklist with actual commands
- `MANIFEST.txt` — File sizes and MD5 checksums for integrity verification

**Schedule:** Weekly (Sunday 05:00), after vzdump (03:00) and Proxmox config backup (04:00) complete.

**Monitoring:** Slack alerts via `enhanced_monitoring_wrapper` on every sync. Backup freshness heartbeat via healthchecks.io (172h max age, checked every 2 hours).

**How it works:** The `sync_usb_recovery.sh` script calls a root-owned `usb_recovery_helper` that mounts the USB, rotates `current/` → `previous/`, rsyncs the latest vzdump per guest, copies `/etc/pve/`, writes a manifest with checksums, and unmounts. If the USB is disconnected, the mount fails and the monitoring wrapper fires a Slack alert.

**Restoring from USB:** See `RECOVERY.txt` on the drive itself, or the Proxmox recovery procedure above. Key commands:
```bash
# Mount USB
mount /dev/sdX1 /mnt/usb

# Restore VM (OPNsense)
qmrestore /mnt/usb/current/100/vzdump-qemu-100-*.vma.zst 100

# Restore LXC (UniFi) — note: must use local-zfs, not local
pct restore 101 /mnt/usb/current/101/vzdump-lxc-101-*.tar.zst --storage local-zfs
```

**Limitation:** USB is physically co-located with the NVMe. A catastrophic event (fire, theft) loses both. The curlbin offsite backups remain the true disaster recovery path.

---

## Quarterly Restore Testing

Every quarter, pick one backup and test the full restore chain: download/locate → decrypt (if curlbin) → restore → verify.

| Quarter | Host | What to Test |
|---------|------|-------------|
| Q2 2026 | unifi-lxc | USB vzdump → temporary LXC (pct restore 999) |
| Q3 2026 | dockassist | curlbin HA backup → decrypt → inspect contents |
| Q4 2026 | opnsense | USB vzdump → temporary VM (qmrestore 999) |
| Q1 2027 | cobra | curlbin Plex backup → decrypt → inspect contents |

Results are logged in `docs/RESTORE_TEST_LOG.md`.

---

## Known Gaps and Accepted Risks

| Gap | Impact | Mitigation |
|-----|--------|------------|
| **cobra media files** not backed up | Loss of media library (100s of GB) | Too large for curlbin (200 MB limit). Re-downloadable content. |
| **age secret key in password manager only** | Cannot decrypt backups without password manager access | Single line key — easy to store in multiple locations if needed |
| **Backup URLs only in Slack** | If Slack notification is missed, URL is gone — IDs are random and not discoverable | `do_backup` also logs URLs to `/tmp/backup_url_*.txt` on the source host, but this is volatile |
| **Tado OAuth tokens** | Need re-auth on dockassist rebuild | Recoverable via `tado_setup.sh` (interactive OAuth2 flow) |
| **curlbin single point of failure** | If curlbin is down, uploads fail | `do_backup` saves local fallback to `/tmp/backup_*.age`; 3 retries with 5s delay |
| **Plex library metadata** not backed up | Watch history and library scan data lost on rebuild | Re-scan from media files; metadata re-fetched from Plex servers |
| **USB + NVMe co-located** | Catastrophic event (fire, theft) loses both USB and NVMe | curlbin offsite backups remain the true DR path; USB is fast-path for drive failure only |
| **vzdump schedule not Ansible-managed** | Must reconfigure manually after Proxmox rebuild | Documented in USB recovery checklist (`RECOVERY.txt`) and this guide |

---

## Backup Schedule Overview

```
03:00  proxmox      vzdump VM/LXC snapshots (daily, Proxmox-managed)
03:00  unifi-lxc    UniFi backup (daily)
04:00  dockassist   Home Assistant backup (daily)
04:00  cobra        Plex config backup (every 7 days)
04:00  proxmox      Proxmox config backup (every 7 days)
04:15  opnsense     OPNsense config backup (daily)
05:00  proxmox      USB recovery sync (Sunday)
```

Curlbin uploads are staggered to avoid concurrency. USB sync runs after all backups complete.
