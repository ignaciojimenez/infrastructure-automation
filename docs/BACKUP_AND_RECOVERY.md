# Backup & Recovery Guide

Complete reference for what is backed up, where backups live, and how to recover each host from scratch.

---

## Backup Inventory

| Host | What | Frequency | Time | Script | Retention |
|------|------|-----------|------|--------|-----------|
| dockassist | HA native `.tar.gz` backup | Daily | 04:00 | `backup_last_mod` | 7 backups (weekly cleanup) |
| cobra | Plex server config | Every 7 days | 04:00 | `backup_plex_config` | Latest per upload |
| unifi-lxc | UniFi `.unf` autobackup | Daily | 03:00 | `backup_unifi` | Latest per upload |
| proxmox | `/etc/pve/` + host configs | Every 7 days | 04:00 | `backup_proxmox_config.sh` | Latest per upload |
| opnsense | `/conf/config.xml` | Daily | 04:15 | `backup_opnsense.sh` | Latest per upload |
| hifipi | — | — | — | Pure IaC, no unique state | — |
| vinylstreamer | — | — | — | Pure IaC, no unique state | — |

All backups are GPG-encrypted and uploaded to curlbin. Success/failure notifications go to Slack.

## Prerequisites for Any Recovery

Before recovering any host, you need:

1. **This repository** — cloned locally with Ansible installed
2. **Ansible Vault password** — stored in macOS Keychain (`security find-generic-password -s ansible-vault-password -w`)
3. **GPG private key** — on the laptop's GPG keyring (the key matching `git_mail` in vault)
4. **curlbin credentials** — in `~/.netrc` on the machine running recovery (for downloading backups)
5. **SSH access** — key-based auth via Secretive (Secure Enclave)
6. **Slack webhook tokens** — in vault, needed for post-recovery monitoring

## How to Decrypt a Backup

Backup URLs are posted to Slack on successful upload. To retrieve and decrypt:

```bash
# Download the encrypted backup from curlbin
curl --netrc -o backup.tar.gz.gpg "https://curlbin.ignacio.systems/FILE_ID"

# Decrypt
gpg --decrypt -o backup.tar.gz backup.tar.gz.gpg

# Extract
tar -xzf backup.tar.gz
```

If the curlbin upload failed, `do_backup` saves a local fallback at `/tmp/backup_*.gpg` on the source host.

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

**What's in the backup:** `/etc/pve/` (VM/LXC configs, storage definitions, user/role setup, network), plus `/etc/network/interfaces`, `/etc/fstab`, ZFS pool snapshots, and crontabs.

**Recovery steps:**

1. Install Proxmox VE on the CWWK hardware
2. Restore network config from backup (`host/interfaces` → `/etc/network/interfaces`)
3. Import ZFS pools: `zpool import <poolname>` (data is on disk, not in backup)
4. Restore `/etc/pve/` contents from backup:
   ```bash
   # Stop cluster services first
   systemctl stop pve-cluster
   systemctl stop corosync
   cp -a pve/* /etc/pve/
   systemctl start pve-cluster
   ```
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

1. Bootstrap the RPi:
   ```bash
   ansible-playbook ansible/playbooks/system/bootstrap.yml --limit dockassist
   ansible-playbook ansible/playbooks/site.yml --limit dockassist
   ```
   This deploys Docker, Home Assistant container, Matter Server, and Cloudflared tunnel.
2. Access HA at `http://dockassist:8123` — initial onboarding screen
3. **Settings > System > Backups > Upload Backup** — upload the decrypted `.tar.gz`
4. Restore from the uploaded backup
5. HA will restart with all config, automations, history, and integrations
6. Re-authenticate Tado:
   ```bash
   ssh dockassist
   /home/choco/homeassistant/tado_setup.sh
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
2. Bootstrap and deploy:
   ```bash
   ansible-playbook ansible/playbooks/system/bootstrap.yml --limit unifi-lxc
   ansible-playbook ansible/playbooks/site.yml --limit unifi-lxc
   ```
3. Access UniFi at `https://unifi:8443`
4. During setup wizard, choose **Restore from Backup** and upload the decrypted `.unf` file
5. Devices should auto-adopt if the controller IP hasn't changed

**Post-recovery checks:**
- Verify all APs and switches show as "Connected" in UniFi UI
- If controller IP changed, devices need manual re-adoption (set-inform via SSH to each device)

### Plex (cobra)

**What's in the backup:** Plex Media Server configuration (library metadata, watch history, user settings). Media files are NOT backed up (too large).

**Recovery steps:**

1. Bootstrap the RPi:
   ```bash
   ansible-playbook ansible/playbooks/system/bootstrap.yml --limit cobra
   ansible-playbook ansible/playbooks/site.yml --limit cobra
   ```
2. Stop Plex: `sudo systemctl stop plexmediaserver`
3. Extract the decrypted backup to Plex's config directory:
   ```bash
   sudo tar -xzf plex_config_backup.tar.gz -C "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/"
   ```
4. Fix ownership: `sudo chown -R plex:plex /var/lib/plexmediaserver/`
5. Start Plex: `sudo systemctl start plexmediaserver`
6. Reconnect USB media drives — check `/etc/fstab` entries (managed by Ansible)

**Post-recovery checks:**
- Verify libraries appear in Plex WebUI
- Plex claim token may need re-linking at plex.tv/claim
- Samba shares (managed by Ansible) should be operational after deploy

### hifipi / vinylstreamer

**No backup needed.** These hosts are pure IaC — all configuration is in Ansible.

**Recovery steps:**

1. Flash Raspberry Pi OS to SD card
2. Bootstrap and deploy:
   ```bash
   ansible-playbook ansible/playbooks/system/bootstrap.yml --limit hifipi  # or vinylstreamer
   ansible-playbook ansible/playbooks/site.yml --limit hifipi
   ```
3. Done. MPD/Shairport/Raspotify (hifipi) or Icecast/Liquidsoap (vinylstreamer) will be running.

---

## Known Gaps and Accepted Risks

| Gap | Impact | Mitigation |
|-----|--------|------------|
| **cobra media files** not backed up | Loss of media library (100s of GB) | Too large for curlbin (200 MB limit). Re-downloadable content. |
| **GPG key on laptop only** | Cannot decrypt backups if laptop is lost | Priority 5 in TODO: migrate to `age` with key in password manager |
| **Backup URLs only in Slack** | Slack history may not persist forever | curlbin URLs are deterministic if you know the file ID. Slack free tier retains 90 days. |
| **Tado OAuth tokens** | Need re-auth on dockassist rebuild | Recoverable via `tado_setup.sh` (interactive OAuth2 flow) |
| **curlbin single point of failure** | If curlbin is down, uploads fail | `do_backup` saves local fallback to `/tmp/backup_*.gpg`; 3 retries with 5s delay |
| **No backup freshness monitoring** | Silent backup failures go undetected | Priority 3 in TODO: implement `check_backup_freshness.sh` |

---

## Backup Schedule Overview

```
03:00  unifi-lxc    UniFi backup (daily)
04:00  dockassist   Home Assistant backup (daily)
04:00  cobra        Plex config backup (every 7 days)
04:00  proxmox      Proxmox config backup (every 7 days)
04:15  opnsense     OPNsense config backup (daily)
```

Staggered to avoid concurrent curlbin uploads.
