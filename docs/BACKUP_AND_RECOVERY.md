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
| **zyxel switch** | VLAN/PVID map | **Manual** | — | Web UI export → `docs/reference/` | In git |

All backups are age-encrypted (asymmetric, public key on hosts) and uploaded to curlbin. Success/failure notifications go to Slack.

### Zyxel XGS1250-12 — manual, and deliberately so

The backbone switch has **no SSH, no SNMP and no API**, and exactly one `admin`
account with no roles — so there is no way to automate this and no read-only
credential to store. See `docs/NETWORK.md` § *Getting at the switch*.

The current export lives at **`docs/reference/zyxel-xgs1250-12.cfg`**, decoded
and committed in plain text on purpose: it is the VLAN and PVID map, which is
already documented in `NETWORK.md`, and keeping it readable means `git diff`
shows you when a port's VLAN changes. A binary blob would hide exactly that.

**To refresh it** after any switch change:

```bash
# 1. Web UI → Management → Configuration Restore/Backup → Backup
# 2. Decode it (the export is XOR 0xa5 — obfuscation, not encryption):
python3 -c "import sys;d=open(sys.argv[1],'rb').read();\
sys.stdout.write(bytes(b^0xa5 for b in d).decode())" startupconfig.cfg \
  > docs/reference/zyxel-xgs1250-12.cfg
# 3. Redact the credential line before committing:
#    username "admin" secret 8 $8$...   →   ! REDACTED: ...
```

🔑 **Always strip the `username` line.** The raw export embeds the admin password
hash, and this repository is public. The hash is not worth backing up anyway —
restoring onto a factory-reset switch means setting a new password regardless.

**Recovery:** factory-reset the switch, set its IP to `10.30.40.50/24` with
gateway `10.30.40.254`, set management VLAN to 40, then re-enter the VLAN and
per-port config from the committed file. There is no import path for a redacted
config, so this is a manual re-entry — roughly 15 minutes for 12 ports.

## Prerequisites for Any Recovery

Before recovering any host, you need the five things below. **The right question is not
what they are but where they live** — because the interesting failure is not a dead
Raspberry Pi, it is a dead control machine.

