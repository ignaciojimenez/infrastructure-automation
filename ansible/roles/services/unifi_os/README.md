# unifi_os — UniFi OS Server, the network controller (PER-127)

UniFi OS Server in a Debian 13 VM (VM 105, `unifi-os-vm`, 10.30.40.201). It
replaces the standalone Network Application on unifi-lxc (CT 101), whose
release line has ended. The reasoning is in
[ARCHITECTURE_DECISIONS.md](../../../../docs/ARCHITECTURE_DECISIONS.md#unifi-controller--unifi-os-server-in-a-vm-2026-11-11).
Facts seen during the PER-178 spike are in the
[unifi role's README](../unifi/README.md#unifi-os-server-per-178-spike-2026-11-12).

The role installs the server once, from Ubiquiti's installer pinned by version
and checksum (`defaults/main.yml`). It then owns what every host here owns:

| What | How |
|---|---|
| Server check, self-healing | `check_unifi_os`, every 13 min: unit, container, console on 11443, inform port 8080 |
| Nightly off-host backup | `backup_unifi --unifi-os` at 03:30, after the Network app's 03:00 autobackup |
| Backup heartbeat | the same healthchecks.io check unifi-lxc used |
| Read-only state capture | `/usr/local/bin/unifi-state`, driven by `bin/unifi-state --unifi-os` |
| System health, read_agent, SSH | the fleet baseline, via `site.yml` |

Deploy: `ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm`

**Not in Ansible:** the console's first run, the configuration restore, the
read-only account and auto-update. They are browser steps (below).
**Auto-update** is on by default for both UniFi OS and Network. It is off
during the cutover so the before/after comparison compares one change, then
back on: security fixes are why we left 9.4.

## Cutover runbook

With Ignacio present. The commands run from this repo's root on the branch.

**Wi-Fi during the gap (reasoned, not tested here):** UniFi APs keep serving
their last configuration while no controller answers. Between steps 3 and 9
nothing manages them: no stats, no changes, no guest portal.

**Wi-Fi is fine, because of a dead-man timer.** This moves the controller that
runs the Wi-Fi, so a laptop on Wi-Fi could lose its way back to cwwk exactly
when a rollback is needed. Step 3 arms a timer on cwwk that rolls back on its
own after 90 minutes; step 10 cancels it once the after-state is clean. A
cutover that drops the laptop's Wi-Fi undoes itself, and the Wi-Fi with it.
Not cancelling it undoes a good cutover, so step 12 checks it is gone.

**Rollback**, at any step after 3, until step 12 passes:

```sh
ssh cwwk 'sudo systemctl stop unifi-rollback.timer; sudo qm stop 105; sudo pct set 101 --onboot 1 && sudo pct start 101'
git revert $(git log -1 --format=%h --grep='retire unifi-lxc')   # CT 101 back in the inventory
ssh cwwk 'sudo pvesh set /cluster/backup/backup-34b8bdac-4d3a --vmid 100,101'   # if step 5 ran
```

The timer runs the first line's cwwk half; the other two wait for the laptop.
The APs inform to the same address either way. Allow a few minutes for ARP
caches to learn the MAC that moved.

### 0. Preflight

```sh
bin/unifi-cutover-preflight          # every line PASS; stop at a FAIL
# "APs adopted and connected" also proves CT 101's read-only account has the
# vault's password: it logs in with it.
ssh -o ControlPersist=8h -o ServerAliveInterval=60 -MNf cwwk   # Touch ID 1
```

### 1. Before-state, twice

```sh
D=../infrastructure-automation/docs/local/unifi-state   # gitignored
bin/unifi-state > $D/before-cutover-1.txt
sleep 30; bin/unifi-state > $D/before-cutover-2.txt
diff $D/before-cutover-1.txt $D/before-cutover-2.txt && echo stable
```

### 2. The backup to restore

Last night's 03:00 autobackup, unless the controller was changed since. If it
was, run a manual backup in the old UI first. Copy it, checksum both ends:

```sh
F=$(ssh cwwk "sudo pct exec 101 -- sh -c 'ls -1t /var/lib/unifi/backup/autobackup/*.unf | head -n 1'")
ssh cwwk "sudo pct exec 101 -- sha256sum $F"
(umask 077; ssh cwwk "sudo pct exec 101 -- cat $F" > $D/cutover.unf); shasum -a 256 $D/cutover.unf
```

### 3. Arm the rollback, stop CT 101 (the gap starts)

```sh
ssh cwwk 'sudo systemd-run --on-active=90min --unit=unifi-rollback /bin/sh -c "qm stop 105; pct set 101 --onboot 1 && pct start 101"'
ssh cwwk 'systemctl list-timers unifi-rollback.timer'            # one timer, ~90 min left
ssh cwwk 'sudo pct set 101 --onboot 0 && sudo pct shutdown 101 --timeout 120; sudo pct status 101'
```

90 minutes is a guess at steps 3–10, not a measurement. If a step runs long,
re-arm before it fires: stop the timer, then run the first line again.

### 4. Replace the spike VM with the real one

The spike's VM 105 holds a restored copy of the configuration and a test
console password. It goes; the real one is built fresh at .201. Provisioning
refuses to create the VM while anything answers on .201.

```sh
ssh cwwk 'sudo qm destroy 105 --purge'
ansible-playbook ansible/playbooks/provision_unifi_os_vm.yml
ssh-keygen -R 10.30.40.201; ssh-keygen -R unifi; ssh-keygen -R unifi-agent
ssh -o StrictHostKeyChecking=accept-new -o ControlPersist=8h -MNf 10.30.40.201   # Touch ID 2
```

### 5. Build it like every host, and back it up

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
`uosserver` (seen in the rehearsal, 2026-11-13; fleet-wide fix is PER-181). The vzdump job and
`check_vm_status` move from CT 101 to VM 105. `check_vm_status` reports CT 101
as stopped until the `deploy_monitoring.yml` run.

### 6. First run, in the browser: `https://10.30.40.201:11443`

Name → Next → **Proceed Without a UI Account** → console password (12+
characters, one special; into the password manager) → Terms of Service →
Finish. Then turn **auto-update off** for UniFi OS and Network: Network →
Settings → Control Plane → Updates, open each row, untick Auto-Update, Apply
Changes. In the rehearsal it stayed off through the restore and restarts.

### 7. Restore

Network → Settings → Control Plane → Backups → **Upload & Restore** →
`cutover.unf`. The Network app restarts itself. Seen in the spike: the 9.4.19
backup restores into Network 10.5.67 without an error.

**Then put the autobackup back to daily.** CT 101 runs `0 3 * * *` with 30
days of statistics. Network 10.5 refuses daily with any history
(`api.err.InvalidAutoBackupDays`), so the restore fell back to Mondays only
(`0 3 * * 1`). Daily is allowed only as settings-only (`autobackup_days: 0`):
the settings are what a restore needs. The console has no control for the
schedule, so set it through the Network API from the logged-in console tab
(browser devtools or Playwright):

**And turn device auto-upgrade off.** CT 101 upgrades AP firmware at 03:00,
and the restore carries that over. Network 10.5 knows newer firmware than 9.4,
so the first night would reboot every AP onto it: a second change stacked on
the migration. Off now, back on once the cutover has run quietly for a few
days (below).

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
false. In the rehearsal (2026-11-15) a schedule set this way fired on time,
survived a reboot, and wrote
`autobackup_10.5.67_<date>_<UTC time>_<epoch ms>.unf`; `auto_upgrade` turned
off and on. Left weekly, `backup_unifi` fails at 03:30 on Tuesday: it refuses
a backup older than 26 h.

### 8. The read-only account

The restore skips every controller account. Create a local, view-only admin
with the vault's `vault_unifi_readonly_user` / `vault_unifi_readonly_password`:
Admins → Create New → Create New User → tick Admin (local access only is
forced) → Username and Password → untick Use a Predefined Role → Network
**View Only**, UniFi OS **None**. Least privilege, and enough: in the
rehearsal it logged in and `bin/unifi-state --unifi-os` read every line.
UniFi OS refuses a password without an uppercase letter; 9.4 did not, so the
vault's was rotated (2026-11-13). Without this account, step 9 cannot log in.

### 9. The APs come back (the gap ends)

```sh
UNIFI_STATE_HOST=unifi-agent bin/unifi-state --unifi-os > $D/after-cutover-1.txt
grep -c '^device .* adopted=true state=1 ' $D/after-cutover-1.txt   # 4, give it minutes
```

`unifi-agent` reaches the VM now: `unifi` resolves to .201. Two signs the
restore did not carry the devices' keys: an AP stuck as disconnected, or one
asking to be adopted. Either one means **rollback**. Do not adopt by hand.

### 10. After-state

```sh
sleep 60; UNIFI_STATE_HOST=unifi-agent bin/unifi-state --unifi-os > $D/after-cutover-2.txt
diff $D/after-cutover-1.txt $D/after-cutover-2.txt && echo stable
diff $D/before-cutover-1.txt $D/after-cutover-2.txt && echo identical
```

Every line that differs is explained by the move, or it's a **rollback**.
Space the logins out: UniFi OS answers HTTP 429 after about six a minute.

Clean: the cutover holds, so disarm the rollback.

```sh
ssh cwwk 'sudo systemctl stop unifi-rollback.timer; systemctl list-timers --all unifi-rollback.timer'   # 0 timers
```

### 11. Force every check once

On the VM (`ssh 10.30.40.201`), with the wrapper exactly as cron runs it
(`crontab -l` shows the lines):

- **Server check.** Run `sudo systemctl stop uosserver`, then the check's cron
  line. Expect a "fixed" message in #home-logging, and the server back. Then
  run it with `UNIFI_OS_INFORM_URL=http://127.0.0.1:1/inform` in front. The
  restart cannot fix that, so expect an alert in #home-alerts.
- **Backup.** The autobackups are at
  `cd /tmp && sudo -u uosserver podman exec uosserver ls -l /var/lib/unifi/backup/autobackup`
  (seen in the rehearsal). Right after the restore it is empty, and
  `backup_unifi` fails on an empty directory. So set the step 7 schedule to a
  few minutes ahead, wait for a file, set it back to `0 3 * * *`, then run the
  backup's cron line and check the log for `Upload successful`.
- **Heartbeat.** Run `~/.scripts/monitoring/heartbeat_backup_unifi.sh` after
  the backup. healthchecks.io must show a fresh ping.
- **System health.** `uosserver` is in `critical_services`, so the
  `systemctl stop` above must also show up in the next health check.

### 12. Settle

```sh
ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm    # changed=0
ssh cwwk 'sudo qm reboot 105'                                      # comes back alone
ansible-playbook ansible/playbooks/site.yml --limit unifi-os-vm    # changed=0 again
```

The run after the reboot catches cloud-init and Ansible fighting over the
hostname or `/etc/hosts`. The rehearsal caught exactly that, so the role now
disables cloud-init after the first `site.yml`. Turn auto-update back on.
`ssh cwwk-agent systemctl list-timers --all unifi-rollback.timer` must show
0 timers: an armed one would undo the cutover. Then close the masters with
`ssh -O exit cwwk; ssh -O exit 10.30.40.201`.

### After the cutover

- **agent-lxc's sweep** knows CT 101's host key for `unifi`. Clear it with
  `ssh 10.30.40.203 ssh-keygen -R unifi` (Touch ID), then deploy the sweep
  label: `ansible-playbook ansible/playbooks/services.yml --limit agent-lxc`.
- **CT 101** stays stopped, `onboot=0`, until the VM's first nightly off-host
  backup exists (03:30 the next morning). Then destroy it. Then retire the
  `unifi` role, `group_vars/network_controller.yml`, its `services.yml`
  include, and the docs that name unifi-lxc (NETWORK.md,
  BACKUP_AND_RECOVERY.md, COVERAGE.md).
- **Device auto-upgrade back on**, after a few quiet days:
  `set('mgmt', { auto_upgrade: true })` from step 7. Expect each AP to
  reboot onto new firmware at 03:00 that night.
- Delete `cutover.unf` from `docs/local/`. It holds the whole configuration,
  PSKs included.
