# unifi_os — UniFi OS Server, the network controller (PER-127)

UniFi OS Server in a Debian 13 VM (VM 105, `unifi-os-vm`, 10.30.40.201). It
replaced the standalone Network Application on unifi-lxc (CT 101), whose
release line had ended, at the cutover on 2026-11-15. CT 101 was destroyed on
2026-11-20. The reasoning is in
[ARCHITECTURE_DECISIONS.md](../../../../docs/ARCHITECTURE_DECISIONS.md#unifi-controller--unifi-os-server-in-a-vm-2026-11-11).

The role installs the server once, from Ubiquiti's installer pinned by version
and checksum (`defaults/main.yml`). It then owns what every host here owns:

| What | How |
|---|---|
| Server check, self-healing | `check_unifi_os`, every 13 min: unit, container, console on 11443, inform port 8080 |
| Nightly off-host backup | `backup_unifi` at 03:30, after the Network app's 03:00 autobackup |
| Backup heartbeat | healthchecks.io check "UniFi backup", pinged every 2 h while the last backup succeeded less than 26 h ago |
| Read-only state capture | `/usr/local/bin/unifi-state`, driven by `bin/unifi-state` |
| System health, read_agent, SSH | the fleet baseline, via `site.yml` |

Deploy: `ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm`

**Not in Ansible:** the console's first run, the configuration restore, the
read-only account and the update settings. They are browser steps (below).

**Updates are automatic** (2026-11-20, Ignacio's call). UniFi OS, Network and
the APs' firmware update themselves; the pin above only decides what a new
install starts from. A rebuild turns them off until its after-state is clean,
so the comparison compares one change.

## What the server is

Seen on the PER-178 spike VM and at the cutover, not read from docs:

| Fact | Value |
|---|---|
| Installer | `uos-installer --non-interactive` (also `--web-port`, `--network-mode slirp4nets\|pasta`, `--uninstall`); fetched from Ubiquiti's firmware API and checked against its `sha256_checksum` |
| Runs as | podman container `uosserver` (pasta networking), `uosserver.service`, CLI `uosserver`. The Network app's files are inside the container, autobackups at `/var/lib/unifi/backup/autobackup`: `cd /tmp && sudo -u uosserver podman exec uosserver ls -l /var/lib/unifi/backup/autobackup` |
| Ports | web **11443** (container 443), inform **8080**, plus 3478/udp, 5514/udp, 6789, 8444, 8880-8882, 9543, 10003/udp |
| First run | name → Next → **Proceed Without a UI Account** → console password (12+ characters, one special) + **Terms of Service** → Finish. It ends at "Setup Complete!" and restores nothing |
| Restore | Network → Settings → Control Plane → Backups → **Upload & Restore** takes a `.unf`. The import skips every controller account (`SKIP_ADMINISTRATOR_USERS_AND_BACKUP_UISETTINGS`) |
| Console session | ends at every server restart and VM reboot: log in again |
| Login rate limit | about six logins a minute get **HTTP 429**. Each `unifi-state` run is one login: space captures out |

**A test controller holding a restored backup has the APs' keys.** On the
spike VM, nftables dropped everything it sent to private, link-local and
multicast addresses, except DNS to the gateway, and counted it: of 40
parallel connections to cwwk, none got through. (`limit rate` is a match in
nftables: a drop on the rate-limited rule lets the excess through, so the log
and the drop are separate rules.) A restored controller opens no LAN
connection of its own; it waits for devices to inform.

## Rebuild runbook

For when VM 105 is broken beyond a restart. With Ignacio present; the commands
run from this repo's root.

**Restore the VM before rebuilding the controller.** cwwk keeps VM 105's
nightly vzdumps (03:00 on `local`, 3 daily + 2 weekly). If cwwk is healthy,
the newest one brings back the whole VM, keys and configuration, with no
browser step. Not exercised yet:

```sh
ssh cwwk-agent 'sudo pvesh get /nodes/cwwk/storage/local/content --content backup --vmid 105'
ssh cwwk 'sudo qm stop 105; sudo qmrestore /var/lib/vz/dump/<newest vzdump-qemu-105-…vma.zst> 105 --force 1 && sudo qm start 105'
```

Steps 7 and 8 are then the check. The rest builds a new VM and restores the
newest `.unf` into it. It is how the cutover from unifi-lxc ran on 2026-11-15,
and the times and observations below are from that run: steps 2–8 took 26
minutes of work.

**Wi-Fi during the gap:** the APs kept serving their last configuration
through 21 minutes with no controller: a Wi-Fi host (vinylstreamer) logged no
event at all. Between steps 2 and 7 nothing manages them: no stats, no
changes, no guest portal. **The drop comes at step 7, not during the gap:**
the new controller provisions each AP as it reconnects, which restarts its
radios. Every client re-associated, about 20 s each (vinylstreamer
19:02:03–19:02:24), and the U7 Lite rebooted once. A Mac may rejoin a
different saved SSID afterwards. Restarting `uosserver` later cost no client
anything: only provisioning does.

**A dead-man timer, when there is something to roll back to.** At the cutover
the old controller stayed intact and stopped. A timer on cwwk would have
restarted it after 90 minutes unless cancelled, so a cutover that cut the
laptop's Wi-Fi would have undone itself; it ran over Wi-Fi for that reason.
Arm the same before any move that keeps the old controller:
`ssh cwwk 'sudo systemd-run --on-active=90min --unit=unifi-rollback /bin/sh -c "<stop the new one>; <start the old one>"'`.
Cancel it at step 8 with `sudo systemctl stop unifi-rollback.timer`, and
`systemctl list-timers --all unifi-rollback.timer` must then show 0 timers. A
rebuild in place has nothing to roll back to: the APs serve meanwhile.

### 0. Before-state

```sh
ssh -o ControlPersist=8h -o ServerAliveInterval=60 -MNf cwwk   # Touch ID
D=docs/local/unifi-state   # gitignored; from a worktree, use the main tree's
bin/unifi-state > $D/before-1.txt
sleep 30; bin/unifi-state > $D/before-2.txt
diff $D/before-1.txt $D/before-2.txt && echo stable
```

If the controller no longer answers, the newest capture in `$D` is the
baseline.

### 1. The backup to restore

The newest autobackup, unless the controller changed since. From the old VM,
if it still boots; checksum both ends:

```sh
F=$(ssh unifi "cd /tmp && sudo -u uosserver podman exec uosserver sh -c 'ls -1t /var/lib/unifi/backup/autobackup/*.unf | head -n 1'")
ssh unifi "cd /tmp && sudo -u uosserver podman exec uosserver sha256sum $F"
(umask 077; ssh unifi "cd /tmp && sudo -u uosserver podman exec uosserver cat $F" > $D/restore.unf); shasum -a 256 $D/restore.unf
```

Otherwise, the newest off-host upload. Its download URL is in the VM's
`~/.logs/unifi_backup.log` (`Backup URL:`). The uploads run `--silent`, so no
URL reaches Slack: with the VM and its vzdumps gone, finding one is
[Scenario 10](../../../../docs/BACKUP_AND_RECOVERY.md#-scenario-10--decryption-is-solved-discovery-is-not).
Decrypt as in
[How to Decrypt a Backup](../../../../docs/BACKUP_AND_RECOVERY.md#how-to-decrypt-a-backup);
the archive holds the `.unf` and `autobackup_meta.json`.

### 2. Replace the VM (the gap starts)

```sh
ssh cwwk 'sudo qm stop 105 && sudo qm destroy 105 --purge'
ansible-playbook ansible/playbooks/provision_unifi_os_vm.yml
ssh-keygen -R 10.30.40.201; ssh-keygen -R 10.30.40.201-agent; ssh-keygen -R unifi; ssh-keygen -R unifi-agent
ssh -o StrictHostKeyChecking=accept-new -o ControlPersist=8h -MNf 10.30.40.201   # Touch ID
```

`--purge` also takes VM 105 out of the vzdump job (step 3 puts it back); its
vzdump archives stay. Provisioning refuses to create the VM while anything
answers on .201. A stale `-agent` host key stalls every read-only probe of the
new VM, so clear all four names.

### 3. Build it like every host, and back it up

```sh
ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm
ssh 10.30.40.201 'getent hosts cwwk'          # 10.30.40.51: search domain is internal
ssh cwwk 'sudo pvesh set /cluster/backup/backup-34b8bdac-4d3a --vmid 100,105'
ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit cwwk,unifi-os-vm
```

`site.yml` runs bootstrap, the baseline, read_agent, this role (install takes
minutes) and the fleet monitoring crons. It does not write
`/etc/monitoring/health_check.conf`: only `deploy_monitoring.yml` does, so
until it runs the VM's health check watches `ssh cron fail2ban` and not
`uosserver` (seen in the rehearsal, 2026-11-13; fleet-wide fix is PER-181).
A fresh VM's health check fails on "Upgrade log not found" until
unattended-upgrades first runs, the next morning (2026-11-15: 48 runs, five
pages).

### 4. First run, in the browser: `https://10.30.40.201:11443`

Name → Next → **Proceed Without a UI Account** → console password (12+
characters, one special; into the password manager) → Terms of Service →
Finish. Then turn **auto-update off** for UniFi OS and Network: Network →
Settings → Control Plane → Updates, open each row, untick Auto-Update, Apply
Changes. It stayed off through the restore and restarts, in the rehearsal
and at the cutover. Every server restart ends the console session, so step
9's backup test needs a fresh owner login.

### 5. Restore

Network → Settings → Control Plane → Backups → **Upload & Restore** →
`restore.unf` (the dialog's **browse** link, then **Restore**). The Network
app restarts itself. At the cutover, a 9.4.19 backup restored into Network
10.5.67 without an error in under a minute, and the APs were back two to four
minutes later.

**Then make sure the autobackup is daily.** Network 10.5 refuses a daily
schedule with any history (`api.err.InvalidAutoBackupDays`). The cutover's
9.4 backup carried `0 3 * * *` with 30 days of statistics, so the restore fell
back to Mondays only (`0 3 * * 1`). Daily is allowed only as settings-only
(`autobackup_days: 0`): the settings are what a restore needs. A backup from
this server should already carry that; read it back either way. The console
has no control for the schedule, so set it through the Network API from the
logged-in console tab (browser devtools or Playwright).

**And turn device auto-upgrade off.** The restore carries the old setting,
which is on. Firmware newer than the APs run would reboot every AP the first
night: a second change stacked on the rebuild.

```js
const set = async (key, body) => {
  const g = await fetch('/proxy/network/api/s/default/get/setting/' + key);
  const csrf = g.headers.get('x-csrf-token'), id = (await g.json()).data[0]._id;
  const r = await fetch('/proxy/network/api/s/default/set/setting/' + key + '/' + id, { method: 'PUT',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf }, body: JSON.stringify(body) });
  return r.status;
};
await set('super_mgmt', { autobackup_cron_expr: '0 3 * * *', autobackup_days: 0 });   // 200
await set('mgmt', { auto_upgrade: false });                                          // 200
```

Read both back with the same GETs: `0 3 * * *`, days `0`, `auto_upgrade`
false. A schedule set this way fired on time, survived a reboot, and wrote
`autobackup_10.5.67_<date>_<UTC time>_<epoch ms>.unf` (rehearsal,
2026-11-15). Left weekly, `backup_unifi` first fails on Wednesday at 03:30: it
refuses a backup 26 h old or more, and Tuesday's run still sees Monday's file
at 24.5 h.

### 6. The read-only account

The restore skips every controller account. Create a local, view-only admin
with the vault's `vault_unifi_readonly_user` / `vault_unifi_readonly_password`:
Admins → Create New → Create New User → tick Admin (local access only is
forced) → Username and Password → untick Use a Predefined Role → Network
**View Only**, UniFi OS **None**. Least privilege, and enough: `bin/unifi-state`
reads every line with it. UniFi OS refuses a password without an uppercase
letter. The form defaults to **Super Admin** until the predefined role is
unticked, and it wants a first or last name: the username will do. Without
this account, step 7 cannot log in.

### 7. The APs come back (the gap ends)

```sh
bin/unifi-state > $D/after-1.txt
grep -c '^device .* adopted=true state=1 ' $D/after-1.txt   # 4, give it minutes
```

Two signs the restore did not carry the devices' keys: an AP stuck as
disconnected, or one asking to be adopted. Either one means the restore did
not take: restore again, or an older backup. Do not adopt by hand.

### 8. After-state

```sh
sleep 60; bin/unifi-state > $D/after-2.txt
diff $D/after-1.txt $D/after-2.txt && echo stable
diff $D/before-2.txt $D/after-2.txt && echo identical   # or step 0's baseline
```

Every line that differs is explained by the rebuild, or it is not done. Space
the logins out: UniFi OS answers HTTP 429 after about six a minute. If a
dead-man timer is armed, cancel it now.

### 9. Force every check once

On the VM (`ssh 10.30.40.201`), with the wrapper exactly as cron runs it
(`crontab -l` shows the lines):

- **Server check.** Run `sudo systemctl stop uosserver`, then the check's cron
  line. Expect a "fixed" message in #home-logging, and the server back. Then
  run it with `UNIFI_OS_INFORM_URL=http://127.0.0.1:1/inform` in front. The
  restart cannot fix that, so expect an alert in #home-alerts.
- **Backup.** Right after the restore the autobackup directory is empty, and
  `backup_unifi` fails on an empty directory. So set the step 5 schedule to a
  few minutes ahead, wait for a file, set it back to `0 3 * * *`, then run the
  backup's cron line and check the log for `Upload successful`.
- **Heartbeat.** Run `~/.scripts/monitoring/heartbeat_backup_unifi.sh` after
  the backup. healthchecks.io must show a fresh ping: the script exits 0
  silently whether it pinged or not.
- **System health.** `uosserver` is in `critical_services`, so the
  `systemctl stop` above must also show up in the next health check.

### 10. Settle

```sh
ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm    # changed=0
ssh cwwk 'sudo qm reboot 105'                                      # comes back alone
ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm    # changed=0 again
```

The run after the reboot catches cloud-init and Ansible fighting over the
hostname or `/etc/hosts`. The rehearsal caught exactly that, so the role now
disables cloud-init after the first `site.yml`. Then:

- **Updates back on:** auto-update for UniFi OS and Network in the console,
  and `set('mgmt', { auto_upgrade: true })` from step 5. Expect each AP to
  reboot onto new firmware at 03:00 that night.
- **agent-lxc's sweep** still knows the old host key for `unifi`. Clear it with
  `ssh 10.30.40.203 ssh-keygen -R unifi` (Touch ID), then deploy the sweep:
  `ansible-playbook ansible/playbooks/services.yml --limit agent-lxc`. Until
  then the sweep reports the VM as "UNREACHABLE — no response at all".
- Close the masters: `ssh -O exit cwwk; ssh -O exit 10.30.40.201`.
- Delete `restore.unf` from `docs/local/`. It holds the whole configuration,
  PSKs included.