| # | Prerequisite | Where it lives | Survives losing the laptop? |
|---|---|---|---|
| 1 | **This repository** | GitHub (`origin`) | ✅ Clone it again |
| 2 | **Ansible Vault password** | Apple Passwords (iCloud-synced). A copy sits in the local `login.keychain-db` purely as Ansible's non-interactive accessor — `security find-generic-password -s ansible-vault-master -w` | ✅ via Apple Passwords |
| 3 | **age secret key** | One line (`AGE-SECRET-KEY-1…`), Apple Passwords | ✅ |
| 4 | **SSH access to hosts** | Secure Enclave key via [`touchid-agent`](https://github.com/ignaciojimenez/touchid-agent) — **hardware-bound and non-exportable, so it does *not* survive** | ✅ **but by a different route — see below** |
| 5 | **Slack webhook tokens** | `vault.yml` (needs #2) | ✅ |

⚠️ **`login.keychain-db` does not sync to iCloud.** It is a local file. Item 2 is safe
because it is *also* in Apple Passwords — do not let the keychain copy be the only one.

---

## Recovering without the laptop

**Losing the Mac is not a lockout.** This is worth stating plainly because the obvious
reading of prerequisite 4 says otherwise: the Secure Enclave key cannot be backed up,
copied, or migrated — not by Time Machine, not by Migration Assistant, not by anything.
That is `touchid-agent` working correctly, and it would be a genuine problem if SSH
depended on that key alone. **It does not.**

### Why it works: sshd asks GitHub, every time

`ansible/playbooks/tasks/ssh_hardening.yml` deploys a two-line script to every Debian
host and wires it into `sshd`:

```sh
#!/bin/sh
curl -sf "https://github.com/<profile>.keys"      # /usr/local/bin/update_keys, root, 0755
```

```
AuthorizedKeysCommand       /usr/local/bin/update_keys
AuthorizedKeysCommandUser   nobody
```

This is a **live lookup at authentication time**, not a snapshot written at bootstrap.
Add a public key to your GitHub profile and every host accepts it on the next
connection — no Ansible run, no physical access, no SD-card surgery.

> 📌 The template is `templates/debian/sshd_config.j2` at the **repository root**, not
> under `ansible/`. Searching only `ansible/` misses this mechanism entirely and leads
> to the wrong conclusion that laptop loss means a lockout.

### The procedure

1. **Get into GitHub** — password and 2FA are in Apple Passwords.
2. **New key, enrolled at GitHub:**
   ```bash
   ssh-keygen -t ed25519 -C "choco@<new-machine>"
   # paste ~/.ssh/id_ed25519.pub into github.com/settings/keys
   ```
3. **Clone and go:**
   ```bash
   git clone git@github.com:ignaciojimenez/infrastructure-automation.git
   ssh cobra    # works immediately — sshd fetched the new key from GitHub
   ```
4. **Restore the vault password and age key** from Apple Passwords; re-create the
   Keychain accessor so Ansible runs non-interactively:
   ```bash
   security add-generic-password -s ansible-vault-master -a "$USER" -w
   ```
5. **Re-establish `touchid-agent`** for day-to-day use, and let the next Ansible run
   reconcile `authorized_keys` (`exclusive: true` from `{{ gh_keys }}`).
6. **Regenerate the agent key** — `~/.ssh/read_agent_ed25519` lives outside
   `~/Documents`, so it is not in iCloud. It is disposable: re-create it and re-run
   `ansible-playbook ansible/playbooks/system/agent_access.yml`.

### Verified state, and the one exception

✅ **Confirmed 2026-09-01** via `sudo sshd -T | grep -i authorizedkeyscommand` on each:
`cobra`, `hifipi`, `dockassist`, `vinylstreamer`, `cwwk`, `unifi-lxc` — **all six wired**.
`agent-lxc` has the script present and fetching.

⚠️ **OPNsense is the exception.** The hardened-sshd task is gated
`when: os_family == "debian"`, and OPNsense regenerates `sshd_config` from `config.xml`
regardless — so it almost certainly has no `AuthorizedKeysCommand`. *This is reasoned
from the playbook, not verified on the host* (`read_agent`'s shell there is disabled).
Two other ways in, both password-based, both in Apple Passwords: the web UI at
`https://opnsense/`, or `qm terminal 100` from the Proxmox console.

🔴 **So the real single point of failure is the GitHub account, not the laptop.**
`authorized_key` is deployed with `exclusive: true` from `{{ gh_keys }}` *and*
`AuthorizedKeysCommand` reads GitHub live — both paths terminate at the same account.
**The credential that must survive is the GitHub 2FA recovery codes.** Keep them in
Apple Passwords alongside everything else. Losing the phone and the laptop together is
the scenario that makes them matter.

### What else is only on the laptop

| Artifact | Backed up by | Notes |
|---|---|---|
| The repo + `docs/local/` | **iCloud Drive** (`~/Documents` syncs) | Verified 2026-09-01 — `docs/local/` is visible in iCloud Drive. Gitignored ≠ unbacked |
| `~/.claude/plans/` | ❌ nothing | Outside `~/Documents`. `phase-c-operator-plan.md` is the source for TODO item 11 |
| `~/.ssh/read_agent_ed25519` | ❌ nothing | Deliberate — disposable, regenerate per step 6 above |
| Backup URLs | Slack history | Random IDs, not discoverable — the Slack message *is* the index |

📌 **If the Apple account is lost as well as the laptop**, iCloud goes with it and
`docs/local/` is gone. Everything in it is re-derivable by re-probing the network (that
is how it was written), so this is a time cost, not a data loss. Nothing operationally
critical may live only there — that is the rule, not an aspiration.

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
| **Any quarter** | **control machine** | **Laptop-loss drill** — from a fresh macOS user account: enrol a new SSH key at GitHub, confirm `ssh cobra` works without the Secure-Enclave key, and restore the vault password from Apple Passwords. The one restore path never yet exercised |

Results are logged in `docs/RESTORE_TEST_LOG.md`.

---

## Known Gaps and Accepted Risks

| Gap | Impact | Mitigation |
|-----|--------|------------|
| **cobra media files** not backed up | Loss of media library (100s of GB) | Too large for curlbin (200 MB limit). Re-downloadable content. |
| **age secret key in password manager only** | Cannot decrypt backups without password manager access | Apple Passwords, iCloud-synced — survives the laptop. Single line, easy to duplicate |
| **GitHub account is the root of fleet SSH access** | Losing it locks you out of every host that trusts `AuthorizedKeysCommand` | Password + 2FA in Apple Passwords; **keep the 2FA recovery codes there too**. OPNsense and Proxmox stay reachable by password as an independent path |
| **`~/.claude/plans/` is on the laptop only** | TODO item 11's source plan is lost with the machine | Outside `~/Documents`, so iCloud does not cover it. Move it into the repo or `docs/local/` if it matters |
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
