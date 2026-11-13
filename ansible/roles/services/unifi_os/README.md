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

Wired, with Ignacio present. Never from Wi-Fi: this moves the controller that
runs the Wi-Fi. The commands run from this repo's root on the branch.

**Wi-Fi during the gap (reasoned, not tested here):** UniFi APs keep serving
their last configuration while no controller answers. Between steps 3 and 9
nothing manages them: no stats, no changes, no guest portal.

**Rollback**, at any step after 3, until step 12 passes:

```sh
ssh cwwk 'sudo qm stop 105; sudo pct set 101 --onboot 1 && sudo pct start 101'
git revert $(git log -1 --format=%h --grep='retire unifi-lxc')   # CT 101 back in the inventory
```

The APs inform to the same address either way. Allow a few minutes for ARP
caches to learn the MAC that moved.

### 0. Preflight

```sh
bin/unifi-cutover-preflight          # every line PASS; stop at a FAIL
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

### 3. Stop CT 101 (the gap starts)

```sh
ssh cwwk 'sudo pct set 101 --onboot 0 && sudo pct shutdown 101 --timeout 120; sudo pct status 101'
```

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
ssh cwwk 'sudo pvesh set /cluster/backup/backup-34b8bdac-4d3a --vmid 100,105'
ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit cwwk,unifi-os-vm
```

`site.yml` runs bootstrap, the baseline, read_agent, this role (install takes
minutes) and the fleet monitoring crons. It does not write
`/etc/monitoring/health_check.conf`: only `deploy_monitoring.yml` does, so
until it runs the VM's health check watches `ssh cron fail2ban` and not
`uosserver` (seen in the rehearsal, 2026-11-13). The vzdump job and
`check_vm_status` move from CT 101 to VM 105. `check_vm_status` reports CT 101
as stopped until the `deploy_monitoring.yml` run.

### 6. First run, in the browser: `https://10.30.40.201:11443`

Name → Next → **Proceed Without a UI Account** → console password (12+
characters, one special; into the password manager) → Terms of Service →
Finish. Then turn **auto-update off** for UniFi OS and Network.

### 7. Restore

Network → Settings → Control Plane → Backups → **Upload & Restore** →
`cutover.unf`. The Network app restarts itself. Seen in the spike: the 9.4.19
backup restores into Network 10.5.67 without an error.

### 8. The read-only account

The restore skips every controller account. Create a local, view-only admin
with the vault's `vault_unifi_readonly_user` / `vault_unifi_readonly_password`
(the exact UI path was not checked in the spike). Without it, step 9 cannot
log in.

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

### 11. Force every check once

On the VM (`ssh 10.30.40.201`), with the wrapper exactly as cron runs it
(`crontab -l` shows the lines):

- **Server check.** Run `sudo systemctl stop uosserver`, then the check's cron
  line. Expect a "fixed" message in #home-logging, and the server back. Then
  run it with `UNIFI_OS_INFORM_URL=http://127.0.0.1:1/inform` in front. The
  restart cannot fix that, so expect an alert in #home-alerts.
- **Backup.** First check where the autobackups are:
  `cd /tmp && sudo -u uosserver podman exec uosserver ls -l /var/lib/unifi/backup/autobackup`.
  This path is reasoned from the Debian package's layout, not seen yet. If the
  directory is empty, run a backup from the UI. Then run the backup's cron line
  and check the log for `Upload successful`. If the path is wrong, fix it in
  `backup_unifi.sh` and redeploy.
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
hostname or `/etc/hosts`. Turn auto-update back on, then close the masters
with `ssh -O exit cwwk; ssh -O exit 10.30.40.201`.

### After the cutover

- **agent-lxc's sweep** knows CT 101's host key for `unifi`. Clear it with
  `ssh 10.30.40.203 ssh-keygen -R unifi` (Touch ID), then deploy the sweep
  label: `ansible-playbook ansible/playbooks/services.yml --limit agent-lxc`.
- **CT 101** stays stopped, `onboot=0`, until the VM's first nightly off-host
  backup exists (03:30 the next morning). Then destroy it. Then retire the
  `unifi` role, `group_vars/network_controller.yml`, its `services.yml`
  include, and the docs that name unifi-lxc (NETWORK.md,
  BACKUP_AND_RECOVERY.md, COVERAGE.md).
- Delete `cutover.unf` from `docs/local/`. It holds the whole configuration,
  PSKs included.
