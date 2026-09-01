# Backup & Recovery Guide

Complete reference for what is backed up, where backups live, and how to recover each host from scratch.

> 🔥 **In an incident, start here:** [Failure scenarios — walked, not
> assumed](#failure-scenarios--walked-not-assumed) names your situation and says
> whether the procedure below has been tested or only reasoned through.
> Lost the laptop? → [Recovering without the
> laptop](#recovering-without-the-laptop). Need to open a backup? → [How to Decrypt a
> Backup](#how-to-decrypt-a-backup).

## Contents

- [Backup Inventory](#backup-inventory)
- [Failure scenarios — walked, not assumed](#failure-scenarios--walked-not-assumed)
- [Prerequisites for Any Recovery](#prerequisites-for-any-recovery)
- [Recovering without the laptop](#recovering-without-the-laptop)
- [How to Decrypt a Backup](#how-to-decrypt-a-backup)
- [Per-Host Recovery Procedures](#per-host-recovery-procedures)
- [USB Recovery Drive](#usb-recovery-drive)
- [Quarterly Restore Testing](#quarterly-restore-testing)
- [Known Gaps and Accepted Risks](#known-gaps-and-accepted-risks)
- [Backup Schedule Overview](#backup-schedule-overview)

---

## Backup Inventory

| Host | What | Frequency | Script | **Source in this repo** | Retention |
|------|------|-----------|--------|--------------------------|-----------|
| dockassist | HA native `.tar.gz` | Daily 04:00 | `backup_ha` | `ansible/roles/services/homeassistant/templates/backup_ha.j2` | 7 (weekly cleanup) |
| cobra | Plex config | 04:00, days 1/8/15/22/29 | `backup_plex_config` | `ansible/roles/services/plex/files/backup_plex_config` | Latest per upload |
| unifi-lxc | UniFi `.unf` | Daily 03:00 | `backup_unifi` | `scripts/services/network/backup_unifi.sh` | Latest per upload |
| proxmox | `/etc/pve/` + host configs | 04:00, days 1/8/15/22/29 | `backup_proxmox_config.sh` | `scripts/services/proxmox/` | Latest per upload |
| proxmox | vzdump (VM 100, LXC 101) → USB | Sun 05:00 | `sync_usb_recovery.sh` | `scripts/services/proxmox/` | 2 generations |
| opnsense | `/conf/config.xml` | Daily 04:15 | `backup_opnsense.sh` | `scripts/services/opnsense/` | Latest per upload |
| hifipi · vinylstreamer | — | — | — | Pure IaC, no unique state | — |
| **zyxel switch** | VLAN/PVID map | **Manual** | Web UI export | `docs/reference/zyxel-xgs1250-12.cfg` | In git |

Every one of these ends in `do_backup` (`scripts/common/do_backup`), which age-encrypts
and uploads to curlbin. Success and failure both notify Slack.

> ⚠️ **Backup scripts live in three different places, and that has already misled a
> search.** `scripts/common/`, `scripts/services/<area>/`, **and**
> `ansible/roles/services/<role>/{files,templates}/`. A `find scripts/ -name
> backup_plex_config` returns nothing and looks like the script does not exist — it is
> in the Plex role. The *Source in this repo* column above exists because that mistake
> was actually made while auditing this document.
>
> 📌 **`backup_last_mod` is not part of this.** It is a generic helper deployed only to
> OPNsense; an earlier version of this table wrongly named it as dockassist's backup
> script.

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

## Failure scenarios — walked, not assumed

Each row below was walked against this document and the repo on 2026-09-01, checking
that every command, path and file it depends on actually exists. **"Verified" means
tested on the live estate; "walked" means the procedure and its dependencies were
checked but the restore itself was not performed.** Nothing here is marked from
memory.

| # | Scenario | Status | What it depends on holding |
|--:|---|---|---|
| 1 | **Laptop lost or stolen** | ✅ **Verified** | `AuthorizedKeysCommand` live on all 6 Linux hosts (`sshd -T`). Credentials in two managers, both memorised. See *Recovering without the laptop* |
| 2 | **A Pi's SD card dies** | ⚠️ **Walked — one gap now closed** | Was hand-waved at *"ensure SSH is accessible"*. `rpi-provisioner` does exactly that and is now referenced. `site.yml` imports `bootstrap.yml`, so one command covers a bare host |
| 3 | **HA data loss / bad upgrade** | ✅ Walked | Daily `.tar.gz` on curlbin; restore through HA's own UI. Tado needs re-auth (documented) |
| 4 | **OPNsense config corrupted, VM alive** | ✅ Walked | Daily `config.xml` on curlbin, restored via web UI. Needs only the OPNsense password |
| 5 | **OPNsense VM lost** | ✅ Walked | `qmrestore` from the USB drive on cwwk. Faster than a rebuild and does not need the network |
| 6 | **cwwk NVMe dies** | 🔴 **Walked — circular dependency** | See the warning below. The procedure is right; its *precondition* is not stated |
| 7 | **Zyxel switch dies** | ✅ Walked | Manual re-entry from `docs/reference/`, ~15 min. No import path for a redacted config — that is accepted |
| 8 | **Apple account lost** | ✅ Walked | Two YubiKeys locally, one abroad; Bitwarden holds the age key and vault password and unlocks from memory |
| 9 | **GitHub account lost** | ✅ Walked | Multi-factor incl. hardware tokens. OPNsense and Proxmox stay reachable by password independently |
| 10 | **House fire or burglary** | 🔴 **Walked — untested link** | USB and NVMe are co-located and both lost. curlbin/R2 is the only path, and *finding* the objects is the unproven step — see below |

### 🔴 Scenario 6 — the precondition nobody writes down

Rebuilding `cwwk` needs a Proxmox ISO, and **`cwwk` is the internet SPOF**: OPNsense
runs as VM 100 on it, so while it is down there is no routing and no WAN. You cannot
download the installer from the network you are trying to restore.

**Keep a Proxmox ISO on the USB recovery drive, or plan to tether a phone.** The wired
VLAN 40 path documented in `NETWORK.md` gets a laptop to the *switch* and to `cwwk`'s
own port, but it does not conjure an internet connection.

### 🔴 Scenario 10 — decryption is solved, discovery is not

The age key now has two homes, so an encrypted backup can always be opened. **What has
never been tested is finding it.** curlbin URLs are random and, by design, not
enumerable; the Slack message announcing each upload *is* the index. If Slack history
is unavailable, the documented fallback is to enumerate the R2 bucket through the
Cloudflare account — **and nobody has ever done that.**

📌 **This is the single most valuable thing to rehearse**, because it is the one link
in the chain where "should work" has never become "does work". It is the laptop-loss
row in [Quarterly Restore Testing](#quarterly-restore-testing).

---

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
   reconcile `authorized_keys` (`exclusive: true` from `{{ gh_keys }}`). **OPNsense is
   the exception** — paste the key into its UI instead; see below.
6. **Re-issue the laptop's `read_agent` key** — see *Porting `read_agent`* below.
   It is not backed up anywhere, by design.

### Porting `read_agent` to a new machine

`read_agent` is the passphrase-free account used for unattended SSH (`ssh cobra-agent`).
**There are two independent keys**, and only one of them is on the laptop:

| Key | Private key lives | Public key declared in | Pinned to | Slack alert per use |
|---|---|---|---|---|
| **Laptop** | `~/.ssh/read_agent_ed25519` — **not backed up** | `vault_agent_ssh_pubkey` (vault) | `vault_agent_control_ip` | yes |
| **agent-lxc** | on CT 103 itself | `agent_lxc_ssh_pubkey` (`group_vars/all/main.yml`, plaintext) | `agent_lxc_ip` | no — it sweeps hourly |

✅ **Losing the laptop does not touch the fleet sweep.** The agent-lxc key lives on the
container, so Tier 1/2 monitoring keeps running throughout. Only *your* unattended SSH
from the laptop stops.

🔑 **The private key is deliberately not backed up.** It is passphrase-free, so a copy
in any sync or backup would be a standing fleet credential sitting outside the vault.
Re-issuing costs one command, which is a better trade than storing it.

**To re-issue, after step 3 above has given you normal SSH as your own user:**

```bash
# 1. New keypair. -N "" is deliberate — unattended access is the whole point.
ssh-keygen -t ed25519 -C "read_agent@infrastructure" -f ~/.ssh/read_agent_ed25519 -N ""

# 2. Put the PUBLIC key in the vault. This is the step that actually matters —
#    regenerating the file locally on its own changes nothing on the hosts.
ansible-vault edit ansible/inventory/group_vars/all/vault.yml   # set vault_agent_ssh_pubkey

# 3. Push it. exclusive/templated authorized_keys means the old key is removed.
ansible-playbook ansible/playbooks/system/agent_access.yml

# 4. Verify as the agent, not as yourself:
ssh cobra-agent 'echo ok'
```

⚠️ **OPNsense needs its own run and will need it again.** `read_agent` there is
`pw`-managed and out-of-band by design — a firmware upgrade deletes it, silently
(settled in [ARCHITECTURE_DECISIONS.md](ARCHITECTURE_DECISIONS.md#agent-access), which
also explains why moving it into `config.xml` does not work). Recovery is one
idempotent command, ~9 s from a fully wiped state:

```bash
ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense
```

📌 **Also re-add the new laptop's own key to `~/.ssh/config`** — the `Host *-agent`
block (`User read_agent`, `IdentityAgent none`, `ProxyCommand` stripping the suffix)
is machine-local dotfiles, not part of this repo.

### Verified state, and the one exception

✅ **Confirmed 2026-09-01** via `sudo sshd -T | grep -i authorizedkeyscommand` on each:
`cobra`, `hifipi`, `dockassist`, `vinylstreamer`, `cwwk`, `unifi-lxc` — **all six wired**.
`agent-lxc` has the script present and fetching.

⚠️ **OPNsense is the exception, and the distinction matters.** `ssh_hardening.yml`
runs on `hosts: all`, and `/usr/local/bin/update_keys` **is** deployed there — that
task has no OS gate. But `Deploy hardened sshd config` **is** gated
`when: os_family == "debian"`, so `sshd` is never wired to call it, and OPNsense
regenerates `sshd_config` from `config.xml` regardless.

What OPNsense gets instead is `Set authorized keys … from github` with
`exclusive: true` — a **snapshot written at Ansible-run time**, not a live lookup. So a
key enrolled at GitHub *after* the last run is not accepted there.

**On a new laptop:** every Debian host lets you in immediately; OPNsense needs the web
UI at `https://opnsense/` or `qm terminal 100` from the Proxmox console (both
passworded, both in the managers). One Ansible run then re-syncs its `authorized_keys`.
Not a lockout — one host with a different door.

🔑 **And pushing a new key there with Ansible is the wrong move.** OPNsense rebuilds
state from `config.xml` on every config apply and upgrade — that is
[settled](ARCHITECTURE_DECISIONS.md#agent-access), verified against `auth.inc` and
live-tested, and it is why `read_agent` is deliberately `pw`-managed and out-of-band.
Writing `~/.ssh/authorized_keys` from Ansible is writing to a file the platform
considers its own.

**So the rule for this one host: paste the new key into the OPNsense UI**
(System → Access → Users), where `config.xml` will keep it. Every other host takes it
from GitHub with no action at all.

✅ **Confirmed 2026-09-01** — the infrastructure user's key is held in the UI field, so
`config.xml` preserves it across applies and upgrades. (Note for anyone re-checking:
*being able to SSH in does not by itself prove this* — a key sitting only in
`~/.ssh/authorized_keys` authenticates identically, right up until the next config
apply removes it. The discriminator is the UI field, or `grep authorizedkeys` in
`config.xml`.)

📌 **So the account that matters most is GitHub, not the laptop.**
`authorized_key` is deployed with `exclusive: true` from `{{ gh_keys }}` *and*
`AuthorizedKeysCommand` reads GitHub live — both paths terminate at the same account.

✅ **Confirmed well covered (2026-09-01).** That account carries several independent
authentication and recovery factors, **at least one of which is a physical token that
depends on neither the laptop nor the Apple account**. Laptop loss does not threaten
it. The factor inventory is in `docs/local/RECOVERY.md` — kept out of this file because
listing which factors guard an account is a targeting aid, not a mechanism.

✅ **Account access is a solved problem (confirmed 2026-09-01).** Two hardware tokens
are registered on *both* the Apple account and GitHub, so the two recovery roots can
rescue each other: lose the Apple account and the tokens still open GitHub; lose both
tokens and the Apple-held factors still open GitHub. Losing one token costs nothing.

✅ **The age key now has a second home too (2026-09-01).** It previously existed only
in the primary password manager, which made "Apple account and laptop lost together"
an *irreversible* event: every age-encrypted backup in this document would have become
permanently undecryptable. A copy now lives in a separate backup password manager, so
that scenario is recoverable.

✅ **The vault password followed it, and the redundancy is real.** Both secrets now
live in two managers, and **both managers unlock from memory** — so neither depends on
the other, and the "backup that depends on the thing it backs up" failure does not
apply here. Every credential in the restore chain now survives losing the laptop, the
Apple account, or either password manager. Inventory in `docs/local/RECOVERY.md`.

📌 **What has *not* been proven is the chain itself.** Each link is now individually
recoverable; the end-to-end path — locate a backup, decrypt it, restore it, on a
machine that is not this one — has never been walked. That is what the laptop-loss row
in [Quarterly Restore Testing](#quarterly-restore-testing) is for, and it is now the
only thing standing between "should work" and "does work"."

### What else is only on the laptop

| Artifact | Backed up by | Notes |
|---|---|---|
| The repo + `docs/local/` | **iCloud Drive** (`~/Documents` syncs) | Verified 2026-09-01 — `docs/local/` is visible in iCloud Drive. Gitignored ≠ unbacked |
| `~/.claude/plans/` | ❌ nothing | Outside `~/Documents` — but it holds *plans for unstarted work*, not operational state. Losing it costs re-thinking, not recovery |
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

1. Flash the SD card **with `rpi-provisioner`** (sibling repo,
   `~/Documents/Workspaces/rpi-provisioner`) — it downloads the OS, sets Wi-Fi, and
   **installs your GitHub SSH keys**, which is the step that makes the host reachable:
   ```bash
   ./provision_pi <image> dockassist
   ```
   Doing this by hand is the slow path: a stock image has no user and no key, and
   `bootstrap.yml` can only connect if it can reach *some* account (it tries the
   infrastructure user, then `pi`, then `root`).
2. Deploy — `site.yml` imports `bootstrap.yml`, so one command covers a bare host:
   ```bash
   ansible-playbook ansible/playbooks/site.yml --limit dockassist
   ```
   This runs bootstrap + baseline + deploys Docker, Home Assistant container, Matter Server, and Cloudflared tunnel.
3. Access HA at `http://dockassist:8123` — initial onboarding screen
4. **Settings > System > Backups > Upload Backup** — upload the decrypted `.tar.gz`
5. Restore from the uploaded backup
6. HA will restart with all config, automations, history, and integrations
7. Re-authenticate Tado — the script is not deployed by Ansible; run it from the repo:
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

1. Flash the SD card with **`rpi-provisioner`** (installs your GitHub SSH keys —
   see the dockassist procedure above), then deploy:
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

1. Flash the SD card with **`rpi-provisioner`** (installs your GitHub SSH keys —
   see the dockassist procedure above), then deploy:
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
| **GitHub account is the root of fleet SSH access** | Losing it locks you out of every host that trusts `AuthorizedKeysCommand` | ✅ Covered — multiple factors incl. a physical token independent of both the laptop and the Apple account (inventory: `docs/local/RECOVERY.md`). OPNsense and Proxmox stay reachable by password as a further independent path |
| **Backup discovery depends on Slack history** | Backup URLs are random and not enumerable; the Slack message is the index. Decryption is now safe, but *finding* the right object is not | Untested fallback: enumerate the R2 bucket directly via the Cloudflare account. **Confirm this works during the next restore test** |
| **Every recovery root resolves to one person's memory** | Both password managers unlock from memory, and the off-site token holder cannot use it | Correct for secrecy, and a deliberate trade. Revisit only if continuity ever outranks it |
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
