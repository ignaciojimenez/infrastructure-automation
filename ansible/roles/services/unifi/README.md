# unifi — the UniFi Network controller on unifi-lxc

Installs the controller with GlennR's installer once, then owns Ubiquiti's apt
source (PER-105), the monitoring crons and the nightly `.unf` backup.

Deploy: `ansible-playbook ansible/playbooks/services.yml --limit unifi-lxc --tags unifi`

## Release-line upgrades

> **Fallback only (2026-11-11).** The plan is to migrate to UniFi OS Server in
> a VM (PER-127, spike PER-178; reasoning in
> [ARCHITECTURE_DECISIONS.md](../../../../docs/ARCHITECTURE_DECISIONS.md#unifi-controller--unifi-os-server-in-a-vm-2026-11-11)).
> This in-place procedure is used only if a 9.4 backup will not restore there,
> to reach 10.6 first. The before/after check below serves both paths.
>
> **That is likely (2026-11-11).** UniFi OS Server runs Network 11 (11.0.99,
> 2026-11-02, published only for UniFi OS), and the standalone application
> ends at 10.6.109. One community report matches our case: a 9.5 backup was
> refused by UniFi OS Server on 10.4 ("incompatible or corrupted"). The advice
> there and in migration guides was to bring the old controller to its latest
> release before exporting. No Ubiquiti statement of the rule was found. The PER-178 spike tries 9.4 directly first,
> because a failed restore into the new VM costs nothing.

**Patches within a line** arrive through apt and unattended-upgrades
(`custom_origins: site=www.ui.com` in the inventory). **A jump to a new line**
(9.4 → 10.6) follows the procedure below, by hand, with a person present.
Never on a schedule: GlennR's updater swaps MongoDB and Java under the
controller, and the network controller is down while it runs.

The repo decides what changes; GlennR's updater does the upgrade; a diff of the
controller's state before and after decides whether it worked.

### What was verified, and when

Re-check these each time. They are facts about other people's systems.

| Fact | How to check | Last seen |
|---|---|---|
| Latest Network release | `curl -s 'https://api.glennr.nl/api/latest-application-release?app=network&version=latest'`, then the same version in Ubiquiti's API: `https://fw-update.ui.com/api/firmware-latest?filter=eq~~version_major~~10&filter=eq~~version_minor~~6&filter=eq~~version_patch~~109&filter=eq~~platform~~debian` must list it with `channel: release` | 10.6.109, released 2026-10-23 (2026-11-10) |
| The target line's apt suite has a package | `curl -sL https://dl.ui.com/unifi/debian/dists/unifi-10.6/ubiquiti/binary-amd64/Packages.gz \| gunzip \| grep ^Version` | ⚠️ **empty** for unifi-10.5 and unifi-10.6. The last suite with a package is unifi-10.4. Ubiquiti's `stable` suite points at the empty unifi-10.5. Every suite's `Release` is dated 2026-07-27 (2026-11-10) |
| The updater jumps directly, no stepping | Read `application_upgrade_releases` and the `--skip --unifi-version` path in `unifi-update.sh` | It installs the requested version in one step, from 9.4 straight to the target. The only forced intermediate is 5.6.40 → 5.6.42. v10.7.8, sha256 `4a727957…672d7f` (2026-11-10) |
| The updater self-updates | `script_version_check` replaces the script with any newer published version before running | Compare `curl -s 'https://api.glennr.nl/api/latest-script-version?script=unifi-update&api_version=2'` with the version you read; if newer, read the diff first |

The empty suite means that, after a jump to 10.5 or later, **apt delivers no
UniFi patches** until Ubiquiti publishes into that suite. Keep
`unifi_repo_suite` on the installed line anyway, so a populated suite is picked
up the day it appears, and do not mistake a clean `unattended-upgrade
--dry-run` for patches arriving.

### The before/after check

`bin/unifi-state` (laptop) logs in to the controller's loopback API on the host
with the vault's read-only account (`vault_unifi_readonly_*`) and prints one
sorted line per site, device, network and WLAN:

- **site**: name, and its device, network and WLAN counts.
- **device**: MAC, name, model, adopted, state (1 = connected), firmware.
- **network**: name, purpose, VLAN, subnet, enabled.
- **WLAN**: SSID, enabled, network, security, hidden, guest.

Uptimes, IPs, counters and clients are left out: they move on their own. The
controller version goes to stderr. **`diff -u before after` is the pass/fail:
empty passes; any line not explained by the upgrade fails it and points at the
rollback.**

The account is View Only, and the controller enforces it: a write returns
`api.err.NoPermission` (forced 2026-11-10). It cannot see WLAN passphrases.
The snapshot still correlates SSIDs, VLANs and MACs, so it lives in
`docs/local/unifi-state/` (gitignored), never in a tracked file or an issue.

### Procedure

Set the target once; every command below uses it.

```sh
TARGET=10.6.109                 # from "Latest Network release" above
LINE=unifi-10.6                 # unifi-<major>.<minor>
SNAP=pre_unifi_10_6_109         # Proxmox: [a-z][a-z0-9_-]+
mkdir -p docs/local/unifi-state
```

**0. Be on a cable.** The controller is down while the updater runs, and the
APs re-provision when it comes back. A laptop on Wi-Fi can lose the session,
and a failed upgrade is then recovered over a cable anyway. Start wired.

**1. Pre-flight** (read-only, no Touch ID)

```sh
# Last night's .unf made it off-host. Grep only these lines: the same log also
# holds the upload's management URL, which is a secret.
ssh unifi-agent 'sudo -n /usr/local/bin/agent_read log unifi_backup.log' \
  | grep -a 'Found latest backup\|exit code' | tail -2
ssh unifi-agent 'grep -o -m1 -w avx /proc/cpuinfo; df -h /; dpkg-query -W unifi'

# Two captures with nothing in between must not differ.
bin/unifi-state > docs/local/unifi-state/before.txt
bin/unifi-state > docs/local/unifi-state/before-2.txt
diff -u docs/local/unifi-state/before.txt docs/local/unifi-state/before-2.txt && echo "baseline stable"
```

The `.unf` has never been restore-tested (COVERAGE blank 1), and the cron
copies the *previous* night's file (it fires at 03:00, alongside the
controller's own autobackup). **The snapshot in step 2 is the real rollback.**
No AVX would send the updater down a different MongoDB path, which this
procedure has not reviewed.

**2. Snapshot** (on cwwk; Touch ID)

Stop the controller first, so MongoDB is shut down cleanly and the snapshot
holds a clean database rather than a crash-consistent one:

```sh
ssh -t cwwk "sudo pct exec 101 -- systemctl stop unifi \
  && sudo pct snapshot 101 $SNAP --description 'before UniFi $TARGET' \
  && sudo pct exec 101 -- systemctl start unifi"
ssh cwwk-agent 'sudo -n /usr/sbin/zfs list -t snapshot rpool/data/subvol-101-disk-0'
```

**3. Run the updater** (on unifi-lxc, in tmux; Touch ID; a person present)

Stop cron for the duration: `check_unifi_service` restarts a stopped
controller every 13 minutes, and halfway through a MongoDB swap is the worst
moment for that.

```sh
ssh -t unifi
sudo systemctl stop cron
sudo tmux new -s unifi-upgrade
# inside tmux, as root:
cd /root && curl -fsSLO https://get.glennr.nl/unifi/update/unifi-update.sh
sha256sum unifi-update.sh       # must equal the checksum you reviewed
bash unifi-update.sh --skip --unifi-version "$TARGET" 2>&1 | tee "/root/unifi-update-$TARGET.log"
```

If SSH drops: `ssh -t unifi sudo tmux attach -t unifi-upgrade`. The updater
keeps its own logs in `/srv/EUS/logs/`.

**4. Verify** (read-only)

Give the APs a few minutes to reconnect, then:

```sh
ssh unifi-agent 'dpkg-query -W unifi'                     # the target line
bin/unifi-state > docs/local/unifi-state/after.txt        # stderr: controller <TARGET>
diff -u docs/local/unifi-state/before.txt docs/local/unifi-state/after.txt
```

An empty diff passes. A device at `state=` other than 1 may still be
reconnecting: capture again after five minutes before calling it a failure.
Anything still different, and not explained, means **rollback (step 7)**.

Then start cron again: `ssh -t unifi sudo systemctl start cron`.

**5. Move the repo to the new line**

Set `unifi_repo_suite: "<LINE>"` in `defaults/main.yml`, in the same change
that records the upgrade. Deploy twice:

```sh
ansible-playbook ansible/playbooks/services.yml --limit unifi-lxc --tags unifi   # converges
ansible-playbook ansible/playbooks/services.yml --limit unifi-lxc --tags unifi   # must be changed=0
ssh -t unifi 'sudo apt-get update && sudo unattended-upgrade --dry-run --debug 2>&1 \
  | grep -i "www.ui.com\|allowed origins\|error\|traceback"'
```

`apt-get update` must finish with no `Err:` or `W:` line, and the dry run must
list the `site=www.ui.com` origin without an error. Count the hosts in the
recap: `--limit unifi-lxc` must show one.

The updater may already have rewritten the suite in `unifi.sources` (it
replaces `unifi-X.Y` in any source that names one). The deploy makes the file
match the repo either way.

**6. Close out**

Keep the snapshot until a nightly `.unf` from the new version is off-host,
then `ssh -t cwwk sudo pct delsnapshot 101 $SNAP`.

**7. Rollback**

```sh
ssh -t cwwk "sudo pct stop 101 && sudo pct rollback 101 $SNAP && sudo pct start 101"
```

Then `bin/unifi-state` against `before.txt` must be empty again, and the repo's
`unifi_repo_suite` stays on the old line. Do not merge the bump.
