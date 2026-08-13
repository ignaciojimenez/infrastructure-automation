# Infrastructure TODO — Prioritized Action List

Updated: 2026-08-13 | Validated against live hosts via read_agent autonomous assessment

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

> **Network layer:** see [NETWORK.md](NETWORK.md) — topology, VLANs, VPN and DNS,
> plus thirteen findings from deriving it on 2026-08-07/08 that are not yet
> tracked here.
>
> **Documentation consolidation** is briefed in
> `~/.claude/plans/doc-consolidation-brief.md` — it moves those findings into
> this file, drains this file of measurements, and adds `docs/ARCHITECTURE.md`.
> ~~**Blocked until L-A is merged**, because nine branches add ~1,600 lines here.~~
> ✅ **UNBLOCKED 2026-08-10** — L-A merged all nine (`main` @ `650909f`), so the
> ~1,600 lines have landed and this can start. Branch `docs/consolidation-2026-08`.

---

## 🔴 Live alert flood, triaged 2026-08-11 — three separate streams, only one covered by the pending deploy

Triggered by "I'm getting Slack alerts from agent-lxc and nightly alerts too". All three verified live from the laptop; separating them matters because the planned L-B/L-C deploy fixes exactly one.

**Stream 1 — hourly `Script Failed on agent-lxc` at `:37`, continuously since 2026-08-10 12:37.** The Tier 1 sweep exits 1 on three findings, all confirmed real:

| Finding | Verified | Status |
|---|---|---|
| `opnsense: UNREACHABLE (no response as read_agent)` | `ssh opnsense-agent` → `Permission denied (publickey)` | **recurrence of Priority 2** — the handover's "verified working 2026-08-07" is stale. Fix: `ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense` |
| `vinylstreamer: UNREACHABLE` | `ssh vinylstreamer-agent` → connection timed out | **new, untracked.** Host-level, not a key problem — no TCP answer at all |
| `cobra: 1 failed systemd unit(s): ●` | `systemctl --failed` on cobra → `nmbd.service` failed (Samba NMB) | real failure **plus** a parse bug, below. ✅ **`nmbd` restarted and green 2026-08-13 during L-B** — cobra now exits 0. The parse bug and the boot race that caused it are both still open; see the L-B section. |

⚠️ **Deploying L-B/L-C does not silence this.** These are correct detections of real faults; the sweep will keep exiting 1 until the hosts are fixed. The *repetition* (24 pages/day, no dedup) is the still-open wrapper item at line ~675 — confirmed still unfixed on `main`: `enhanced_monitoring_wrapper` has a bare `# Always notify on failures / SEND_TO_ALERT=true` branch with no cooldown. The merged anomaly-dedup work fixed Tier 2 *re-billing*, not Slack volume. This is the strongest live case yet for that item.

🐛 **New latent bug — `FAILEDUNITS` loses every unit name.** `fleet_health_check.sh.j2:224` and `:233` run `systemctl --failed --no-legend --no-pager | awk '{printf "%s ", $1}'`. Without `--plain`, systemd prefixes the line with `●`, so `$1` is the bullet and the unit name is discarded — every report reads `N failed systemd unit(s): ● ● …`. Reproduced verbatim on cobra: the command returns `● `. `scripts/common/system_health_check.sh:463` already gets this right (`--no-legend --plain`); the fleet sweep never got the same fix. One-word fix, but it means **ten days of sweep reports named no unit at all**, so the history is unusable for "when did nmbd break". Classic parse-yields-nothing bug — the pattern matched, the value was empty.

**Stream 2 — `Slack watch could not read #home-alerts (ERR invalid_ts_oldest)`, every 6h at `:07`.** This one **is** already fixed on `main` (the poisoned `0.000000` watermark, self-healing guard — see the Slack-watch section below) and is simply **not deployed**. `services.yml --limit agent-lxc --tags agent` (handover step B8 / session L-C) clears it. Only stream covered by the pending work.

**Stream 3 — nightly healthchecks.io `backup_homeassistant` / `backup_unifi` / `backup_opnsense` DOWN then UP.** Not in any plan. Exactly the three heartbeats with `backup_max_age_minutes: 1560`; the three at `10320` never alert. Pattern on 2026-08-11: DOWN 02:30, UP 04:30 — recovery lands on the first `*/2` heartbeat after the 04:00/04:15 backup crons, so **the backups themselves are succeeding**; what gaps is the ping stream overnight. Same shape on 2026-08-09 (~21:55–22:10), drifting because healthchecks derives DOWN from last-ping time.

✅ **The state files are NOT the cause — measured 2026-08-12 as `choco`:**

| Host | State file mtime | `last_status` |
|---|---|---|
| `unifi` | `2026-08-12 03:00:04` | `success` |
| `dockassist` | `2026-08-12 04:00:23` | `success` |

Both gates in `heartbeat_backup.sh` therefore pass at **every** `*/2` heartbeat: mtime is at most ~24h old against a 26h (`1560`) window, and status is `success`. A backup that runs daily can never age out of a 26h window. **So the script, whenever it actually runs, pings.**

⚠️ **This rules out the freshness-window explanation and relocates the fault.** The DOWN notice's "Last Ping: Success, 1 day, 6 hours ago" (= period 1 day + grace 6h, so a genuine ~30h ping gap) can now only mean the heartbeat **did not run**, or **ran and the ping did not land**. Two consequences:

1. 🔴 **All three checks went DOWN and recovered together** (UP at `04:30:03`, `04:30:04`, `04:30:04`) across three independent hosts with three independent crons. Simultaneity across hosts points at a *shared* cause — the outbound path (opnsense is the gateway, and it threw `Script Failed on OPNsense.internal` at 12:30 on 08-10, inside the gap) or healthchecks.io itself — not at per-host cron drift. Confirm before assuming: the healthchecks.io ping log shows every ping with timestamp and source IP, which discriminates "cron didn't fire" (staggered, per-host) from "path broke" (all three, same minute).
2. 🐛 **A failed ping is silent by design.** `heartbeat_backup.sh:30` is `curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true`. The `|| true` and the discarded stderr mean a dead-man's switch cannot report that its own ping failed — the only evidence is the absence healthchecks.io eventually notices, 30h later. Worth logging the curl exit status even if the script still exits 0.

Still to check, in order: the healthchecks.io ping log for one of the three; then `crontab -l | grep -i heartbeat` and the rendered `MAX_AGE_MINUTES` on `unifi`/`dockassist` — the per-host `heartbeat_backup_*.sh` are role-owned, so they are in the silent-drift class that `deploy_monitoring.yml` does not sync.

**Hypothesis, unverified:** the flood starting 2026-08-10 12:37 is adjacent to a one-off `Script Failed on OPNsense.internal` at 12:30 the same day, which fits the known pattern of an OPNsense firmware/config event dropping the uid≥2000 `read_agent` account. Worth confirming from `pkg query` timestamps when the firewall is reachable again.

---

## unifi-lxc has never had `--tags ssh` applied — L-B will restart its sshd (measured 2026-08-08)

**Risk:** Low, but it will look alarming mid-deploy if it is not expected. Found during the L-A pre-flight (A1), which is a `--check --diff` run and changed nothing.

A1's gate is *"no diff on `sshd_config`, no change to `authorized_keys`"*, and **both tripped**. The branches are not the cause: the same `--check --diff` was run from `main` and from `fix/deploy-plumbing-dirs-2026-08`, and **the diff bodies are byte-identical**. The nine merged branches' delta on those two files is exactly zero — that branch's only template change is an `is_test_environment` conditional that renders `PermitRootLogin no` on any fleet host, i.e. what was already there.

What the diff actually is, all of it `unifi-lxc` drift against `main`:

| Task | Diff | Why |
|---|---|---|
| Deploy hardened sshd config | header comment + `TCPKeepAlive`/`LoginGraceTime` move above a comment | deployed copy is stamped `Generated by Ansible - 2025-10-12`; the template has since dropped its render timestamp. **No directive changes value, none are added or removed.** |
| Set authorized keys from github | **+1 key, −0** | the task is `exclusive: true` against `https://github.com/<profile>.keys`, which now serves **6** keys; the host has 5. Purely additive — nothing is revoked, and the connecting key survives. |
| Disable root user login | root's shell → `/sbin/nologin` | see below |
| Create SSH monitoring script | new file | `~/.scripts/check_ssh_security.sh` is simply absent there |

**`unifi-lxc` is the only host in this state.** Root's shell was read on all six reachable Debian hosts: `dockassist`, `cobra`, `hifipi`, `vinylstreamer` and `cwwk` are already `/sbin/nologin`; **only `unifi` is still `/bin/bash`**. Combined with the Oct-2025 stamp on its `sshd_config`, `unifi-lxc` is the one host the SSH role has not reached in a long time — this is host drift, not a fleet-wide surprise waiting in L-B.

**Consequence for L-B:** the first real `--tags ssh` run touching `unifi-lxc` notifies `restart_ssh`. That is safe (`sshd -t` validates before the write, and `PermitRootLogin no` is already deployed so locking root's shell removes no access that exists), but it is an SSH restart on a live host and should not be a surprise. Nothing else in the fleet is implicated.

~~⚠️ **Not verified:** root's *password-lock* state anywhere…~~ ✅ **ANSWERED 2026-08-13** — the fleet-wide `--check --diff` below was run. Results in the next section.

```sh
ansible-playbook ansible/playbooks/services.yml --tags ssh --check --diff   # all hosts, read-only
```

---

## The fleet-wide SSH check, run 2026-08-13 — one row above is now WRONG

All eight hosts reachable, nothing changed (`--check`). **The headline holds: `unifi-lxc` is still the only host with an `sshd_config` diff and the only one that restarts sshd.** Two things the table above got wrong or could not know:

🔴 **The `authorized_keys` row is VOID — retract it, do not act on it.** It said GitHub serves **6** keys and `unifi-lxc` has 5. **GitHub now serves 5**: the `ssh-ed25519 …QpDuP` key present on 2026-08-08 has since been **removed from the account**. So `unifi-lxc` is now `ok` on that task — the gap closed because *the source changed*, not because the host did.

⚠️ **The real lesson is the mechanism, not the key.** `authorized_key` runs with `exclusive: true` against a **live external URL**. A key added to GitHub lands on every host at the next run; **a key removed from GitHub is deleted from every host at the next run.** The effective access set for the whole fleet therefore changed between 2026-08-08 and 2026-08-13 with **no repo commit, no deploy and no review**. That is the documented design, but it means any `authorized_keys` finding is a snapshot of a moving target and must be re-read at deploy time rather than trusted from a previous session.

### What each host actually wants

| Host | changed | What |
|---|---:|---|
| `agent-lxc` | **0** | fully converged |
| `cobra`, `dockassist`, `hifipi`, `vinylstreamer` | 1 each | `update_keys` shebang only — `#!/bin/bash` → `#!/bin/sh` on a one-line `curl` script. Cosmetic. |
| `cwwk` | 3 | the shebang, plus root's and `choco`'s password lock |
| `unifi-lxc` | 4 | `sshd_config` (**+ sshd restart**), root login, `check_ssh_security.sh` |
| `opnsense` | 6 | `authorized_keys` reorder/comment-strip (same 5 keys — verified by comparing the base64, nothing added or removed), root + `choco` password lock, `check_ssh_security.sh`, and the `scripts_dir` migration below |

**Password locks, now answered as far as it can be without root.** `Disable root user login` is `changed` on `cwwk`, `opnsense`, `unifi-lxc`. On `unifi-lxc` the shell alone explains it. On `cwwk` root's shell was *directly measured* as `/sbin/nologin` already, and on `opnsense` the task omits `shell` entirely — so on those two the only attribute left that can differ is **`password_lock`**. `Lock the user account password` (the `choco` account) is `changed` on `cwwk` and `opnsense`. ⚠️ **Deduced from the task's own field set plus a direct shell reading — not read out of `/etc/shadow`**, which needs privilege `read_agent` does not have.

🛑 **A prediction elsewhere in this file is now stale and will stop L-B for no reason.** The pre-flight note says the monitoring-directory task reports `ok` on every host and that a `changed` "is a finding, not noise". **`opnsense` now reports `changed` on `/home/choco/.scripts`** — because `refactor/opnsense-scripts-dir-2026-08` merged and moved its `scripts_dir` there. **That is B6 doing its job, not drift.** `/home/choco/.logs` is `ok`; every other host is `ok` on both. Treat a `changed` on any host *other than opnsense's `.scripts`* as the finding.

⚠️ **Still not verified:** the actual `/etc/shadow` state on any host, and the presence of `check_ssh_security.sh` by direct inspection — `/home/choco` is `0700`, so `read_agent` gets `Permission denied`, which reads as "absent" if stderr is discarded. The playbook's `--check` result is the authority for that file, not a shell probe.

---

## ✅ L-B DEPLOYED 2026-08-13 — the monitoring sprint is live on all 8 hosts (B1–B7)

Steps B1–B7 all applied from `main` and verified. **The headline: the aggregation fix is real, not a lobotomy — it caught a genuine 4-day-old failure on its first fleet run.** Two steps were deliberately narrowed after their dry runs disagreed with the plan; both are recorded below as open decisions rather than silently applied.

### The proof the new exit-status aggregation works

`cobra`'s `nmbd.service` (Samba NMB) had been dead since **2026-08-09 21:41** — it lost a boot race (`No local IPv4 non-loopback interfaces available`, 90 s start timeout) and stayed failed for 3 days. The evidence is a clean before/after in `~/.logs/system_health_check.log` on cobra, same host, same fault, 15 minutes apart:

| Time | Script | Result |
|---|---|---|
| `18:30:03` | old (pre-deploy) | `Notification sent: No` |
| `18:45:03` | new (post-deploy, **cron's own run**) | `Sending notification to Slack (ALERT)` → `Notification sent: Yes` |
| `18:46:57` | after `systemctl restart nmbd` | `Sending notification to Slack (MONITORING)` → recovery notice, `no issues` |

That satisfies B5's "force one real failure and watch `#home-alerts`" with a *real* fault rather than a synthetic one, and it exercises the alert **and** the `--notify-fixed` recovery path. `nmbd` is running again and cobra exits 0.

⚠️ **Two things this exposes, neither fixed:**
- **`cobra` defines no `critical_services`**, so `check_services` never probed `nmbd`. The *generic* `systemctl --failed` check is the only reason it was ever seen. Any service on any host that is not in an inventory `critical_services` list is covered only by that generic check.
- **`nmbd.service` already has `Wants=`/`After=network-online.target`.** The ordering is correct; `network-online.target` simply completed before an IPv4 address existed. It succeeded on 5 of the 6 boots in the journal, so this is an **intermittent boot race that will recur**, not a misconfiguration. A `Restart=on-failure` drop-in would mask it cheaply.

Also confirmed live: the `FAILEDUNITS` `●` parse bug documented above. Iterating `systemctl --failed --no-legend` on cobra yielded `Invalid unit name "●"` — the bullet *is* `$1`, exactly as predicted.

### Verified, per step

| Step | Result |
|---|---|
| **B1** dockassist crons | `changed=1` → `changed=0`; live crontab reads `--heartbeat-interval=always`; the three container-check lines showed **no diff**. Logs: 0 × `mv: cannot stat`, all three `Notification sent: No`. Scoped — see below. |
| **B2** `adm` group | `changed` on **exactly** cwwk / unifi-lxc / agent-lxc, `ok` on the four Pis, `changed=0` on re-run. Verified *functionally*, not just by group membership: all three now `ls /var/log/unattended-upgrades` successfully and the check yields a real parsed value, `Last upgrade: 2026-08-13`. |
| **B3–B5** monitoring | All 7 Debian hosts exit **0**. Directory task `ok` everywhere. dockassist/unifi-lxc `changed=0` on the B5 pass, confirming B3/B4 converged. `check_link_speed` live (`eth0: 1000Mb/s full` on cobra). |
| **B6** opnsense | **13** crons under `/home/choco/.scripts`, **9** `/usr/local/bin` refs — all 9 confirmed to be `/usr/local/bin/bash`, the interpreter. All 14 referenced paths executable, `/usr/local/bin` back to `root:wheel`. |
| **B7** cwwk | `Automatic-Reboot "False"`, **3** `Automatic-Reboot` lines not 4. Second run `changed=0` — the removed render timestamp working, which was never true before. |

**B6 was verified by execution, not by inspection.** A full cron line was run end-to-end from the migrated path — `/usr/local/bin/bash …/.scripts/enhanced_monitoring_wrapper … .scripts/monitoring/check_dns_health.sh` → `exit code: 0`, `OK: DNS resolving via VPN (4/4 resolvers active)`. **B7 likewise**: `apt-config dump` was read, so the value APT *parses* was confirmed, not merely the file's contents.

### 🔴 §1a's opnsense acceptance criterion cannot be met by this deploy — the script is not deployed there

The handover states that post-merge opnsense "should exit 0 with those lines gone or downgraded — that is L-B's acceptance criterion". **It does not apply.** `deploy_monitoring.yml:44` excludes `system_health_check.sh` from FreeBSD by `when:`, and `:48` actively removes it (`state: absent`). Verified on the host: `/home/choco/.scripts/system_health_check.sh` → **No such file**, and `crontab -l | grep -c system_health_check` → **0**. opnsense runs the separate `check_system_health.sh`, which reports load correctly (`Load: 0.38` at 18:51 — the window where the old clock-parsing bug would have read `100%`) and exits 0.

**Consequence, and it cuts both ways:**
- ✅ The feared "opnsense pages every 15 minutes after the aggregation fix" was **structurally impossible** via this path. That gate was never real.
- 🔴 The §1a FreeBSD fixes — `freebsd_default_services()`, `freebsd_service_state()`, `read_load_1min()` — are **dormant code that runs on no host in production.** They were measured by running the script on opnsense *by hand*. They remain unexecuted in the live fleet and will stay that way until something deploys them there. Do not count them as verified-in-production.

### ✅ RESOLVED 2026-08-13 — `custom_origins` hook; both hosts converged without losing vendor patching

The decision below was taken the same session, once the vendor repo metadata was actually read instead of assumed. **The feature-upgrade fear was largely unfounded: three of the four vendor repos pin their major version in the suite**, so they can only ever deliver patches within a pinned line.

| Repo | Suite / pin | Can it jump major? |
|---|---|---|
| MongoDB | `a=bookworm/mongodb-org/**8.0**` | **no** |
| UniFi | `n=**unifi-9.4**` | **no** |
| Adoptium | `a=trixie`, package-pinned (`temurin-N-*`) | **no** |
| Plex | `a=public` — single rolling suite | **yes** |

So neither original option was right. `templates/debian/50unattended-upgrades.j2` gained a **`custom_origins`** hook mirroring the existing `custom_blacklist` one, and `cobra` / `unifi-lxc` set it in inventory. Both hosts now run the codified security-only template, the unbounded `"origin=*"` is gone, and vendor software still gets patched. **The other five hosts are `changed=0`** — the hook emits nothing where undefined, so it is provably inert.

🐛 **A real bug this surfaced, and it would have shipped silently.** `origin=Ubiquiti Networks, Inc.` **cannot work**: unattended-upgrades splits every pattern on commas to separate `key=value` pairs, and Ubiquiti's apt `Origin` literally contains one. Tested against the tool's own `match_whitelist_string()` on the host rather than by reading docs:

```
'origin=Ubiquiti Networks, Inc.'  ->  ERR:ValueError
'origin=mongodb'                  ->  repo.mongodb.org       MATCH
'origin=Artifactory'              ->  packages.adoptium.net  MATCH
'site=www.ui.com'                 ->  www.ui.com             MATCH
'codename=unifi-9.4'              ->  www.ui.com             MATCH
```

It does not merely fail to match — **it raises**. `site=www.ui.com` is used instead, which also keeps the 9.4 major pin in `sources.list` where it belongs rather than duplicating it into a second place that can drift. ⚠️ **General rule: any apt `Origin` or `Label` containing a comma is unexpressible via `origin=`/`label=` — use `site=` or `codename=`.**

✅ **Verified by what it yields, not by what it prints.** Every pattern in the rendered file was replayed through the real matcher on both hosts — each one either resolves to a real repo or is correctly inert — and `unattended-upgrade --dry-run -v` on `unifi-lxc` then found a genuine pending vendor update, **`mongodb-database-tools 100.18.0`**, a patch inside the pinned 8.0 line. Under the plain security-only template that package would never have been offered. cobra is clean with nothing pending.

<details>
<summary>The original two-way decision (historical)</summary>

### 🟡 OPEN DECISION — B7 deferred on `cobra` and `unifi-lxc` (drifted `50unattended-upgrades`)

B7's gate says "every Debian host changes one header line; cwwk the header plus line 43; **anything else is a surprise; stop**." Five hosts matched exactly. Two did not, and the gate was obeyed:

| Host | Diff | What it would do |
|---|---|---|
| `unifi-lxc` | **+6 / −27** | drops the `"origin=*"` catch-all and the MongoDB / GlennR / Adoptium origins |
| `cobra` | **+37 / −41**, plus `20auto-upgrades` **+1 / −17** | drops `"origin=*"` and the Plex origin; normalises `Automatic-Reboot "true"` → `"True"` and adds `-WithUsers "false"` |

Both carry a template stamped `Generated by Ansible - 2025-10-12` — the same October provenance as `unifi-lxc`'s `sshd_config` drift. The repo template is **security-only by design** (`// SECURITY UPDATES ONLY`), and the other five hosts already have it.

🔑 **The trade-off, flagged rather than decided.** Third-party vendor repos do not publish a `Debian-Security` label, so converging these two means their vendor software gets **no automatic patching at all** afterwards. Measured live:

- `cobra` → `repo.plex.tv` (Plex Media Server)
- `unifi-lxc` → `www.ui.com` (UniFi), `repo.mongodb.org`, `packages.adoptium.net` (Java)

Against that: `"origin=*"` means those two hosts currently auto-install **feature** upgrades unattended at 04:00 — a MongoDB or UniFi major bump landing on its own, followed by an auto-reboot, is a real availability risk on the network controller. Neither option is obviously right; it is a policy call, not drift cleanup, and it does not belong inside a monitoring deploy. **Deferred deliberately — decide, then run `--tags updates` on those two.**

</details>

### 🟡 OPEN — B1 was scoped to `--tags cron`; the untagged run has three unrelated side effects

The handover's B1 command is `services.yml --limit dockassist` untagged. Its dry run produced `changed=9`, of which **one** was the wanted cron fix. `--tags cron` produces `changed=1` and covers B1's entire acceptance criterion (all four cron tasks carry the `cron` tag), so that is what was deployed. The other eight are pre-existing and still true of any untagged run on dockassist:

1. **It upgrades Home Assistant** (`force_source: true` on `:stable`). → tracked below.
2. **It recreates the `home-assistant` container every single run.** → tracked below.
3. ✅ **It would break MQTT persistence — FIXED 2026-08-13, same session.** `mqtt.yml` set `{{ mosquitto_data_dir }}/data` to `owner/group: {{ ansible_user }}` (1000). Measured live: that directory is **`1883:1883`** and holds `mosquitto.db` (`0600 1883:1883`). The broker runs as uid 1883 and autosaves by writing a temp file and renaming, which needs **directory** write — so a choco-owned `0755` data dir silently fails every persistence write. **Root cause read from the image, not guessed:** the entrypoint runs as root and does `[ -d "/mosquitto/data" ] && chown -R ${PUID}:${PGID} /mosquitto/data`, and **only that path** — which is exactly why `config` beside it is `1000` and `data` is `1883`. The container therefore wins *at container start*, so the damage window is from an Ansible run until the next restart, unbounded. `data` is now split out of the loop with `owner/group: "1883"`, mirroring the existing `passwd` task. `--tags mqtt` now reports `ok` on it.

### 🐛 Found while fixing the above — `'CHANGED' in 'UNCHANGED'` is `True`

`mqtt_ha_integration.yml` guarded its injection script with:

```yaml
changed_when: "'CHANGED' in ha_mqtt_inject.stdout"
```

The script's two outcomes are `CHANGED` and `UNCHANGED`, and **`CHANGED` is a substring of `UNCHANGED`** — so the test was true in both branches. The task reported `changed` on every run and fired its `notify: Restart Home Assistant` handler each time. **Every `services.yml` run on dockassist has been restarting Home Assistant since MQTT landed on 2026-07-12**, while the script itself correctly did nothing.

**Proven by file mtimes, not by reading the code.** After two runs at 19:08, `core.config_entries` was still stamped `2026-08-12 11:21` and `core.config_entries.pre-mqtt.bak` `2026-07-12 19:52` — the script never wrote, so it had printed `UNCHANGED` both times while Ansible called it `changed`. Exactly one mqtt entry exists (`title localhost`, `port 1883`), so the *outcome* was always correct; only the signal was wrong.

⚠️ **`no_log: true` is why nobody saw it** — it hides the stdout that would have shown `UNCHANGED` beside a green `changed`. Fixed to an exact comparison, `ha_mqtt_inject.stdout.strip() == 'CHANGED'`, and verified in both directions: `changed=0` with no handler, and HA's `StartedAt` unchanged across the confirming run.

**General shape worth carrying:** a `changed_when` that substring-matches its own negative case. Anywhere a script reports status as a word, compare the whole value — this is the same "verify what the parse *yields*, not that the pattern matched" rule that the monitoring work keeps re-learning.

### 🟡 Minor — `RECOVERY.txt.j2` re-renders forever

`platform/proxmox` → `/home/choco/.scripts/RECOVERY.txt` embeds `Generated: <timestamp>`, so cwwk reports `changed` on **every** `deploy_monitoring.yml` run in perpetuity. Identical wart to the one B7 just removed from `50unattended-upgrades.j2`; same fix. Noise in a place where "a `changed` is a finding" is the working rule.

(The same run legitimately added **CT 103 / agent-lxc** to `RECOVERY.txt` and `vm_ct_config.txt` — first time the recovery kit has known about the agent container.)

### ⚠️ `read_agent` on opnsense is still broken — confirmed again, not retried

`ssh opnsense-agent` → `Permission denied (publickey)`, matching the Priority 2 recurrence triaged 2026-08-11 and contradicting the handover's "verified working 2026-08-07". **Attempted exactly once and then abandoned** — repeated failed auth against the firewall is what fed CrowdSec on 2026-08-03. All opnsense work in this session went through Ansible as `choco` instead, which works fine.

---

## dockassist — `services.yml` is not idempotent, and a deploy can silently upgrade Home Assistant

**Risk:** Medium — no data loss, but every untagged run recreates the HA container, and any run may bump HA's version with no decision and no record. Raised 2026-08-13 during L-B, **deliberately deferred** rather than fixed, because the two halves are coupled and one of them is a decision.

Same class as the `changed_when` substring bug fixed in `4d9b962` — silent, unnecessary container churn on every deploy — but heavier, because this is a **recreate plus a possible version change**, not a restart.

### The two halves

| # | What | Kind |
|---|---|---|
| 1 | `Pull Home Assistant Docker image` uses `force_source: true` against `:stable` (Cloudflared `:latest` and Matter `:stable` likewise), so a deploy pulls and can upgrade HA | **decision**, not a bug |
| 2 | `Create and start Home Assistant container` declares the volume as `…:/config`; Docker reports `…:/config:rw`, so `community.docker.docker_container` never matches and **recreates every run** | plain bug, one character |

### Why they can't be split

Both tasks carry `tags: [homeassistant, docker]`, so there is **no tag selection that exercises #2 without also running #1's pull.** Verifying the one-character fix therefore risks performing an HA version upgrade as a side effect. Fixing #2 alone and committing it unverified is the "written but not verified" state this repo keeps getting bitten by, so they move together or not at all.

⚠️ Note #2's fix only buys idempotency **when the image has not moved** — if #1 pulls a new image, `docker_container` correctly recreates regardless. So #1 is the one that decides whether deploys are quiet.

### The decision #1 needs

The role **already ships a dedicated upgrade path** — an `update_ha` management script plus a `Configure Home Assistant update cron job` task. If that is the intended mechanism, then `force_source: true` inside the deploy role is redundant with it, and a monitoring or MQTT deploy being able to bump HA's version is an accident rather than a design. Dropping `force_source` (pull only when absent) would make upgrades happen solely through `update_ha`.

**Not decided here** — whether a deploy should be able to upgrade HA is an operator call.

### Acceptance

- `services.yml --limit dockassist` (untagged) reports **`changed=0`** on a second consecutive run.
- HA's `StartedAt` is **unchanged** across that run — the same check that proved `4d9b962`, and the only one that distinguishes "reported ok" from "did nothing".
- Whatever is decided for #1 is written down, so the next reader knows HA upgrades are (or are not) a deploy side effect by design.

**Until then:** prefer `--tags` on dockassist. `--tags cron`, `--tags mqtt` and `--tags config` are all known-clean and were used throughout L-B.

---

## agent-lxc — Tier 1/2 monitoring never ran for 12 days (ROOT CAUSE FIXED; codify + cleanup pending)

**Risk:** High — silent blind spot. The fleet observer has produced **zero** output since it was built (2026-07-22). Nothing alerted, because the thing that would alert is the thing that is broken. Discovered 2026-08-03 only because the absence of reports was noticed by hand.

### Confirmed (2026-08-03)
- CT 103 is running, `cron.service` active, crontab installed and byte-for-byte what the role intends (all 5 jobs).
- **Exactly one Slack message ever** from `agent-lxc`: 2026-07-22 09:06, and that was the `/tmp/fleet_synth.sh` synthetic test (threshold forced to 1%). The real crons have never posted anything.
- **Zero SSH connections** from `10.30.40.203` to `dockassist`/`hifipi`/`cobra` — grep proven capable against the same journals (51 `Accepted` lines). Tier 1 has never reached a single host.
- `~/.logs/` **did not exist**. Every cron redirects `>> {{ logs_dir }}/*.log`; a shell that cannot open a redirect target fails *before* executing the command. Silent, permanent, unlogged.
- Egress/DNS/`choco` account/`/tmp` perms/`cron.allow`/spool perms all verified healthy — none of them are the cause.

### Fixed on branch `fix/agent-lxc-logs-dir-2026-08`
- `roles/services/agent` now creates `logs_dir` itself instead of assuming `deploy_monitoring.yml` ran. Only that playbook and two platform roles created it; agent-lxc is the first host with entirely role-owned monitoring, so it was the first deployed without one.
- Seeds `.last_slack_ts` on first deploy. Without it the Slack watch falls back to `oldest=0`, pulls the last 50 messages of #home-alerts, and burns Tier 2 budget investigating resolved alerts — worse, the agent's first-ever report would describe a fault that no longer exists.

### Verified fixed (2026-08-03) — end to end, on a real failure
`mkdir -p ~/.logs` applied by hand at ~14:12. Cron had been executing on schedule all along; the redirect was killing every job before it started. **The missing directory was the entire root cause.**

Proven, not inferred:
- **14:15:03** — first-ever real monitoring message in #home-logging (`System Health Check`, SUCCESS, `Host: agent-lxc`), on the next `*/15` tick.
- **14:37:01** — Tier 1 sweep ran, SSH fan-out confirmed on all six checkable hosts by counting `10.30.40.203` in each host's own sshd journal (independent of anything the agent reports about itself).
- **14:37:16** — sweep found a genuine issue, exited 1, and the wrapper posted `:x: ALERT` to **#home-alerts** (the watched channel). The alert path is verified against a real fault, not a synthetic one.

⚠️ **This fix is manual and lives only on the box.** The branch codifies it, but until that is deployed a rebuild recreates the outage.

### Not the cause — but real, and worth its own work
The container's systemd is badly broken: **19 failed units**, including *every* mount unit (`tmp.mount`, `run-lock.mount`, `dev-mqueue.mount`) and all four `systemd-tmpfiles-*` services. `systemd-journald` and `systemd-tmpfiles-setup` both exit `243/CREDENTIALS` — systemd cannot set up its credentials tmpfs, i.e. the container cannot mount filesystems. Likely an LXC capability/config issue (unprivileged + newer systemd).

This did **not** cause the outage — cron works fine. But dead `journald` is *why the outage hid for 12 days*: cron's record of what it ran and why it failed goes nowhere, and `/var/log/syslog` has been 0 bytes since 2026-07-14. A monitoring host that cannot log will keep failing invisibly.

### The agent got itself banned by CrowdSec within 10 minutes of working (2026-08-03)
The moment Tier 1 started working it found `opnsense: UNREACHABLE (no response as read_agent)` — a real, pre-existing key failure. Tier 2 then fired at 14:47 to investigate **that finding**, which meant OpenCode repeatedly SSH'd at opnsense and failed publickey auth every time. OPNsense runs CrowdSec; a burst of failed SSH auth from `10.30.40.203` is textbook ssh-bruteforce, so **CrowdSec banned the agent container**. Since OPNsense *is* the gateway, the container lost everything beyond its own L2 segment.

Symptom shape, for next time: same-segment hosts reachable (cobra pings in 0.3 ms), everything routed dead; gateway ARP entry `REACHABLE` but ping to it 100% loss (L2 fine, L3 filtered); **survives a full container reboot** — which is the tell that the block is not in the container. Diagnosed by comparing a same-segment host against an off-segment one; the container itself looked perfectly healthy throughout (0.065% CPU, 187 MB/2 GB, 15 processes).

Cleared with `cscli decisions delete --ip 10.30.40.203` on opnsense.

**This is a feedback loop, not a one-off.** While `read_agent` is broken on opnsense, every sweep finds it, every Tier 2 run attacks it, and CrowdSec re-bans. Broken for now by removing the Tier 2 anomaly cron (manual — see ⚠️ below). Permanent fixes, in order of value: (1) restore `read_agent` on opnsense, (2) whitelist fleet IPs in CrowdSec so the infrastructure cannot ban itself, (3) have `fleet_health_check` back off a host that fails auth rather than retrying it hourly.

#### ✅ (3) DONE in code 2026-08-06 — the loop is broken at both ends

Branch `fix/agent-lxc-logs-dir-2026-08`. Covered by `tests/unit/ssh_backoff_test.sh` (17 assertions, laptop-only, no spend); 8 of them fail against `main`.

- **Tier 1 backs off.** `ssh_probe` now captures stderr instead of discarding it, because "the far side refused our credentials" and "the far side is not there" are distinguishable only there. A rejection records `~/.agent/ssh_backoff/<host>` and suspends probing for a doubling window — 1h, 2h, 4h, capped at 6h (`agent_ssh_backoff_{base,max}_seconds`). A successful probe clears it.
- **Scoped to rejected auth, deliberately.** A host that is merely down logs no failed auth and trips no IPS; backing off from it would blind the sweep for nothing. Tested both ways.
- **It reports without connecting.** The finding still fires on every sweep — only the TCP connection stops. Silence would be the wrong fix; the human must keep being told.
- **Tier 2 will not investigate a host it cannot log into.** If every finding in the snapshot names a backed-off host there is nothing the agent could gather — its only tool is `ssh <host>-agent` — so `investigate.sh` exits 0 without launching OpenCode. When *some* findings are reachable it runs, with a "Hosts you must NOT connect to" block appended to the prompt naming the rest. `infra-monitor.md` gained a matching hard rule.

⚠️ **The two fixes are coupled, and the coupling is easy to break.** The back-off finding's wording is deliberately constant across sweeps. Put a timestamp or a retry counter in it and the snapshot content changes every hour, which silently un-fixes the dedup below. `ssh_backoff_test.sh` asserts the two sweeps produce byte-identical text for exactly this reason.

Still open from that list: (1) opnsense `read_agent` durability, and (2) a CrowdSec whitelist for fleet IPs. The back-off makes the loop survivable, not impossible.

### Tier 2 has never completed a run — and the earlier cost warning was wrong
`investigate.log` shows every Tier 2 run ending `rc=124 — opencode timed out after 600s and was killed`, `run cost: $0`, at 14:47 / 15:47 / 16:47. It never reached the Anthropic API because the CrowdSec ban had cut its network. **Actual spend to date: $0**, not the $7–13/day estimated from the re-billing bug below. That estimate was wrong in the reassuring direction — but the bug is real and simply never got the chance to fire. Tier 2's true cost and correctness remain **unmeasured**: it has not once produced a successful investigation.

Each failed run still burns 10 minutes of the container's single CPU on a hung `opencode`, hourly.

### ⚠️ Manual state on the box, not yet codified (2026-08-03)
- `mkdir -p ~/.logs` — the actual outage fix. Codified on this branch; **deploy it or a rebuild reproduces the outage.**
- Tier 2 anomaly cron **removed by hand** to break the CrowdSec ban loop (backup at `/root/crontab.choco.bak.20260803` inside CT 103). Any `services.yml --tags agent` run restores it — do not deploy until opnsense access is fixed.
- `pct set 103 --features nesting=1` — see below. Persisted in the CT config, not in this repo; nothing in Ansible manages container features.

### systemd breakage fixed — enable nesting
The 19 failed units (`journald`, `tmpfiles-setup`, every mount unit, all `243/CREDENTIALS`) were a missing `nesting=1` feature flag. Proxmox says so itself on reboot: `WARN: Systemd 257 detected. You may need to enable nesting.` After `pct set 103 --features nesting=1` + reboot, `systemctl --failed` returns **0 units** and `journald` is active — cron execution is finally visible in the journal.

Consequence worth noting: while journald was dead, **fail2ban was blind**, because its sshd filter reads `_SYSTEMD_UNIT=ssh.service` from the journal. `Currently banned: 0 / Total failed: 0` meant "no visibility", not "no attacks". Any host with a dead journald has decorative fail2ban.

**Now codified** (`provision_agent_lxc.yml`): `--features nesting=1` on create, an idempotent `pct set` for existing containers, and — the more important half — the playbook now **fails the build on any failed unit after boot**. It previously accepted `degraded` by design (`failed_when: ... 'degraded' not in stdout`), which is precisely how a container with 19 failed units passed provisioning and stayed broken for weeks. "Finished booting" and "booted healthy" are different questions; it now asks both.

### ✅ Cost bug — FIXED IN CODE 2026-08-06 (a persistent fault was re-investigated, and re-billed, every hour)

Branch `fix/agent-lxc-logs-dir-2026-08`. `fleet_health_check.sh` now builds the snapshot in a temp file alongside the real one and replaces it — atomically, by rename — **only when the findings differ**. The `timestamp` line is excluded from that comparison, because it changes on every run by construction: comparing whole files would have left the guard exactly as dead, in a subtler way. So the snapshot's mtime tracks "new information" rather than "the sweep ran", which is what `investigate.sh`'s `-nt` guard always assumed it did.

Covered by `tests/unit/anomaly_dedup_test.sh` — 8 assertions, laptop-only, no container and no spend. It asserts the *exact* predicate Tier 2 uses (`[ "$ANOMALY_FILE" -nt "$MARKER" ]`) rather than "the file was not written": a fix that wrote the file with a stale mtime would pass the weaker test and still fail in production. 3 of the 8 fail against `main`, including the whole-file-comparison trap.

Both mtimes in that test are set explicitly with `touch -t`. Letting them land in the same second would make `-nt` false for the wrong reason and pass vacuously — the same class of structurally-guaranteed non-result as the "declared broken 1 minute into a 60-minute cron cycle" note above.

Original diagnosis, kept:

#### ⚠️ Cost bug — a persistent fault IS re-investigated (and re-billed) every hour
`investigate.sh` gates on `[ ! "$ANOMALY_FILE" -nt "$MARKER" ]`, with the stated intent that "a persistent fault isn't re-investigated (and re-billed) every hour". But `fleet_health_check.sh:225` rewrites `last_anomaly.json` **unconditionally on every sweep that finds anything** — so its mtime advances hourly, the guard never engages, and Tier 2 re-investigates the identical finding every hour. The `--slack` path has proper content-dedup (7-day, signature-based); this path has none.

Live exposure right now: opnsense is unreachable (below), so the sweep finds it every hour. At the repo's own figure of ~$0.30–0.55 per investigation that is roughly **$7–13/day** until opnsense is fixed. Also `SEND_TO_ALERT=true` on every failure with no dedup or cooldown (`enhanced_monitoring_wrapper:384`), so it is 24 push notifications/day to #home-alerts alongside the spend.

**Fix:** write `last_anomaly.json` only when its *content* changes (compare against the previous file and skip the write if identical), so mtime tracks "new information" rather than "sweep ran". Content-hash dedup like the `--slack` path is the better long-term shape.

**Until fixed:** either resolve opnsense access (removes the finding), or temporarily remove the Tier 2 anomaly cron.

### Next Steps
1. **Deploy the branch** so `logs_dir` is codified and the hand-made directory stops being load-bearing.
2. Fix the container's systemd/mount breakage (needs root on CT 103; `pct exec` is deliberately not in read_agent's sudo allowlist).
3. Restore `journald` — the observability gap that made this a 12-day outage instead of a 1-hour one.
4. Re-run `agent_access` against agent-lxc: it is missing `/usr/local/bin/agent_read` (commit `067bba5`) that every other host has. That helper reads exactly the logs that were needed here, and its absence is why this could not be diagnosed remotely.

### Process note — how this was nearly misdiagnosed
After the manual fix, the sweep was declared "still broken" on the basis of zero SSH connections. That check ran ~1 minute after the directory was created, against a Tier 1 job that runs at `:37` — no cycle had occurred yet. The negative result was structurally guaranteed and proved nothing. **Before concluding a fix failed, confirm at least one scheduled cycle has actually elapsed.** A check that cannot yet have fired is not evidence of anything.

### Acceptance Criteria
- [x] A monitoring message appears in #home-logging tagged `Host: agent-lxc` — 2026-08-03 14:15:03
- [x] `fleet_health_check.sh` (Tier 1, `:37`) produces SSH connections from `10.30.40.203` on all fleet hosts — verified 14:37 from each host's own sshd journal
- [x] Alert path proven on a real fault — `:x: ALERT` in #home-alerts at 14:37:16 (opnsense unreachable), not a synthetic test
- [x] `systemctl --failed` on CT 103 is empty, `journald` active, cron execution visible in the journal — after `nesting=1`, 2026-08-03 17:02
- [ ] `logs_dir` codified in the role and deployed, so the manual `mkdir` is no longer load-bearing
- [ ] Tier 2 completes one successful investigation (never yet achieved — all runs timed out at 600s)
- [x] The re-billing bug is closed, and the ban loop has a back-off — in code 2026-08-06, both covered by unit tests that fail against `main`
- [ ] Tier 2 anomaly cron restored (`/root/crontab.choco.bak.20260803` on CT 103), after the branch is deployed. **No longer blocked on opnsense access:** the back-off means a host that rejects the key is reported, not attacked. Restore it and watch the first real run — cost and correctness are still unmeasured.

### Incidental findings (this session)
- **`roles/services/unifi` has the identical latent bug** — three crons redirect into `logs_dir` (lines 168/183/199) and the role never creates it. `unifi-lxc` is unaffected today because its `.logs` predates the role, but a rebuild reproduces the agent-lxc outage exactly. Same one-task fix; not applied here (out of scope for this branch).
- `deploy_monitoring.yml` tags its logs-dir task `[monitoring, logs]` but its scripts task `[monitoring, scripts]`. A run with `--tags scripts` deploys scripts into a directory it silently skips creating. Plausible (unverified) explanation for how agent-lxc ended up with all six `scripts/common/` files and no `.logs`. **Confirmed and reproduced 2026-08-04** — see the Priority 2 entry below.
- **The agent role had the identical tag gap, found 2026-08-06 while fixing the above.** Its `Ensure agent log directory exists` was tagged `[agent, monitoring, logs]` while the cron writing into that directory was `[agent, monitoring, cron]`, so `--tags cron` installed a crontab redirecting into a directory the same run declined to create — the 12-day outage reachable through a second door on the very host it happened to. Fixed on `fix/agent-lxc-logs-dir-2026-08`: the directory task now carries `logs`, `scripts` **and** `cron`. Verified with `--list-tasks` under a static `roles:` include, since `--list-tasks` cannot see through the `include_role` that `services.yml` uses. **General rule, worth applying to any new role: the task that creates a directory carries every tag that writes into it.**
- `system_health_check.sh` on agent-lxc reports `❌ Upgrade log not found - unattended-upgrades may not be configured`, but `/var/log/unattended-upgrades/` exists and is populated. The probe increments `issues_found` without failing the run, so it will show a red ❌ in every daily heartbeat without ever alerting. Cosmetic, but it trains the eye to ignore red.
- Whole fleet rebooted 2026-07-31 ~13:45 (every host "up 2 days" on 08-03). Unexplained; predates nothing here (agent silence started 07-22) but worth knowing.
- `touchid-agent` refuses non-interactive signing from an agent shell (`agent refused operation`), so Ansible runs against hosts without an `-agent` alias must be driven by hand.

### Incidental findings — Tier 2 session, 2026-08-06

- **The agent's `.j2` shell scripts are now unit-testable on the laptop.**
  `tests/lib/render_j2.py` renders the small Jinja subset these templates use
  (`{{ var }}` plus the one `agent_fleet_hosts` loop) with no jinja2 import —
  the system python3 on macOS has none, and pulling a dependency into a shell
  suite to substitute four variables is a poor trade. **It exits non-zero on
  any construct it does not understand**, rather than leaving literal `{{ … }}`
  in a script the test then "passes" against. Both new tests render, stub
  `ssh`, and run the real script: no container, no fleet, no spend. Verified
  under `dash` on CT 199 as well as on the laptop, since `/bin/sh` on macOS is
  bash in POSIX mode and is more permissive than what agent-lxc actually runs.
- **`run_and_report` must not be piped into.** It sets `AGENT_RC`/`AGENT_COST`
  that its callers read *afterwards*, and the right-hand side of a POSIX
  pipeline is a subshell, so `{ …; } | run_and_report` leaves them unset — with
  `set -u` the digest's `exit "$AGENT_RC"` then dies. Prompts are therefore
  assembled into a file and redirected. Anyone adding a fourth mode will hit
  this; the alternative (unquoting the heredocs to interpolate) is worse, since
  the digest prompt contains backticks that would then execute.
- **A JSON fixture built with `echo` is not portable, and fails silently.**
  bash's `echo` leaves `\n` alone while dash's expands it, which put real
  newlines inside a JSON string, made the event unparseable, and made the
  stubbed agent look like it had "exited 0 but produced no text". The test still
  passed, because the assertion only checked that the agent had been *invoked*.
  Two lessons: fixtures that are data use `printf '%s\n'`, and an assertion
  about a happy path must check the run **succeeded**, not merely that it
  started.
- **macOS has neither `flock` nor `timeout`**, both of which `investigate.sh`
  uses. The tests stub them unconditionally so a laptop run and a container run
  exercise the same thing. Neither is under test; if either ever is, it needs a
  container.

#### The back-off's trigger, checked against real ssh output rather than a fixture

The back-off fires on a string match against ssh's stderr, which is exactly the
"verify what the parse *yields*, against real captured output" trap. So it was
checked against real output, not against the strings the test stubs emit:

| Condition | Real stderr | Matches? | Wanted |
|---|---|---|---|
| Rejected key (bogus key → CT 199) | `Permission denied (publickey,password).` | ✅ | back off |
| Host absent (unused address) | `ssh: connect to host … port 22: Operation timed out` | ✅ no match | keep probing |

The matched substring — `Permission denied` — is emitted by the **ssh client**,
not by the server, so it does not depend on opnsense's sshd config or on which
auth methods it advertises. That is what makes this portable across the fleet.

⚠️ **It has still never fired against opnsense's actual failure mode** (the
`read_agent` account deleted by config regeneration). If that produces some
other text — `kex_exchange_identification`, a banner, a timeout — the match
fails and the host is reported `UNREACHABLE` instead, which is **today's
behaviour**. The failure direction is fail-open: a missed match costs the
back-off, never a false one. Worth confirming when opnsense next drifts, which
this file says it will.

**The cheap version of that check, for whoever picks this up** — it confirms the
match from *inside* the fleet rather than from the laptop, needs no broken host,
and deliberately does not touch opnsense (the string comes from the ssh client,
so any Debian target proves it):

```sh
ssh cobra "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    nosuchuser@dockassist true 2>&1 | tail -1"
```

Expect `Permission denied (publickey)`. Anything else means the match needs
widening. One failed auth is orders of magnitude below CrowdSec's ssh-bf
threshold — verified 2026-08-06, when a deliberate failed auth from the laptop
produced no alert and no decision.

📌 **Corroboration, found while checking this.** `cscli alerts list` on opnsense
still holds the incident: `crowdsecurity/ssh-bf` against `10.30.40.203` at
`2026-08-03T12:47:12Z` — 14:47 local, exactly the Tier 2 cron minute. The
account of what happened is now confirmed from the firewall's own record, not
only from the agent's logs. No active decisions.

#### What an offline Jinja render can and cannot prove

Both templates were rendered through **real jinja2 with the real variable set**
(role defaults + `group_vars/agent.yml` + inventory + vault) and the output
parsed under `dash` on CT 199. The new knobs resolve to `3600` / `21600`.

But the render leaves `{{ vault_infrastructure_user | default(lookup('env',
'USER')) }}` unresolved in three places, and **that is a limit of rendering
outside Ansible, not a template bug**: Jinja evaluates `default()`'s argument
eagerly, and `lookup` is an Ansible plugin that does not exist in a bare
Environment. It is a pre-existing line (`group_vars/all/main.yml:14`, from the
initial migration), and agent-lxc's live crontab shows Ansible resolves it —
`/home/choco/.scripts/fleet_health_check.sh`. **Anything needing `lookup`,
`vault`, or a connection can only be proven by a real playbook run.**

---

## Monitoring gaps — what would actually have caught 2026-08-03

Asked after the fact: which check, if it existed, would have caught each failure? The answer for several of them is "one that already exists and does nothing."

### ✅ Status 2026-08-04 — items 1, 2 and 3 are FIXED IN CODE (not deployed)

Written and verified against a disposable Debian 13 LXC (CT 199), both directions: each fix's tests were also run against `main`, because a test that does not fail there proves nothing. **Nothing is deployed; no fleet host has been modified.**

- **`system_health_check.sh` exit status** — fixed, `tests/cases/health_*.sh`. Against `main` the suite reproduces the bug exactly: output reads `❌ Service cron: not running` immediately above `Health check completed`, exit status **0**. 4 of 5 cases fail on `main`, all 5 pass on this branch.
- **`systemctl --failed` check** — added in the same pass, covered by `health_failed_unit.sh`.
- **Slack watch watermark** — fixed, `tests/unit/slack_watermark_test.sh` (runs on the laptop, no container or network). Quiet poll returns `OK 0.000000` on `main` vs the preserved watermark here. **The fix is self-healing**: a non-positive watermark on disk is now treated as absent, so CT 103's poisoned `0.000000` recovers on its next run with no manual reseed.

⚠️ **The TODO's "one-line class of fix" framing for `system_health_check.sh` was wrong, in a way that mattered.** Six of the seven check functions had no `return` at all — only `check_auto_upgrades` did. Worse, `check_disk_usage` evaluated its loop inside a `df | grep | while` **pipeline, which POSIX runs in a subshell**, so counters incremented there are discarded when it exits. The obvious fix — add increments, sum at the end — would have left the disk check, the one most likely to fire, still returning 0 while printing a red ❌. Demonstrated rather than reasoned: identical input yields `issues=0` through a pipeline and `issues=2` through a here-doc. It now uses a here-doc. **Generalise this:** any `cmd | while` loop in this repo that accumulates state is silently discarding it.

**✅ Item 4, the healthchecks.io ping, is now FIXED IN CODE too (2026-08-06).** The "it needs laptop time" framing was wrong twice over: the check and the vault write were done remotely on 2026-08-04, and the ping itself needed neither. See the dead-man's-switch section below.

### ✅ Pending-reboot check — ADDED 2026-08-06 (not deployed)

`check_pending_reboot` in `system_health_check.sh`, aggregated like every other check. It exists to make `auto_reboot: false` on cwwk a *safe* trade rather than a downgrade: a kernel security update only takes effect on reboot, so switching off the unattended 04:00 restart without this swaps an unannounced reboot for an **unnoticed unpatched kernel**.

**Graded by age, deliberately — warning-only would have been the same mistake in a new costume.** A warning exits 0, the wrapper records SUCCESS, and the message lands in `#home-logging`, which is an unwatched firehose: indistinguishable from writing no check at all. So a pending reboot is a **to-do for 7 days and a fault after**, matching `check_auto_upgrades`' window. That leaves room to reboot the hypervisor at a chosen moment without a page, and stops "later" lasting a quarter.

- Reads `/run/reboot-required` (falling back to `/var/run/`), names the packages from `.pkgs` — the difference between "reboot sometime" and "you are running an unpatched kernel".
- Age comes from the flag's mtime. It lives on **tmpfs**, so the mtime is genuinely when the update landed and the file vanishes on reboot: no cleanup path, and no way for it to go stale.
- Guards what `stat` *yielded*, not that it exited 0 — an unparseable value evaluates to 0 in POSIX arithmetic, which would date the flag to 1970 and page instantly.
- Non-Debian returns 0 early. FreeBSD has no equivalent flag, and opnsense no longer receives this script at all.

`tests/cases/health_pending_reboot.sh` walks all three states — absent, fresh, and backdated 8 days — asserting the **exit status** in both directions, not just the output. Suite **9/9** on CT 199; **6 of its 7 assertions fail against `main`**. The one that passes there does so vacuously (main's script always exits 0), which is the reason the case asserts exit status on the fresh leg too.

### 🔴 The Slack watch self-destructs on its first quiet hour (root cause confirmed 2026-08-03)
`investigate.sh --slack` has been failing every hour with `ERR invalid_ts_oldest`. Confirmed cause — `/home/choco/.agent/.last_slack_ts` contains **`0.000000`**.

The embedded Python initialises `maxts = 0.0` and always emits `print(f"OK {maxts:.6f}")`. A poll that returns **zero new messages** therefore reports `OK 0.000000`. The shell then persists it:
```sh
[ -n "$_maxts" ] && [ "$_maxts" != "0" ] && printf '%s' "$_maxts" > "$SLACK_TS_FILE"
```
That guard exists to prevent exactly this, but it is a **string** comparison against `"0"` while Python emits `"0.000000"` — so it passes, and the watermark is clobbered. Every later poll sends `oldest=0.000000`, which Slack rejects.

**It cannot self-recover:** the watermark is only rewritten after a *successful* fetch, and the fetch now always fails. So the watch dies permanently the first hour nothing new arrives — i.e. almost immediately on a healthy fleet. Evidence in `investigate.log`: three `slack watch done; investigated 0 alert(s)` (the quiet polls), then unbroken `ERR invalid_ts_oldest`.

Corollary: **the Slack watch has almost certainly never worked in production.** The earlier worry that a fresh deploy would backfill 50 messages of #home-alerts was misplaced — it would have poisoned its own watermark and stopped instead.

**Fix (repo, not live):** initialise `maxts` to the `oldest` value the poll was made with, so an empty window *preserves* the watermark instead of resetting it; and make the guard numeric rather than a string compare against `"0"`. Reseeding the file by hand only buys one hour — the next quiet poll re-poisons it.

### 🔴 `system_health_check.sh` can never fail — every host, every 15 minutes, since forever
Each check function increments `issues_found`, and `check_auto_upgrades` even ends `return $issues_found`. But the main body just calls the functions in sequence:
```sh
check_uptime
check_disk_usage
check_memory
check_load
check_services
check_network
check_auto_upgrades

echo "=============================="
echo "Health check completed"
echo "=============================="
```
No aggregation, and **no final `exit`**. A script's status is that of its last command — here, `echo`. So it exits **0 unconditionally**, and `enhanced_monitoring_wrapper` only alerts on non-zero. This check has therefore **never alerted on any host, ever.**

Verified against the *deployed* copy on cwwk (via `agent_read`), not just the repo. Empirical proof from today: agent-lxc's 14:15 run printed `❌ Upgrade log not found - unattended-upgrades may not be configured` and the wrapper recorded `Status: SUCCESS / Exit Code: 0`.

What is silently uncovered on all 7 hosts: **disk usage, memory, load, ssh/cron/fail2ban being down, internet reachability, and auto-upgrade staleness.** The internet-reachability check is the one that would have caught today's CrowdSec cutoff within 15 minutes.

**Fix:** aggregate the function return codes and exit non-zero when any check fails. Then force each failure condition and watch it fire — the red ❌ output proves the *printing* works, which is exactly what made this invisible.

### ✅ No dead-man's switch on agent-lxc — FIXED IN CODE 2026-08-06 (not deployed)
Tier 1 checks that every host's monitoring ran recently (`agent_wrapper_max_age_hours: 26`) — but it runs *from* agent-lxc, so it cannot detect its own death. That is precisely the 12-day outage.

The mechanism already exists and is already in use: **healthchecks.io pings on proxmox, opnsense (WAN + DNS), homeassistant and pihole**. agent-lxc is the one host without one — the host whose silence was the entire failure. A ping from the Tier 1 sweep would have paged on day one.

**Fix:** healthchecks.io ping at the end of `fleet_health_check.sh`. Small, reuses existing infrastructure, and is the single highest-value item on this page.

**Done 2026-08-06.** `ping_healthcheck()` in `fleet_health_check.sh.j2`, one call site immediately before the report branches, driven by `agent_sweep_healthcheck_url` (role default → `vault_healthcheck_agent_sweep | default('')`). Check `agent-lxc Tier 1 fleet sweep`, period 1h, grace 25m — created and vaulted 2026-08-04.

Three decisions worth keeping, because each has a plausible opposite:

- **The ping is unconditional — it fires on a sweep that found problems.** Gating it on a clean sweep would stop the heartbeat the moment the fleet is unwell, conflating "the observer is dead" with "the fleet is broken", which are the two states this exists to separate. Findings already reach `#home-alerts` through the wrapper; this covers *silence*. ⚠️ Deliberately unlike `heartbeat_backup.sh`, which pings only on recent success — that one asserts a backup's freshness, not a run's existence.
- **The ping can never change the sweep's exit status.** `|| true` on both branches and `return 0`. A dead-man's switch that can fail the thing it watches is a liability; hc-ping.com being down is healthchecks' problem to alert on, not a fleet finding.
- **It lives inside the script, not in the cron line.** The 12-day outage killed the cron *at the redirect*, before the script was reached. A ping in the script therefore does not fire, which is exactly what should page. A ping appended to the cron line would have to survive the same redirect and might not.

Covered by `tests/unit/sweep_healthcheck_test.sh` — 12 assertions, laptop-only, no container and no network. **6 of the 12 fail against `main`**, including all three "pings at all" assertions. `sh -n` and `dash -n` clean on the Ansible-rendered output; variable resolution confirmed in agent-lxc's real scope (`connection: local`), not just in the test renderer.

⚠️ Two things this does **not** prove. The wget branch is unreachable on the deployed host — agent-lxc has both curl and wget (measured 2026-08-06), so it always takes the curl path; the test forces it only by building a curl-free `PATH`. And no ping has ever reached healthchecks.io from that container: **the first real ping happens at L5**, and its check goes from "new" to "up" then. Until then the check is armed and has never been fed.

### No check for failed systemd units
`check_services` tests three named services (ssh, cron, fail2ban). Nothing anywhere checks `systemctl --failed`. A container with 19 failed units — journald among them — passed every check it had.

**Fix:** add a failed-unit count to `system_health_check.sh` (after the exit-code fix, or it will be as inert as the rest).

### Design note — do NOT move local checks to agent-lxc
Tempting after today, but backwards. agent-lxc was itself the single point of failure, and centralising would have made the blast radius larger, not smaller. Local checks also see things a remote prober cannot (0700 homes, ALSA on hifipi, per-host service state).

The correct split is the one already in place, plus one missing piece:
- **local checks** stay local — they have the access
- **agent-lxc** does cross-host correlation — which it does well
- **an external watchdog** detects *absence* — the one thing neither a host nor agent-lxc can do for itself

Absence-detection is the actual gap, not check placement.

### Priority
1. Fix `system_health_check.sh` exit status — restores ~7 checks across 7 hosts, one-line class of fix, largest coverage gain available
2. healthchecks.io ping from the Tier 1 sweep — closes the watch-the-watcher hole
3. `systemctl --failed` check
4. Then the Tier 2 bugs (re-billing, retry guard)

---

## opnsense — `read_agent` access is broken (found by the agent's first real sweep)

**Risk:** Medium-high — the firewall is the one host neither the fleet observer nor autonomous diagnostics can see. Silent until now because the observer that would have reported it was itself dead.

**Confirmed 2026-08-03:** Tier 1's first real run reported `opnsense: UNREACHABLE (no response as read_agent)`. Verified independently from the Mac — `ssh opnsense-agent` returns `Permission denied (publickey)`. The host answers on 22, so it is the key/account that is broken, not the box. Note this fails from *both* the container and the laptop, so it is not specific to the agent-lxc identity — `read_agent`'s key is missing or wrong on opnsense generally.

`agent_access` runs `hosts: all` and has a FreeBSD sudoers template, so opnsense is in scope by design; it has simply drifted (same class as agent-lxc missing `agent_read`).

### Root cause: OPNsense deletes accounts it does not own — and will not give a non-admin a shell
The account was **gone entirely**, not merely missing a key. `sshd_config.d/10-read_agent.conf` survived from the 2026-07-22 Ansible run while the user did not: OPNsense regenerates system accounts from `config.xml`, so anything created by `pw` (which is what `ansible.builtin.user` uses) has a limited lifespan. The `agent_access` role's FreeBSD user task therefore reports `changed` and achieves nothing durable.

Worse, **OPNsense will not give a non-admin user a login shell at all.** From `src/etc/inc/auth.inc`:
```php
$is_admin   = userIsAdmin($user['name']);
$user_shell = $is_admin && !empty($user['shell']) ? $user['shell'] : '/usr/sbin/nologin';
// userIsAdmin() → userHasPrivilege(getUserEntry($username), 'page-all')
```
The only privilege that unlocks the shell is **`page-all` ("GUI: All pages") — full administrator**. There is no granular shell-access privilege. Granting it to a read-only monitoring account on the firewall is not an acceptable trade, so **do not**.

### Current state (2026-08-03, working but fragile)
- User + both authorized keys (with `from=` pinning) created via the OPNsense UI → stored in `config.xml` → **durable**, survives upgrades.
- Group `read_agent` (gid 2000, no privileges) created to satisfy `AllowGroups wheel read_agent`.
- Login shell set with `pw usermod read_agent -s /bin/sh` → **NOT durable**, lives only in `/etc/passwd` and reverts whenever OPNsense regenerates accounts.

Verified: `ssh opnsense-agent` works, and the 19:37 sweep returned SUCCESS across all 7 hosts — the first fully clean sweep since the container was built.

### Next Steps
- **Preferred: stop SSH-probing opnsense.** It is not a general-purpose host and it has a proper API. Monitoring it via a read-only API key removes the shell-durability problem *and* permanently eliminates the failed-auth → CrowdSec trigger. This is the architectural fix.
- Failing that: accept the `pw` shell as drift and rely on the sweep to detect the revert — it alerts within the hour, which is exactly how this was found. Note the alert repeats hourly with no dedup.
- Change `agent_access` on FreeBSD to **assert** the user exists and fail with a pointer to OPNsense user management, instead of creating one with `pw` and reporting success.

### Acceptance Criteria
- [x] `ssh opnsense-agent "uname -a"` succeeds from the Mac — 2026-08-03 19:38
- [x] Tier 1 sweep reports 0 issues across 7 hosts — 19:37:15 SUCCESS
- [ ] opnsense monitoring no longer depends on a shell that OPNsense will revert

---

## cwwk Thermal Stability — Root Cause + Headroom (mitigations deployed)

**Risk:** High operational impact — cwwk hosts the OPNsense firewall (VM 100, onboot), so a cwwk crash takes down all internet. Recurring silent resets.

### Root cause (investigated 2026-06-30)
cwwk hard-reset at 18:50 on 2026-06-30 with **no kernel log, panic, MCE, OOM, or thermal trip recorded** — the journal just stops mid-write. Whole fleet was fine (only cwwk dropped), no software/kernel/package change, temps/RAM/ECC/storage all clean. The smoking gun: `package_throttle_count` = **22,841** since the 18:51 boot (a healthy box reads ~0), proving the CPU repeatedly slammed Tjmax (105°C). Cause: girlfriend turned off the fan facing cwwk during a heatwave → thermal runaway → silicon-level **THERMTRIP** (instant power-off, leaves no log). Note: the per-event syslog throttle line is rate-limited/suppressed on this kernel, so *only the hardware counter* reveals throttling — instantaneous `sensors` reads a calm 56°C between throttle cycles. Distinct from the 2026-06-29 ~10:17 event, which was fleet-wide (real house power blip).

### Done — thermal logging (#2)
`save_temps.sh` (root cron `*/2`) logs temps + `package_throttle_count` + delta to `/var/log/diagnostics/thermal-history.log` (~3 days retained, 644 so read_agent can read it). Deployed + verified on cwwk. Fills the gap that made today's crash un-quantifiable. Role: `platform/proxmox`.

### Done — thermal headroom (#3, deployed 2026-06-30)
All as code in the `platform/proxmox` role (toggle `enable_proxmox_power_tuning`):
- **RAPL power cap:** PL1 (sustained) 35W → **20W**, PL2 (burst) left at 35W. Applied at boot via `cwwk-power-tuning.service`. Verified live: `PL1=20000000`, `PL2=35000000`. No throughput cost at 1 Gbps WAN.
- **Governor:** `performance` → **`powersave`** (intel_pstate; still boosts under load). Verified: all 8 cores `powersave`.
- **Dedicated thermal alert:** `check_thermal.sh` (cron `*/5`, via `enhanced_monitoring_wrapper` → #home-alerts) alerts on throttle-counter **delta**. Logic verified across OK/WARN/CRIT/reboot. Temp alerting moved out of `check_proxmox_health.sh` (no double-alerts).

### RECURRENCE — 2026-07-31/08-01 (second occurrence, same root cause)

**The 2026-06-30 root cause repeated, with a different trigger.** A house power outage on 2026-07-30 ~13:40 cut power to everything; when it returned (2026-07-31 13:45) the USB cabinet fan did **not** resume, because it requires a manual switch press after power-on. Combined with a Netherlands heatwave, cwwk has been throttling continuously ever since. Diagnosed remotely 2026-08-01 while away from home.

**Quantified (from `thermal-history.log`, 2160 samples spanning both states):**

| | fan OK (Jul 28 → Jul 30 13:40) | fan dead (Jul 31 13:45 → now) |
|---|---|---|
| pkg avg | 42–45°C | **67–70°C** |
| pkg peak | 50–60°C | **94°C** (1 Hz sampling) |
| throttle events | **0** across 3 full days | continuous |

- Throttle duty cycle is only **0.2%** (142s of throttling over 19.4h). `temp1_crit_alarm` never latched. Tjmax = 105°C — it is throttling gracefully, exactly as the PL1 cap was designed to make it.
- Throttling is **bursty, not sustained**: median 2-min delta = 4 events, p90 = 176, p99 = 1515, max = 4632 (03:04, during `pve-daily-update`). Roughly half the `*/5` check runs exceed `THROTTLE_WARN=20` → ~1 Slack alert per 10 min.
- **Heat is component-local, not cabinet-wide.** All Pis polled: hifipi 69°C, cobra/dockassist 56°C — **zero** under-voltage/throttle kernel events fleet-wide in 5 days, and these are consistent with the measured 26.5°C room ambient (Tado) rather than a heat-trapped enclosure. `vinylstreamer` read 45°C but **is not in the cabinet** — it is a house-ambient control, not a cabinet data point. Heatwave contributes ~+5–6°C to everything; fan loss contributes ~+20°C to the cwwk package alone.
  - ⚠️ **Superseded evidence:** an earlier version of this analysis argued "board ambient is only +1.3°C over room" from `acpitz` (27.8°C) and "NVMe flat at 35.9°C". **Both readings were later proven to be static stubs — see the Sensor reliability section below.** Cabinet air temperature is *unmeasured*. The component-local conclusion still holds, but rests on the Pi temperatures and room ambient, not on those two sensors.
- **No fire risk** — and this does *not* depend on the discredited sensors. Sustained package power is hard-capped by RAPL (PL1 20W, verified writable and enforced), the silicon self-protects by throttling at Tjmax 105°C and THERMTRIPping above it, and peak measured was 94°C with `temp1_crit_alarm` never latching. The worst realistic outcome is a clean power-off that takes OPNsense (and therefore all internet) with it — an **availability** risk, not a safety one.

**Conclusion:** the mitigations are working. The unfixed item is the fan, as already noted below since 2026-06-30.

### 2026-08-07 — THIRD thermal event, and the first one the fan did not cause

**There is still no fan** — the Noctua + mechanical controller bought 2026-08-02 is not yet fitted, so cwwk has been running passively since 2026-07-31. That is the standing condition, not the news. The news is that **a single runaway process on a guest was enough to hold the box at ~95°C for ten hours**, and nothing in the fleet's monitoring could see it.

**Sequence (measured, `thermal-history.log` + `procstat`):**

| Time | Event |
|---|---|
| 01:44:05 | `grep -rn 'forward-addr\|forward-zone\|10.64.0.' /var/unbound/` starts on the **OPNsense guest** as `read_agent` |
| 01:46 sample | cwwk `pkg` 76→92°C, `throttle_delta` 8→12,611, `load` 0.32→1.25 |
| 01:46 → 11:42 | `pkg` **sustained 94–96°C**, delta ~16,000 per 2 min, load flat ~1.2. Host `kvm` (PID 1594 = VM 100) at **109% CPU**; nothing else above 1% |
| 11:42 | process killed by hand |
| 11:44 | `pkg=74`, `throttle_delta=69`, `load=0.25` — recovery inside two samples |

**Why the grep never finished — verified, and it is platform-specific.** `procstat -f` showed fd 3 open on `/var/unbound/dev/random` at offset **181,681,487,872** (~169 GiB read). Unbound's chroot on OPNsense contains a **fully populated devfs** (`random`, `zero`, `null`, `mem`, …), and BSD `grep -r` descends into it and reads character devices as files. There is no EOF.

```
BSD grep 2.6.0-FreeBSD : grep -r over a device  → exit 124 (reads forever)
                         --devices=skip         → exit 1   (clean skip)
GNU grep 3.11 (Linux)  : grep -r over /dev      → exit 2   (skips devices already)
```

**So only the FreeBSD host is exposed to this shape** — which happens to be the internet SPOF *and* the guest of the fanless hypervisor. Both greps were run bounded with `timeout` to verify this; neither left anything running.

**Origin (inferred, not proven):** the parent `sh -c` ends with `echo '(empty = Unbound is NOT forwarding to Mullvad DNS)'`, which is the exact question behind network finding 1 (`monitor_dns_failover.sh` asserting a forwarding config that does not exist). Timestamp and subject both match the network-documentation session of 2026-08-07. Recorded because it motivates the guard below, **not** as a reason to narrow what agents may inspect — see the design note.

**What this says about the thermal picture — it does *not* overturn the fan conclusion:**

- Prior peak-load samples already touched 89–95°C (load 13.77 → 95°C, 2026-08-06 03:04). The box reaches that temperature transiently under bursts *and* under one permanently-pegged core; the difference today was **sustained vs transient**, not a new cooling fault.
- Steady-state with one core pegged, fanless, is therefore **~95°C**. That is the number to plan against, and it is 10°C from Tjmax.
- ⚠️ **Idle has settled at 74°C**, against 67–69°C on 2026-08-04→06. **Unverified** whether that is residual soak from a ten-hour heat load or a genuine ambient rise — re-read `thermal-history.log` before drawing anything from it.

**The drifted thresholds are now demonstrated, not theoretical.** At ~16,000 events per 2 min the `*/5` check computes a ~40,000 delta — landing exactly on the hand-applied `THROTTLE_CRIT=40000` and oscillating CRIT/WARN on nearly every run. That is the Slack spam. Temps of 94–96°C stayed *below* the hand-applied `TEMP_WARN=98`, so the alerts never mentioned temperature at all and pointed at "check fan/airflow" for ten hours while the cause was a stuck process one VM away. **This is a concrete argument for what to restore the thresholds to (see RESTORE ON RETURN below), and for the wrapper dedup work in Next Steps.**

#### 🔴 The monitoring gap this exposed — a fourth failure class

Every host already has CPU monitoring, in three separate implementations:

- `scripts/common/system_health_check.sh:106` `check_load()` — all hosts
- `scripts/services/opnsense/check_system_health.sh:42`
- `scripts/services/proxmox/check_proxmox_health.sh:102`

All three compute `load_1min / cpu_count × 100` against an 80% warn. **Normalising by core count makes a single runaway process undetectable by construction:**

| Host | Cores | Pegged cores needed to warn | Reading during the incident |
|---|---|---|---|
| `unifi-lxc` | 2 | 1.6 | — |
| Pis (×4) | 4 | 3.2 | — |
| `opnsense` | 6 | 4.8 | **17% — "healthy"** |
| `cwwk` | 8 | 6.4 | **16% — "healthy"** |

OPNsense reported a comfortable 17% while one of its six cores was pinned. **This is not a cwwk-vs-the-rest gap — no host in the fleet, cwwk included, has a check that can see one stuck process.** cwwk caught it only via `check_thermal.sh`, a *physical downstream symptom* two layers from the cause, and misattributed it.

This is a distinct shape from the three already tracked in this repo:

| | Class | Example |
|---|---|---|
| 1 | Check exists, is broken | the five false failures, 2026-08-06 |
| 2 | Nothing watches it at all | PVE package updates, OPNsense firmware |
| 3 | Check runs, reports success, protects nothing | `monitor_dns_failover.sh` — 9,359 green checks on a false premise |
| **4** | **Check exists, works correctly, and cannot cover the mode it appears to cover** | **`check_load()` — normalisation hides the single-process case** |

Class 4 is arguably the worst to audit for: the coverage *looks* present and the code is not wrong. It belongs to the "start from failure modes, make the blanks the deliverable" review already proposed after Phase C — this is that review's first **demonstrated** member rather than a reasoned one.

#### 🔴 The fan will REMOVE the only thing that detected this — plan for it before fitting it

**Raised by Ignacio 2026-08-07, and the arithmetic confirms it.** Right now `check_thermal.sh` is, by accident, the fleet's only runaway-process detector. It is a bad one — indirect, and it names the wrong cause — but it is the reason this incident was noticed at all. **Fitting the fan removes it and puts nothing in its place.**

Derived from measured values, not estimated:

| | Measured | Source |
|---|---|---|
| Fanless idle | **68.8°C** (1,837 samples) | `thermal-history.log`, Aug 4–6 |
| Fanless, one core pegged | **94.6°C** (290 samples) | the 2026-08-07 incident |
| **Cost of one pegged core** | **+25.8°C** | difference of the two |
| Fan-OK idle | **42–45°C** | RECURRENCE table, Jul 28–30 |
| **⇒ Fan-OK, one core pegged** | **≈ 68–71°C** | 43 + 25.8 |

Against repo `TEMP_WARN=85` and Tjmax 105°C, ~70°C is unremarkable — and the fan-OK baseline recorded **zero throttle events across three full days**. **So with the fan fitted, the exact incident of 2026-08-07 produces no throttle delta, no temperature warning, and no alert of any kind.** It runs indefinitely, silently.

*(The ≈70°C figure is conservative in the safe direction: dissipation scales with ΔT to ambient, so a cooler starting point sheds the same watts at a smaller rise. The real number is likely lower, which only strengthens the conclusion.)*

⚠️ **Generalise this — it is the actual lesson.** Every mitigation that widens a margin also removes the signal that the margin was being consumed. The RAPL cap did a milder version of this in June. A fix that makes an alert stop firing and a fix that makes the *fault* stop happening are indistinguishable from the alert stream alone — which is the "silencing an error is not fixing it" trap, arriving from the direction of a genuine improvement rather than a bad patch.

**Consequences, all of which change the order of work:**

1. **The runaway-process check stops being a nice-to-have and becomes the fan's prerequisite.** It is the replacement detector. Fitting the fan without it is a net *loss* of coverage on the host that takes the internet down.
2. **Commissioning the fan must include proving detection survived it.** Per the standing rule — force the condition and watch it fire. On the cooled box, deliberately peg one core (`timeout 300 sh -c 'while :; do :; done'`) and confirm an alert reaches #home-alerts. **"Temps look fine now" is not acceptance**; it is exactly the observation a silenced detector produces.
3. **L-E should follow the fan, not precede it.** The threshold restore reads differently on each side of it: on a fanless box the repo's `THROTTLE_WARN=20` pages constantly (see RESTORE ON RETURN), but **on a properly cooled box those repo values become correctly calibrated again** — 20 throttle events on a box that measured zero across three days is a real signal. Restore them *after* the fan and the wrapper-dedup dependency largely evaporates.
4. **Re-baseline once cooled.** The RECURRENCE table's fan-OK figures predate this year's ambient and the KSM change. Take a fresh idle + pegged-core reading after commissioning so the next comparison has a true reference.

#### ✅ ANSWERED 2026-08-08 — the `choco` false failures are real, and the merge already fixes all of them

**Measured as `choco`** on cobra, cwwk and opnsense (the user the cron actually runs as; every previous measurement was `read_agent`). **All three §1 predictions confirmed — none refuted.** All three hosts exit `0` today, as expected: the aggregation is not deployed yet, so the ❌ lines are cosmetic.

| Host | ❌ / ⚠️ observed as `choco` | Fixed by | After L-A+L-B |
|---|---|---|---|
| `cobra` | none — fully green | n/a | ✅ exit 0 |
| `cwwk` | ❌ `Upgrade log not found` · ⚠️ `Memory: 81%` | `fix/agent-lxc-logs-dir` | ✅ exit 0 |
| `opnsense` | ❌ `Service sshd: not running` · ❌ `Service cron: not running` · ⚠️ `Load: 4:10PM on 6 CPUs (67%)` | `fix/agent-lxc-logs-dir` | ✅ exit 0 |

**Why L-B is safe — verified in the branch, not assumed:**

- **`sshd` → `openssh`:** `freebsd_default_services()` probes `/etc/rc.d` and `/usr/local/etc/rc.d` for an `openssh` script and returns `"openssh cron"` on OPNsense. The name is detected, not hardcoded.
- **`cron` permission-dependence:** `freebsd_service_state()` tries `service status` first and only falls back to `pgrep` when `can_inspect_processes`; otherwise it returns `unknown`, which `check_services` grades as a **warning that increments nothing**. An unprivileged user who cannot see the process table can no longer manufacture a critical.
- **Unreadable upgrade log:** `check_auto_upgrades` now separates *unreadable* from *missing* and reports the former as a **warning**. Worth noting this means **B2 (the `adm` group) is no longer load-bearing for alert volume** — it is still correct and still worth doing, but the code now degrades safely without it.

🔴 **NEW — the FreeBSD load bug is TIME-DEPENDENT, and that is a diagnostic trap.** `check_load` returns the clock instead of the load, and awk coerces it: `load_percent = hour / ncpu × 100`. On opnsense's 6 CPUs:

| Clock hour | Reported | Severity |
|---|---|---|
| 1–3 | 17–50% | ✅ silent |
| **4** | **67%** | ⚠️ warning |
| **5–12** | **83–200%** | ❌ **error** |

**So it is an error for 8 of every 12 clock hours — 16 hours a day — and silent or merely advisory for the other 8.** The 2026-08-08 measurement was taken at 16:10, i.e. `4:10PM`, one of only four hours in twelve where it is not an error. An hour later it would have been ❌.

⚠️ **Had the aggregation shipped without this fix, opnsense would have paged for two-thirds of the day and gone quiet for the rest — an intermittent alert that looks exactly like a real fluctuating load problem.** It is fixed on `fix/agent-lxc-logs-dir` by `read_load_1min()`, which asks `sysctl -n vm.loadavg` rather than parsing `uptime` prose. **General lesson: a parse bug whose output is a plausible number is worse than one that crashes — this one was invisible for months because every value it produced was a number a busy box could genuinely report.**

<details>
<summary>Original brief (kept — it is why this was asked)</summary>

**Every false-failure measurement in this repo was taken as `read_agent`. The cron runs as `choco`.** Nobody had checked whether they persist for the user that actually runs the check, and the exit-status aggregation converts any that do into a page every 15 minutes, permanently, the moment L-B deploys.
</details>

⚠️ **An agent cannot answer this.** Autonomous SSH must use the `-agent` suffix; `choco` uses a Secretive key requiring Touch ID. Confirmed 2026-08-08 — `ssh -o BatchMode=yes` to cobra, cwwk and opnsense as `choco` all return `Permission denied (publickey)`, failing fast rather than hanging. **And re-running as `read_agent` would reproduce exactly the flaw this item exists to close.** It needs a human shell (the phone works).

```sh
ssh cobra    '~/.scripts/system_health_check.sh; echo EXIT=$?'
ssh cwwk     '~/.scripts/system_health_check.sh; echo EXIT=$?'
ssh opnsense '/usr/local/bin/system_health_check.sh; echo EXIT=$?'
```

Record the **exit code and every ❌ line** per host. Predictions from §1 of the handover, to be confirmed or refuted rather than assumed:

- The `adm` false failure should still fire — **B2 is not deployed yet.**
- opnsense's `sshd` is really **`openssh`**, so `check_services` probes a service that does not exist.
- opnsense's `cron` check is **permission-dependent** — `❌` as `choco`, `✅` as root, seconds apart. The cron runs as `choco`, so `choco` gets the false answer.

**This is a read. It changes nothing on any host.** Until it is answered, L-B's blast radius is unknown.

#### Deferred — do after L-A, not before

⚠️ **None of this may be written before the nine branches merge.** Measured collisions, identical in kind to the ones that parked the token item:

| File a fix needs | Already modified by |
|---|---|
| `scripts/common/system_health_check.sh` | `fix/agent-lxc-logs-dir-2026-08` **and** `feat/link-speed-check-2026-08` |
| `scripts/services/agent/investigate.sh.j2` | `fix/agent-lxc-logs-dir-2026-08` |
| `playbooks/tasks/deploy_monitoring.yml` | `fix/agent-lxc-logs-dir` **and** `fix/deploy-plumbing-dirs` |

🔴 **`check_load()` had a SECOND, independent reason it could never alert.** `system_health_check.sh` had no aggregation and no final `exit`, so its status was that of the last `echo`; `enhanced_monitoring_wrapper` keys purely on exit status. **So even a genuine whole-box saturation — the one case `check_load()` *was* designed for — never reached Slack, on any host, ever.**

⚠️ **Provenance corrected 2026-08-08 — this section first credited that to `feat/link-speed-check-2026-08` (2026-08-07). Wrong.** It was **measured 2026-08-05** and is already written up in the handover's §1, and `fix/agent-lxc-logs-dir-2026-08` already fixes it with per-check return codes. The link-speed branch re-derived it independently, and a second session (this one) then re-reported it as new — the same finding claimed three times. **The bug is real and the compounding argument below stands; only the "newly discovered" framing was false.** Recording it because re-discovery that looks like discovery is exactly how a fixed item gets re-opened and re-worked.

Two independent defects in the same check, from opposite directions: the **threshold** could not represent a single-process fault (this section), and the **exit path** discarded every fault it did detect. Either alone makes it silent. That both existed undetected for months is the strongest possible argument for the "start from failure modes, make the blanks the deliverable" review — neither would have been found by reading the check and asking whether it looked correct, because it *did*.

⚠️ **Build the runaway-process check on the post-L-A `main`, not today's.** `fix/agent-lxc-logs-dir-2026-08` is what converts the script to per-check counted returns summed into `total_issues` with a real `exit` — a check written against today's `main` would inherit the exit-0 bug and be cosmetic. Any new check must **count its faults and `return` the total**; reporting via `print_status` alone contributes nothing. That is not hypothetical: `check_link_speed` was written that way and had to be corrected (`db08910`) before it could ever alert.

Writing against a base that moves underneath, then resolving conflicts in cron and monitoring definitions, is this repo's signature failure mode. After L-A there is one branch and the collision is gone. (`check_system_health.sh` and `check_proxmox_health.sh` are clean on all nine branches, so a fix scoped to those two only *could* go earlier — it would not be the whole job.)

Three items, in the order they earn their keep:

1. **Bound agent diagnostics by wall-clock — `timeout`.** ✅ **Preferred, and it limits no capability.** A single hung command is what caused this; `timeout` catches *every* runaway shape (stuck grep, blocked read on a FIFO, hung `ssh`) without an allowlist to maintain and without narrowing what an agent may inspect. Deliberate design decision, taken 2026-08-07: **do not respond to this by restricting agent read access.** The failure was unbounded duration, not excessive scope.
2. **`--devices=skip` on BSD-side recursive greps** — `scripts/services/opnsense/*` and `scripts/services/agent/investigate.sh.j2`. Belt-and-braces; on its own it only fixes the one shape that already bit us, and GNU grep needs nothing.
3. **A runaway-process check.** 🔴 **Listed third but it is the one that matters most — it is the fan's prerequisite**, per the masking section above. Everything before it prevents *this* incident; only this one detects the *next* one, and after the fan nothing else will. Alert on a single process sustaining ~100% of one core across N consecutive samples. Reuse the `check_thermal.sh` counter-delta idiom (sample process CPU-time, alert on sustained growth) rather than a single-sample threshold. **Place it where the process runs, not on the hypervisor** — a pegged core on the firewall is nearly always wrong, whereas `kvm` at 109% on cwwk is sometimes legitimate. Host scope is an open decision; it touches `system_health_check.sh`, which reaches all eight hosts.

### ⚠️ RESTORE ON RETURN — manual drift on cwwk (do this FIRST when home)

Temporary changes were applied by hand on cwwk on 2026-08-01 while away. **All are un-codified drift.** Ansible restores most of it, but do it deliberately rather than discovering it later:

| Change | Current (drifted) state | Restored by |
|---|---|---|
| RAPL PL1 | **15W** (repo says 20W) | Reboot, or the `Restart cwwk power tuning` handler |
| RAPL PL2 | **20W** (repo/firmware default 35W) | Reboot only — the script does not manage PL2 |
| `check_thermal.sh` thresholds | **15000 / 40000 / 98 / 101** (repo: 20 / 500 / 85 / 95) | Any `platform/proxmox` run |
| Thermal cron schedule | `*/5` — already back to the repo value | n/a |
| **`ksmtuned` disabled** | `disabled` / `inactive (dead)` | ⚠️ **NOTHING — see below** |

📌 **The threshold row is no longer just drift — 2026-08-07 measured what it costs.** At `*/5`, `THROTTLE_CRIT=40000` sat exactly on the delta produced by one pegged core, oscillating CRIT/WARN every run; and `TEMP_WARN=98` kept a real 94–96°C event out of the alert text entirely. Restoring the repo values is the right move, but do it **with** the wrapper dedup in Next Steps — the repo's `THROTTLE_WARN=20` on a fanless box will page constantly on its own. See the 2026-08-07 event section above.

⚠️ **`ksmtuned` is a different class of drift and will NOT self-heal.** Disabled by hand on 2026-08-02. Unlike the rows above it **survives reboots *and* Ansible runs**, because the repo contains no KSM references at all (`grep -ri ksm ansible/ scripts/` → nothing). The systemd `preset: enabled` means a **rebuilt cwwk would come back with KSM on**, silently diverging from the running host. Either codify the disable in the `platform/proxmox` role (a `proxmox_disable_ksm` toggle, matching the variables-over-groups convention) or consciously re-enable it. Do not leave it as invisible drift.

```bash
# restore everything to the repo's source of truth
ansible-playbook ansible/playbooks/platform/proxmox.yml --limit proxmox --check --diff   # inspect first
ansible-playbook ansible/playbooks/platform/proxmox.yml --limit proxmox
```

**Then verify** — an Ansible run alone does *not* reset PL2, because `cwwk_power_tuning.sh` only manages PL1:

```bash
ssh cwwk-agent "grep . /sys/class/powercap/intel-rapl:0/constraint_[01]_power_limit_uw"   # expect 20000000 / 35000000
ssh cwwk-agent "sudo -n /usr/bin/crontab -l -u choco | grep proxmox_thermal"              # expect a single */5 line, no duplicate
```

If PL2 still reads `20000000`, reboot cwwk or write `35000000` back by hand. Also confirm the thermal cron did not duplicate (the `cron` module keys on its `#Ansible:` marker — see the rename gotcha in `CLAUDE.md`).

### ⚠️ Sensor reliability — `acpitz` and the NVMe temp on cwwk are NOT trustworthy

Discovered 2026-08-01 while using them as evidence. Five reads over 20s:

- `nvme` `temp1/2/3_input` = **35850 on all three sensors, identical, zero variation** — and `nvme=35` in every one of 2160 log samples across four days. Three identical sensors that never move is not a live measurement.
- `acpitz` (`thermal_zone0`) = **27800, constant across hours.** Almost certainly a fixed ACPI value, not a real probe.
- `x86_pkg_temp` varied normally over the same reads (68/65/66/71/65°C) — **this one is real.**

**Consequence:** the earlier "board ambient is only +1.3°C above room, so the cabinet ventilates fine" claim rests on `acpitz` and is **withdrawn**. Cabinet air temperature is currently *unmeasured* — which is precisely the gap the ambient probe below fills. Trust only `x86_pkg_temp`/`coretemp` on cwwk and the Pis' `thermal_zone0`; do not use `acpitz` or the NVMe reading for anything.

### KSM is a hidden thermal variable on cwwk (discovered 2026-08-02)

Throttling collapsed from ~3,500 events/hour (all afternoon and evening of Aug 1) to **~0/hour from 05:00 on Aug 2** — with *no* fan change, room ambient actually 0.7°C **higher** (27.2°C vs 26.5°C), unchanged guests, and similar load. Cause traced to **KSM (Kernel Samepage Merging)**:

- `ksmd` averaged 6.2% CPU over the host's lifetime but now measures **0 ticks in 20s**, and `/sys/kernel/mm/ksm/run` = **0**.
- `ksmtuned` enables KSM when free memory drops below ~20% of total and disables it above. Host total is 31,834 MB → threshold ≈ 6,367 MB. Free currently reads **6,398 MB** — i.e. the host sits *right on the activation boundary* and toggles across it.
- `general_profit` = **-201,384,320** (negative): KSM is costing more than it saves here anyway, with only 52 pages shared.

**Mechanism:** KSM scanning is a low-level *continuous* CPU burn spread across all cores. On a cooling-starved CPU that is already sitting a few degrees under Tjmax, that constant background load is enough to hold it above the TCC trip point. Package average was ~69–70°C with KSM on versus ~66–68°C with it off — a ~3°C shift that produces a **cliff-edge** change in throttle counts, because throttling is a threshold effect, not a linear one.

**Consequences:**
1. **It confounds the RAPL cap experiment.** The 03:00 `pve-daily-update` comparison (14,002 events on Aug 1 without caps vs 8,682 on Aug 2 with caps) is *not* evidence the caps work — peak load also differed (12.65 vs 8.10), and KSM state differed. **The caps still have no demonstrated benefit.** See the `stress-ng` item for the only clean way to settle it.
2. **Latent issue independent of the fan:** this host runs close enough to the KSM threshold that memory growth in any guest silently adds continuous CPU load. **Note the thermal urgency disappears once ventilation is fixed** — a ~6%-of-one-core burn only matters on a cooling-starved CPU. The *memory* case stands on its own though: per the kernel docs, `general_profit =~ ksm_saved_pages * sizeof(page) - (all_rmap_items) * sizeof(rmap_item)`, so cwwk's **−201,384,320** means KSM's tracking overhead exceeds its savings by ~192 MiB, while `pages_sharing=52` is only ~208 KiB actually saved. KSM pays off with many near-identical VMs; cwwk runs *one* big FreeBSD VM plus three LXCs (which already share the host kernel and page cache), so there is almost nothing to merge. **DONE manually 2026-08-02** (`systemctl disable --now ksmtuned`; verified `disabled` / `inactive (dead)`, `ksm/run=0`). **Still needs codifying** — see the RESTORE ON RETURN note above, since this one does not self-heal. Trivially reversible if guest topology ever changes. Ref: <https://docs.kernel.org/admin-guide/mm/ksm.html>
3. Any future thermal comparison on cwwk **must record `/sys/kernel/mm/ksm/run`**, or it is uninterpretable.

### Design lesson — the fan must not be able to fail OFF

Two incidents, two different triggers (a person in June, a power cut in July), **one shared mechanism: the fan ended up off**. A thermostat-controlled fan would add a *third* way for that to happen. The durable fix is a fan on unswitched, always-on power — a dumb always-on fan cannot fail off, and a ~5W USB fan costs ~€1.50/yr to run continuously.

If a controller is used anyway (noise), it must be wired **fail-safe: fan ON when the controller loses power or faults** — never fail-off.

### Next Steps — remaining
- **Fan (ROOT CAUSE, now twice-proven):** move the cabinet fan to unswitched always-on power so neither a person nor a power cut can leave it off. Must not require a manual press after power restoration. *Still the actual fix — the cap only widens the margin.*
  - **Hardware bought 2026-08-02:** Noctua fan + a simple **mechanical** controller (USB voltage conversion, physical on/off switch, speed fader). A *mechanical* switch is the correct choice: it **retains its position through a power cut**, unlike the old USB fan's momentary soft-latch that reset to off on power-up — which is precisely what caused this incident.
  - 🔴 **Commissioning check — prove the fan did not silence anything (added 2026-08-07).** Better cooling removes `check_thermal.sh` as the accidental runaway-process detector and puts nothing in its place — see *"The fan will REMOVE the only thing that detected this"* above for the measured arithmetic. **Do not accept "temps look fine now" as commissioning**; that is precisely what a silenced detector looks like. Peg one core deliberately on the cooled box (`timeout 300 sh -c 'while :; do :; done'`) and confirm something still alerts. If nothing does, the fan has traded a loud misattributed alert for silence, and the runaway-process check is now blocking rather than deferred.
  - ⚠️ **Commissioning check — fan START voltage exceeds RUN voltage.** A DC fan needs more voltage to overcome static friction than to keep spinning, so a fader set low can leave a fan that runs happily but **fails to start from cold** after a power cut — silently recreating this exact outage. **Do not validate by watching it spin.** Set the fader, then pull power, restore it, and confirm the fan starts *by itself* from stationary. Check the model's minimum start voltage in Noctua's spec sheet and keep the fader comfortably above it.
  - Remaining risk after this: a human switching it off (the 2026-06-30 cause). Mitigate with labelling.
- **Alert-volume defect (not a threshold problem):** `enhanced_monitoring_wrapper` sends a Slack alert on *every* non-zero exit with no cooldown or dedup (`SEND_TO_ALERT=true` in the failure branch, ~line 384). A persistent known-bad condition therefore pages indefinitely at the cron interval. Same defect as the vinylstreamer 17-alert storm. Add per-monitor failure dedup: alert on transition into failure, then re-alert at a backoff interval, and alert on recovery. **Fix this in the wrapper — do not compensate by raising `check_thermal.sh` thresholds, which are correctly calibrated for a healthy box and would hide a genuine future event.** Cross-host benefit.

  **⚠️ Do NOT "fix" alert volume by lengthening the cron interval.** `check_thermal.sh` alerts on a *delta since last run*, so a longer interval accumulates a **larger** delta. Moving `*/5` → `*/30` during this incident cut alert count 6× but pushed each run's delta from ~275 (WARNING, ≥20) past `THROTTLE_CRIT=500` into **CRITICAL** — fewer alerts, all of them now critical. This trap applies to any delta-based check.

  **Validated patch (written and tested 2026-08-01, never deployed).** Replaces the bare `SEND_TO_ALERT=true` at line 385 of `scripts/common/enhanced_monitoring_wrapper`. Passed `bash -n`, and 5 logic cases: first failure → alert; repeat within window → suppressed; repeat after window → alert; recovery-then-failure → alert; corrupt marker → **fails open** (alerts). Uses the existing `LAST_STATUS`, `STATE_FILE` and `log_msg`:

  ```bash
  # --- alert cooldown ---
  # Alert on transition INTO failure, then at most once per ALERT_COOLDOWN while
  # the same failure persists. Recovery notification is unaffected.
  ALERT_COOLDOWN="${ALERT_COOLDOWN_SECONDS:-21600}"
  _marker="${STATE_FILE}.lastalert"
  _now=$(date +%s)
  _last=0
  if [ -f "$_marker" ]; then
    _last=$(cat "$_marker" 2>/dev/null || echo 0)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  fi
  if [ "$LAST_STATUS" != "failure" ] || [ $(( _now - _last )) -ge "$ALERT_COOLDOWN" ]; then
    SEND_TO_ALERT=true
    echo "$_now" > "$_marker"
  else
    log_msg "Alert suppressed by cooldown ($(( (ALERT_COOLDOWN - (_now - _last)) / 60 )) min remaining)"
  fi
  ```

  **Known limitation to resolve before deploying:** the cooldown keys on *failure*, not severity — a WARNING→CRITICAL escalation is suppressed inside the window. Either make it severity-aware (reset the marker when `exit_code` rises) or keep the window short enough that the worst-case delay is acceptable.
- **`cwwk_power_tuning.sh` fails silently (robustness, small):** both RAPL writes are wrapped in `|| true` and the unit still exits `0/SUCCESS`, so a rejected cap would be invisible — and because the BIOS defaults may coincide with the target values, reading the value back does **not** prove the script applied it. This cost real time on 2026-08-01 chasing a suspected BIOS lock. *(RAPL is confirmed **not** locked — `rdmsr -f 63:63 0x610` = 0, and both constraints are writable as root; the earlier failures were running on the wrong host and then as the wrong user.)* Fix: drop `|| true`, verify each write by reading the value back, and log/exit non-zero on mismatch so the unit goes `failed` and surfaces in `systemctl --failed`.
- **Consider a PL2 (burst) Ansible variable:** `proxmox_rapl_pl1_watts` exists but PL2 is deliberately left at the firmware default (35W). The 94°C spikes are burst-driven, so PL2 is the effective lever under degraded airflow. Consider `proxmox_rapl_pl2_watts` for a documented degraded-airflow mode. Note `constraint_0_max_power_uw` reads 15W — the chip's rated ceiling — so the current PL1 of 20W is actually *above* spec.
- **Validate under load:** `stress-ng` comparison at 35W vs 20W to quantify the temp drop (brief router-core load — schedule for a quiet window).
- **Live-fire the alert:** trigger a synthetic throttle delta and confirm the #home-alerts message + recovery end-to-end.
- **BIOS:** currently 5.27 (2024-11-26), board reports "Default string" — check CWWK for a newer release.
- **Forensics for hangs vs power:** consider netconsole / pstore-ramoops + a panic watchdog so a *hang* (vs power cut) is distinguishable next time.

### Acceptance Criteria
- [x] Power cap + governor applied as code and documented in decisions log
- [x] Throttle-aware dedicated alert deployed (logic verified)
- [x] Alert proven end-to-end — synthetic WARNING delivered a real #home-alerts message; returns to OK silently (no `--notify-fixed`, consistent with other checks — add it if closure pings are wanted)
- [x] cwwk holds throttle-free under summer load — validated over 2 days (2026-06-30→07-02, 1445 samples): package temp mean 46.7°C, peak 70°C (vs 105°C throttle point), **zero throttle events**; counter flat at 22,841. *Scope note (2026-08-01): this held **with working airflow**, and was re-confirmed Jul 28–30 (zero throttle events over 3 days). It does not hold with the fan off — see RECURRENCE above.*
- [ ] 🔴 **Detection survives the fan (added 2026-08-07).** After commissioning, peg one core on the cooled box and confirm an alert reaches **#home-alerts**. ⚠️ **This criterion cannot be met by a temperature reading** — the whole point is that temperature will look fine. It is met only by a fault being *reported*. Until it passes, cwwk has less runaway-process coverage with the fan than it had without one.
- [ ] Fresh idle + pegged-core baseline recorded post-fan, so the next thermal comparison has a true reference (the Jul 28–30 fan-OK figures predate this year's ambient and the KSM change).

### Incidental findings (this session)
- ✅ **cwwk cron/mail drift reconciled** (2026-07-01): adopted `save-dmesg` + `arc_summary` into the `platform/proxmox` role as managed root crons; removed the stale `Proxmox health check` cron (its target `proxmox_health.sh` didn't exist → failed every 4h). Root cause of the deferred-mail pileup was the 6 monitoring crons emitting the wrapper's stdout every run → now redirected to `~/.logs/proxmox_*.log` (matches the backup crons). Built `/etc/aliases.db` and flushed 2201 stale cron mails. cwwk root crontab is now 100% Ansible-managed.
- ⚠️ **Move webhook tokens out of cron arg lines** (elevated) — the Slack tokens are literal in every monitoring cron `job`, so they leak into `crontab -l`, `--diff` output, and cron-mail subjects (seen repeatedly this session). Move to a sourced env file read by `enhanced_monitoring_wrapper`. Given the repeated exposure, **consider rotating the two webhooks**. Cross-host (all monitored hosts).
- Monitoring logs (`~/.logs/proxmox_*.log`) and `zfs-arc.log` have no rotation — add logrotate if they grow.
- ✅ **cobra timezone skew — RESOLVED 2026-07-21.** cobra was on `Europe/London` (BST, 1h behind the rest of the fleet). No code change was needed: `timezone: "Europe/Madrid"` already lives in `group_vars/all/main.yml` and `debian_baseline.yml --tags timezone` already applies it — cobra had simply drifted and was the only outlier (all 6 other hosts verified `Europe/Madrid`/CEST). Applied with `ansible-playbook ansible/playbooks/platform/debian.yml --tags timezone --limit cobra`. **Gotcha worth remembering:** `cron` caches the timezone at process start and does *not* pick up a `/etc/localtime` change on its own, and `community.general.timezone` did not restart it here — cobra's cron was still 901s old (pre-change) after the module reported `changed`, so every cobra cron would have kept firing an hour off. **Now codified** (2026-07-21): `debian_baseline.yml` registers the timezone task and restarts cron only when it actually changed — verified idempotent (`changed=0`, restart skipped, on a second run against cobra). Note the FreeBSD path (`freebsd_baseline.yml`, `tzsetup`) has the same latent gap and was deliberately left alone — opnsense is the firewall and its timezone is managed through `config.xml` anyway; revisit only if its zone ever needs changing.
- No UPS monitoring (NUT/apcupsd) on cwwk; the 2026-06-30 split (cwwk down, Pis up) suggests cwwk may not share the Pis' power protection — worth confirming UPS topology. **Reinforced 2026-07-30:** a house power cut took the whole fleet down for ~24h, and the only reason it was recoverable remotely is that everything came back on its own.

**Findings from the 2026-08-01/02 thermal session:**
- 🔁 **`read_agent` on opnsense is broken AGAIN — this is a recurrence of Priority 2 below, not a new issue.** `ssh opnsense-agent` returned `Permission denied (publickey)` on 2026-08-01, the exact symptom documented in Priority 2 (OPNsense's `local_sync_accounts` wipes `pw`-managed uid ≥ 2000 accounts on firmware upgrade). **Fix is the known one-liner:** `ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense` (~9s, idempotent). It blocked autonomous diagnosis of the firewall during this incident — the 10G interface/media state had to be gathered by hand, which is precisely the cost Priority 2 predicts.
  - ⚠️ **The detection works — the *signal* was lost, which is worse.** Checked the code: `opnsense` **is** in `agent_fleet_hosts` (`kind: freebsd`, `inventory/group_vars/agent.yml`), and `fleet_health_check.sh.j2` explicitly handles a dead probe — absence of the `DISK` field emits `note "$host" "UNREACHABLE (no response as read_agent)"`. So the hourly sweep has almost certainly been reporting opnsense UNREACHABLE the entire time, and it went unnoticed **while ~336 thermal alerts/week were being generated**. This is textbook alert fatigue: a real, correctly-detected failure buried under a known-condition alert storm. **It is the strongest argument for the wrapper dedup above** — that work is not cosmetic, it protects the signal-to-noise of every other check. Action on return: read back `fleet_health_check.log` / #home-alerts history to confirm how long opnsense has been flagged, then run the Priority 2 repair command.
- **Postfix on cwwk is deferring mail to `me@ignacio.systems`** — repeated `connect to mx0*.mail.icloud.com[...]:25: Connection timed out`, with items aging up to ~41h in the queue (`delay=149861`). Outbound :25 is very likely blocked (ISP or OPNsense egress rule). Cron/monitoring mail is therefore silently not being delivered. Either route through an authenticated smarthost on :587 or accept it and stop generating mail. Related to the 2026-07-01 cron-mail cleanup above.
- **`fs.protected_regular` gotcha (cost real time debugging):** on Debian 12+/Proxmox, **root cannot write to a file it does not own inside a sticky world-writable dir** like `/tmp`. A shell redirect such as `2>/tmp/foo.err` fails with `Permission denied` *even as root* if `/tmp/foo.err` is owned by another user. Worse, bash processes redirections left-to-right and **aborts the whole command** if one fails — so `cmd 2>/tmp/foo.err > /sys/...` never runs `cmd` at all, and the resulting "failure" is entirely spurious. Use `/root/` for scratch error files when debugging as root.

---

## #home-logging Flooded by dockassist Container Checks (NEW, 2026-08-02)

**Risk:** Low operational, high signal-to-noise. `#home-logging` is the unwatched firehose, so nothing is *missed* — but ~92% of the channel is three duplicated messages, which makes the channel useless for the "scan it occasionally" purpose it exists for. No alerting impact (`#home-alerts` is a separate webhook and is unaffected).

### Symptom (measured 2026-08-02)

dockassist posts **3 messages every 10 minutes, 24/7** — `check_container.sh` for `home-assistant`, `matter-server` and `mosquitto`:

| Source | msgs/day |
|---|---|
| dockassist `check_container.sh` × 3 | **432** |
| Entire rest of the fleet (daily heartbeat burst at 00:00) | ~35 |

Every other host behaves correctly: one heartbeat per job per day, all fired in a single 00:00 CEST burst.

### Root cause (verified on the live host, not inferred)

All three cron jobs invoke the **same script** and none passes `--monitoring-name`. The wrapper then derives its state-file name from the script basename:

```sh
STATE_NAME="${MONITORING_NAME:-$(basename "$script_path")}"   # enhanced_monitoring_wrapper:301
```

→ all three share `/home/choco/.log/check_container.sh.json`, and they run in the same second. The state write is a fixed tmp path with no locking:

```sh
jq … "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"   # :432
```

Three concurrent writers trample it. Live evidence from `~/.logs/homeassistant_container_check.log`:

```
[2026-08-02 17:10:02] Sending daily heartbeat notification
mv: cannot stat '/home/choco/.log/check_container.sh.json.tmp': No such file or directory
```

162 such occurrences in the mosquitto log alone. State never persists → `LAST_NOTIFICATION_DATE` never matches today → the "daily" heartbeat fires on every run.

**Control case on the same host:** `check_docker.sh` — same wrapper, same `--heartbeat-interval=daily`, also no `--monitoring-name`, but a *unique* basename → `Notification sent: No` for 12 hours straight. That isolates the fault to the state-file collision, not to the heartbeat logic.

### It is a bug, not an intentional design (theory evaluated + rejected)

Considered and disproved the theory that these were meant to be chatty and the wrapper was simply misused:

- The cron explicitly says `--heartbeat-interval=daily`. If per-run posting were wanted, the correct knob is `--heartbeat-interval=always`, which this repo **already uses deliberately** in 4 other places (backups, HA update, USB recovery sync). The author knew the knob.
- The `mv: cannot stat` error on every single run is a malfunction signature, not a configuration.
- Identical config to the quiet `check_docker.sh` on the same host.

**But the "wrapper wasn't fully understood" half of the theory is correct, and is the real lesson:**

- `--monitoring-name` was introduced 2025-11-16 (`5adbec1`, proxmox/opnsense) — *one day after* the HA container check shipped in the initial migration (`a000f71`, 2025-11-15). It was never retrofitted onto the pre-existing HA jobs, and adoption stayed patchy: cwwk 5/5 jobs, cobra 2/10, dockassist 2/12, hifipi/vinylstreamer/unifi 0.
- The wrapper documents the flag as *"Name of the monitoring task (used for state file if provided)"* — it reads as cosmetic. Nothing signals **"required whenever two jobs on a host share a script."** That is an API footgun, not operator error.

### Timeline — this is NOT from the recent HA/MQTT work

The Mosquitto addition (`67d9454`, 2026-07-12) only took it from 2 messages to 3. Slack evidence, sampled at three points:

| Date sampled | msgs / 10 min | Which |
|---|---|---|
| 2026-05-10 (Slack retention edge) | 2 | — |
| 2026-06-15 | 2 | `home-assistant` + `matter-server` |
| 2026-07-11 (day before Mosquitto) | 2 | `home-assistant` + `matter-server` |
| 2026-08-02 (now) | 3 | + `mosquitto` |

The Matter Server cron was committed **2025-11-30** (`45d0f11`) — in the *same commit* that created the container, so monitoring shipped with it — and is provably live from at least 2026-05-10, two months before any MQTT work.

**Breakage began at N=2 container checks, not N=3.** With a single `check_container.sh` job the state file is unique and the wrapper behaves correctly; the second one is what created the collision.

Caveats on evidence: Slack free-tier retention is ~90 days, so continuity between 2025-11-30 and 2026-05-10 is inferred from git, not observed. Docker container creation dates are **not** usable as "first deployed" evidence — an image update recreates the container (`home-assistant` reports `Created=2026-07-10` despite running for years).

### Related latent issues found in the same pass

1. **The wrapper silently accepts invalid `--heartbeat-interval` values.** The `if/elif` chain (`:390–399`) only handles `daily|hourly|always`; anything else matches no branch and silently disables heartbeats entirely. Two live instances:
   - `--heartbeat-interval=weekly` on dockassist `docker_system_prune` — almost certainly unintended; that job has never heartbeated.
   - `heartbeat: "never"` on the OPNsense VPN gateway tracking job (`roles/platform/opnsense/tasks/main.yml:160`) — intent is clear and it works, but only *by accident*. Should become a first-class supported value.
2. **The state-write race is fleet-wide latent, not dockassist-specific.** `check_volume_quota.sh` already runs on both cobra and vinylstreamer — different hosts, so no collision *today*. The next same-host duplicate re-arms the identical bug.
3. **A failed state update is invisible.** `… && mv` with no error handling means the wrapper carries on as if it persisted.

### Fix (repo — requires laptop, Ansible deploy)

Scope deliberately split. **There is exactly one active bug**; everything under "prevention" is latent and currently produces zero noise. Do not let the prevention work gate the fix.

**Required — this alone resolves the channel flood (467 → ~38 msgs/day):**
- [x] Add distinct `--monitoring-name={homeassistant,matter_server,mosquitto}_container` to the three cron jobs in `roles/services/homeassistant/tasks/main.yml` and `tasks/mqtt.yml` — **done 2026-08-06**, and verified byte-for-byte against dockassist's live crontab (see below)
- [ ] `rm /home/choco/.log/check_container.sh.json*` on dockassist — orphaned once the new state names take over

**Prevention — ACCEPTED 2026-08-02, to be done in the same pass:**
- [ ] Harden `scripts/common/enhanced_monitoring_wrapper`: `mktemp` for the state tmp file instead of the fixed `${STATE_FILE}.tmp` (~2 lines). Disarms this bug class on every host for every future job.
- [ ] Make `never` a **first-class, documented, validated** value for `--heartbeat-interval` — see decision below
- [ ] Hard-fail on unrecognised `--heartbeat-interval` values instead of silently disabling heartbeats
- [ ] Fix `--heartbeat-interval=weekly` on `docker_system_prune` → **`always`** (not `daily`). That job runs `@weekly`, so "heartbeat on every run" *is* one message per week — `always` states the intent honestly. (`daily` would behave identically here since runs are 7 days apart; `always` is the clearer expression. This supersedes the earlier `→ daily` suggestion.)

#### Decision — heartbeat interval semantics (2026-08-02)

Owner's intent, stated explicitly: **do not add more frequency values** (`weekly`, `monthly`, …). The supported set stays `daily | hourly | always | never`, where the job's own cron schedule carries the cadence and the heartbeat setting only says *how often to speak about it*. Both live oddities (`weekly` on `docker_system_prune`, `never` on the OPNsense VPN job) came from the same assumption — that an unlisted value would degrade to "no heartbeat". It does, but only by accident, and silently.

⚠️ **One open sub-decision, deliberately unresolved.** Owner's stated preference is that *leaving the interval undefined* should mean "no heartbeat". The wrapper currently defaults to `HEARTBEAT_INTERVAL="daily"` (`:203`) when the flag is absent.

Recommendation: **make `never` explicit but keep `daily` as the absent-flag default.** Reason: a job that silently never heartbeats is indistinguishable from a job that is broken or not running at all — silence is the one signal monitoring must never default to. A forgotten flag should produce one noisy message a day, not permanent quiet. All 40+ live wrapper invocations currently pass the flag explicitly, so this default is never actually exercised today; the choice only affects future jobs.

Owner may overrule at implementation time — if so, flip the default to `never` **and** add a CI lint requiring `--heartbeat-interval` to be present on every wrapper invocation, so the silence is always deliberate rather than forgotten.

**Deliberately dropped** (churn across 7 hosts for no current benefit):
- ~~Stagger the three container checks~~ — redundant once the tmp path is unique
- ~~Fleet-wide `--monitoring-name` retrofit~~ — the flag only matters when two jobs on one host share a script basename. Better addressed as a CI lint that fails on same-host duplicate basenames without `--monitoring-name`, if it recurs.

**Deploy:** `ansible-playbook ansible/playbooks/services.yml --limit dockassist` (container checks) + `ansible-playbook ansible/playbooks/deploy_monitoring.yml` (wrapper, all hosts — only if the prevention items are taken).

**Acceptance:** `#home-logging` drops from ~467 to ~38 msgs/day; dockassist's three container checks each post exactly once per day in the 00:00 burst; no `mv: cannot stat` lines in `~/.logs/*container_check.log`.

### Interim manual mitigation (applied by hand while remote)

**This is NOT drift.** The hand-applied `--monitoring-name` values are byte-identical to what the Ansible fix will render (`homeassistant_container`, `matter_server_container`, `mosquitto_container`), so deploying the repo fix is a no-op on these three lines. The cron `name:` comments are untouched, so the playbook overwrites cleanly with **no duplicate entries** (see the cron-naming gotcha in `CLAUDE.md`).

Exact command applied (idempotent — the `/--monitoring-name/!` guard makes a second run a no-op; dry-run verified against the live crontab with the host's GNU sed):

```sh
crontab -l > ~/crontab.bak.$(date +%Y%m%d)
crontab -l | sed -E \
 -e '/check_container\.sh [^ ]+ home-assistant /{/--monitoring-name/!s#--notify-fixed=true#--notify-fixed=true --monitoring-name=homeassistant_container#}' \
 -e '/check_container\.sh [^ ]+ matter-server /{/--monitoring-name/!s#--notify-fixed=true#--notify-fixed=true --monitoring-name=matter_server_container#}' \
 -e '/check_container\.sh [^ ]+ mosquitto /{/--monitoring-name/!s#--notify-fixed=true#--notify-fixed=true --monitoring-name=mosquitto_container#}' \
 | crontab -
rm -f ~/.log/check_container.sh.json*
```

- [x] **Applied on dockassist 2026-08-02, between 19:20 and 19:30 CEST — verified working.**
- [ ] Backup at `~/crontab.bak.20260802` — delete once the repo fix is deployed and verified

**Verification (2026-08-02 19:30 CEST, first cron run after the change):** all three jobs report `Notification sent: No`, the `Sending daily heartbeat notification` line is gone, and no `mv: cannot stat` errors appear in any of the three logs. Confirms the root cause and the fix. Channel volume should now settle at ~38 msgs/day.

Note for whoever verifies next: the `*/10` runs immediately *before* the crontab edit still show the old behaviour. Read the first run after the edit, not the last few lines, or you will conclude the fix failed.

### Repo fix verified against the live crontab — 2026-08-06

The three `--monitoring-name` values are now in the role, and the claim that they
match dockassist byte-for-byte is **measured, not asserted**. Method, without
connecting to the host as `choco` and without a playbook run:

1. Capture the live crontab (see the `read_agent` note below).
2. Parse the `job:` strings straight out of the two task files, render them with
   Jinja2 against dockassist's real variables, and diff against the live lines.

Variable resolution is the part that is easy to get wrong. `ansible-inventory
--host dockassist` returns **neither role defaults nor the function-level
`group_vars/homeassistant.yml`** — the latter is pulled in by `services.yml` with
`include_vars` at runtime, keyed on `primary_function`, because dockassist is not
in an Ansible group called `homeassistant`. Layer all three in precedence order
(role defaults < inventory < `include_vars`) or the render silently uses fallback
values: the first attempt produced a phantom diff on `Internet speed check`
(300/150/100 from the `| default()` arms instead of the real 850/850/15).

**Result: 12 of the 13 rendered cron jobs are byte-for-byte identical to the live
crontab**, including all three target lines. The lines that were not touched
matching is what makes the three that were meaningful — a render that agrees with
reality everywhere else is a render worth trusting.

**The one remaining diff is intentional**: `Docker system prune` is
`--heartbeat-interval=weekly` live and `always` in the repo. That is this
branch's own fix (see the prevention list above), not drift. **So L4's
"`--check --diff` shows no diff" acceptance needs restating: no diff on the three
container-check lines, one expected diff on `docker_system_prune`.**

Checked in both directions, per the standing method: with the change stashed, all
three lines report `DIFFERS`. A comparison that cannot fail is not evidence.

✅ **The captured crontab was itself validated.** `sudo crontab -l -u choco` over
`read_agent` was diffed against `crontab -l` run as `choco` on the host: **byte-for-byte
identical**, no truncation or mangling. The byte-for-byte claim above therefore
rests on confirmed source data, not on a privileged view that might differ.

📌 **`read_agent` CAN read another user's crontab — argument order is the catch.**
The sudoers rule is `/usr/bin/crontab -l -u *`, so `sudo crontab -l -u choco`
works from `dockassist-agent` while the more natural `sudo crontab -u choco -l`
is rejected with "a password is required". This retires the standing assumption
that reading a live crontab needs a `choco` shell from the phone — it is
autonomous, and any future "does the repo match the host?" check can be done the
same way.

### Fatal-interval blast radius — measured fleet-wide 2026-08-06

The hardened wrapper makes an unrecognised `--heartbeat-interval` fatal
(`daily|hourly|always|never` pass; anything else exits 1). Since the wrapper
ships to every host via `deploy_monitoring.yml`, "which live cron lines does that
kill?" is a question about the **crontabs**, not about the script — so it was
counted rather than reasoned about, via `sudo crontab -l -u {choco,root}` over
`read_agent`:

| Host | always | daily | weekly |
|---|---|---|---|
| dockassist | 1 | 10 | **1** |
| cobra | 1 | 9 | — |
| hifipi | — | 7 | — |
| vinylstreamer | — | 3 | — |
| cwwk | 2 | 8 | — |
| unifi-lxc | — | 4 | — |

**Exactly one invalid value exists on the whole fleet: `docker_system_prune` on
dockassist — the one this branch already fixes.** So the deploy-ordering
constraint (`services.yml --limit dockassist` before or with
`deploy_monitoring.yml`) is not just necessary, it is *sufficient*: no other host
needs a coordinated change, and no other job goes fatal.

✅ **opnsense measured 2026-08-06 too — also clean.** Read by hand as `choco`
(FreeBSD's sudoers has no `crontab -l -u *` rule, so `read_agent` is refused
there; the host is reachable, the refusal is authorisation). Of 13 crons, **9
invoke the wrapper**: `daily` ×8 and `never` ×1. Both valid, so nothing on
opnsense goes fatal either.

🔴 **Correction — "the FreeBSD cron is unwrapped" is false, and it has been used
to rank deploy risk.** opnsense runs the wrapper on 9 of 13 crons, explicitly via
`/usr/local/bin/bash`. The *narrow* claim in §1a survives untouched: the common
`system_health_check.sh` is genuinely not scheduled there — what is scheduled is
the role's own `check_system_health.sh`, a different file. But the generalisation
drawn from it does not. **`deploy_monitoring.yml` ships
`enhanced_monitoring_wrapper` to opnsense, where 9 live crons depend on it**, so
the wrapper half of L3 has full blast radius on the firewall even though the
`system_health_check.sh` half has none. Rank opnsense's L3 risk on the wrapper,
not on the health script.

Also confirmed while there, since both could have bitten opnsense at L3:
- **`never` is explicit, not a fall-through.** It suppresses the heartbeat and
  *still* sends recovery notifications. `opnsense_vpn_gateway` runs `*/15` with
  `never`, so a regression here would have been either 96 msgs/day or a silently
  lost recovery alert. Neither: behaviour is unchanged from `main`.
- **The `mktemp` change is guarded.** An empty result is caught
  (`[ -z "$state_tmp" ]` → warn, state not persisted) and a failed update
  `rm -f`s the temp file instead of leaving litter. Previously `... && mv`
  carried on as though the state had persisted.

✅ **`mktemp` verified on FreeBSD 2026-08-06** — run on opnsense itself:
`mktemp /tmp/statetest.json.XXXXXX` returned `/tmp/statetest.json.hErSn4`. The
path-bearing template works, so the wrapper's state update persists on the
firewall and heartbeat dedup — the exact thing this branch exists to fix — does
not silently break there after L3. **No executable unknown remains for this
branch on opnsense.**

Related: the three container checks all use `daily`, and the `--monitoring-name`
parsing (`STATE_NAME="${MONITORING_NAME:-$(basename "$script_path")}"`) is
**unchanged from `main`** on this branch — the hardening touched `mktemp`, the
docs and the error path only. So the byte-identical cron lines derive identical
state-file names under both the old and the hardened wrapper. That coupling was
checked rather than assumed, because the branch changes the cron lines and the
wrapper together.

**Still outstanding after the manual step** (i.e. what the laptop session is actually for): the wrapper hardening, the interval validation, the `never`/default decision, and the `docker_system_prune` `weekly` → `always` fix. None of those are applied by hand.

### ✅ Status 2026-08-04 — prevention items DONE, required item NOT done

Written and verified against a disposable Debian 13 LXC (CT 199) by
`tests/cases/wrapper_state_collision.sh`, run in both directions. **Nothing is
deployed.**

Done on this branch:
- **`mktemp` for the state temp file.** Against `main` the test reproduces the
  dockassist fault on demand: **6 × `mv: cannot stat`** across 15 concurrent
  runs, leaving an empty, corrupt state file. Zero on this branch.
- **`--heartbeat-interval` is validated.** `never` is now first-class;
  unrecognised values are fatal instead of silently disabling heartbeats.
- **`docker_system_prune` `weekly` → `always`.**
- **`--monitoring-name` documented as REQUIRED** when two jobs on a host wrap
  the same script. It read as cosmetic, which is an API footgun rather than
  operator error.

Sub-decision resolved as recommended: an **absent** `--heartbeat-interval` still
defaults to `daily`. Silence is the one signal monitoring must never default to
— a job that quietly never heartbeats is indistinguishable from one that is
broken. All 40+ live invocations pass the flag explicitly, so the default is not
exercised today.

⚠️ **STILL NOT DONE: the three `--monitoring-name` cron values** — the
"Required" item, and the only one that actually clears the channel flood. The
interim hand-applied crontab fix on dockassist is still what is holding the
channel quiet, and an unmodified `services.yml` run STILL REVERTS IT. Nothing
about this branch has changed that.

⚠️ **Deploy ordering.** Making unknown intervals fatal means
`docker_system_prune` would hard-fail weekly if the wrapper reached a host
before the cron fix. Audited: the repo now contains 35 `daily`, 4 `always`, 1
`always` (was `weekly`), and `never` on the OPNsense VPN job. The cron fix
reaches dockassist via `services.yml` while the wrapper reaches all hosts via
`deploy_monitoring.yml`, so they are committed on this one branch deliberately
— do not split them.

### Session decisions (2026-08-02)

- Prevention items: **accepted** — do them in the same pass as the required fix.
- Implementation: **deferred entirely to laptop time.** This plan is committed to branch `docs/monitoring-heartbeat-collision-2026-08` (off `main`, independent of the cwwk thermal branch); **no code has been written and nothing has been deployed** — deliberate, because the wrapper change touches all 7 hosts and cannot be tested remotely (`read_agent` is read-only; deploys need Touch ID).

---

## hifipi `amixer` Alerts — Repo Fix Never Deployed (fix written, awaiting deploy — 2026-08-02)

**Risk:** None operational — audio is verifiably healthy. This is `#home-alerts` noise, and that is the *watched, push-notified* channel, so it is worse than pure log spam: it trains the owner to ignore real alerts. 8 false alerts/week.

### Symptom

| Alert | Schedule | Script | Error |
|---|---|---|---|
| 1 | daily 00:00:04 | `check_audio_output.sh` | `amixer: Unable to find simple control 'Master',0` |
| 2 | **Sundays only** 00:00:06 | `restart_audio_services.sh` | `amixer: Unable to find simple control 'Digital',0` |

Slack corroborates exactly: one alert on 07-22/23/24/25/27/28/29/30 and 08-01, **two** on 07-26 and 08-02 — both Sundays (`@weekly` = Sunday 00:00). That cadence is why it read as "one alert that sometimes doubles".

### Root cause — the fix existed in the repo and was never deployed

`9972e65` (**2026-03-23**) already corrected both scripts to target the real hardware control (`amixer -c 0 … 'DAC'`). hifipi was still running the **pre-March versions**. Verified by checksum, not inferred — exactly the two files that commit touched differed; every other audio script and every common script matched.

**Why the drift persisted:** these scripts are deployed *only* by the `audio_playback` role (`ansible/roles/services/audio_playback/tasks/main.yml:301`), via `services.yml`/`site.yml`. `deploy_monitoring.yml` — the playbook you'd naturally reach for when chasing monitoring noise, and which `CLAUDE.md` calls *"Deploy monitoring scripts to all hosts"* — copies only `scripts/common/`. So common scripts stayed in sync (proving the host *was* being deployed to) while role-owned ones rotted for four months with no failing signal.

### Hardware ground truth (verified)

Card 0 `sndrpihifiberry` (HiFiBerry DAC+ HD) exposes only `DAC Playback Volume` and `PCM Playback Volume` (`/var/lib/alsa/asound.state`). There is **no `Master`, `Digital` or `Analogue` control on this card at all** — the old names were never valid for this DAC. `DAC` sits at `240/240` = 0 dB = 100%; `PCM` at unity. `systemctl --failed` empty, MPD/Shairport/Raspotify healthy. **Zero audio impact — always pure monitoring noise.**

### Three bugs, not one — the control names were only the visible layer

Redeploying `9972e65` as-is would **not** have silenced alert 2:

1. `restart_audio_services.sh` still called `/usr/bin/amixer sset 'Master' 100%` (no `-c 0`) under `set -e`. No PulseAudio session exists in cron, so `Master` is absent → exit 1 → the Sunday alert would keep firing, merely renaming the control. Proven by the deployed check script failing on that exact control in that exact context nightly. **Fixed: line dropped** (the hardware DAC line above it does the real work; `|| true` would have preserved a permanent no-op).
2. `check_audio_output.sh` used bare `alsactl store` with no `sudo`; `/var/lib/alsa/asound.state` is root-owned `0644` → fails as `choco` → `set -e` → exit 1. Invisible today because that branch only runs when DAC < 90%, and DAC is pinned at 100%. The sibling script already did it correctly. **Fixed: `sudo /usr/sbin/alsactl store`**, matching. `choco` holds `NOPASSWD: ALL` (`ansible/playbooks/bootstrap.yml:133`), and `sudo systemctl restart …` already succeeds from cron in the same script.

`asound.state` was last written **Mar 23 19:18** — during the manual session that produced the fix. No `alsactl store` has succeeded since.

### Coverage check — does the fix still catch what the monitoring is for?

The intent is "audio device present, at max volume". Checking this surfaced **a third bug**, unrelated to the control names and older than them:

- **Device present:** `aplay -l | grep -q 'card'` → unchanged; still exits 1 + alerts if the card disappears. Always worked.
- **Max volume:** now reads `DAC` (the real hardware volume, 0–240) instead of `Master`, which never existed. **But pointing at the right control was not sufficient — the value was never usable.** See below.
- **Dropped `Master` write:** loses nothing. No such control exists on this card in any context.
- **Known gap (accepted):** `PCM Playback Volume` is not checked. It sits at unity (0 dB of −102.39…+4.00 dB) and nothing in the repo ever writes it. Worth adding only if a "quiet audio" incident ever occurs with `DAC` at 100%.

#### Bug 3 — the volume threshold never evaluated (fixed 2026-08-02)

`grep -E 'Left:|Mono:'` matches **two** lines on a stereo control, because `amixer` prints an empty `Mono:` header above the channels:

```
  Mono:
  Front Left: Playback 240 [100%] [0.00dB]
  Front Right: Playback 240 [100%] [0.00dB]
```

`awk -F'[][]' '{print $2}'` emits a blank field for `Mono:` and `100%` for `Front Left:`, so `VOLUME` is `"\n100"` — multi-line. That fails the `^[0-9]+$` guard, so `[ "$VOLUME" -lt 90 ]` **never runs**, the script always falls through to the success branch, and the self-heal path is unreachable. A DAC at 10% would have been reported as "configured correctly".

Pre-existing, not introduced by the `Master`→`DAC` migration: the old version had the identical `grep` and simply never reached it. Fixed by taking the first percentage and not filtering by channel label:

```sh
VOLUME=$(amixer -c 0 sget 'DAC',0 | grep -oE '[0-9]+%' | head -1 | tr -d '%')
```

Verified against hifipi's real `amixer` output (clean `100`, threshold runs) and a mono-card variant (`50` → correctly flagged low). The replacement carries a comment recording the trap so the channel-label filter is not reintroduced.

**Lesson — this is the one worth keeping.** The bug survived two passes because verifying that a parse *matches* is not the same as verifying what it *yields*. The reasoning "`'Front Left:'` contains `'Left:'`, so the grep is fine" was correct and useless: the failure was in the second matching line, not the first. Check the produced value, not the pattern. It only became visible when real `amixer` output was pasted into the session — no amount of reading the script would have shown it.

### Why the earlier investigation didn't close it

The 2026-07-25 Tier 2 agent investigation ($0.44) diagnosed alert 1 correctly — "monitoring-script bug, this DAC has no `Master`, no audio impact" — but recommended *a human patch the check script*, not knowing the patch had been in git for four months. Its mitigations were therefore redundant, and it never saw alert 2 because that Sunday job hadn't fired in its lookback. **Lesson: on a `Script Failed` alert, diff the deployed script against the repo before diagnosing its logic.**

### Diagnostic gotcha — do not trust `amixer` from `read_agent`

`read_agent` is not in the `audio` group (`choco` is, gid 29). From a `read_agent` session `aplay -l` reports *"no soundcards found"* while `amixer scontrols` reports a phantom `'Master'`/`'Capture'` — the exact opposite of the truth. Read control names from `/var/lib/alsa/asound.state` (world-readable) instead.

### Status

- [x] Repo fix written and committed on branch `fix/hifipi-amixer-alerts-2026-08` (both latent bugs above). **Local only — not pushed**; pushing needs Touch ID and the owner was on a phone.
- [x] **Interim manual mitigation applied 2026-08-02 (~20:55 CEST) and independently verified** — see below.
- [x] Deployed checksums confirmed byte-identical to the repo (agent-side `shasum` via `agent_read`, not self-reported). Full re-audit of hifipi afterwards: **0 drift** across all repo-matched scripts.
- [x] **Second paste 2026-08-02 (~21:40 CEST)** — `check_audio_output.sh` volume-parse fix (bug 3). Host hash `9c0c2f5d8df31147d810087b426b13fff310a794`, confirmed by the owner. `restart_audio_services.sh` unchanged (`aafb6939…`).
- [ ] Deploy: `ansible-playbook ansible/playbooks/services.yml --limit hifipi --tags audio_playback` — **expect changed=0 on both scripts.** Anything else means something drifted after 2026-08-02; stop and diff.
- [ ] Verify a clean 00:00 run, **and a clean Sunday 00:00 run** — alert 2 needs a full week. Do not close this on a Monday.

#### What is and isn't proven as of 2026-08-02 21:00 CEST

| | Status |
|---|---|
| Files on host == repo | ✅ verified by checksum from the agent side (2nd paste hash `9c0c2f5d…` confirmed by owner) |
| `check_audio_output.sh` runs clean interactively | ✅ smoke-tested, exit 0, prints a single-line `DAC volume: 100%` |
| Volume threshold + self-heal branch actually fire | ✅ proven by forcing `DAC` to 50%: detected, reset to 100%, exit 0 |
| `sudo /usr/sbin/alsactl store` works from `choco` | ✅ **proven.** `sudo -n -l` shows `(ALL) NOPASSWD: ALL`; `sudo -n /usr/sbin/alsactl store` → exit 0 |
| `restart_audio_services.sh` runs clean end-to-end | ✅ run manually in full: all three services restarted, DAC set, `alsactl store` succeeded, exit 0 |
| `check_audio_output.sh` runs clean **under cron** | ⏳ first proof at **00:00 Mon 2026-08-03** |
| `restart_audio_services.sh` runs clean under cron | ⏳ first proof at **00:00 Sun 2026-08-09** (`@weekly`) |

**The `NOPASSWD` risk flagged earlier is closed** — proven by hand rather than left to Aug 9. `sudo -n` was used deliberately: plain `sudo` from an interactive session would have prompted and succeeded, proving nothing about cron, which cannot answer a prompt.

Only the cron-context runs remain, and both scripts have now executed successfully end-to-end by hand. Residual risk is low and confined to environment differences between an interactive session and cron (`PATH`, no TTY) — real but unlikely, since every other job on this host runs fine under the same wrapper.

#### Expected Slack behaviour on the first clean run — do not misread it

The wrapper sends a **recovery notification** when the previous run failed (`enhanced_monitoring_wrapper:402`), and that goes to `$monitor_hook` → **`#home-logging`**, not `#home-alerts` (`:420`). So the first clean run of each script produces **one message in `#home-logging`** (recovery, coinciding with the daily heartbeat) and **zero in `#home-alerts`**.

That is success, not a residual failure. The acceptance test is therefore precise: **any `Script Failed on hifipi` in `#home-alerts` after 2026-08-02 means the fix did not work.** A `#home-logging` message is expected and correct.

### Incidental findings on hifipi (not investigated)

- Slack webhook tokens are literal in every crontab line — the same instance as Priority 3 below, observed again here.
- Stale artefact deployed alongside real scripts: `~/.scripts/do_backup.127013.2026-03-14@17:07:39~`. Harmless; folds into the clutter cleanup item below.
- `system_health_check` reports **194 pending updates** (informational, not alerting). `unattended-upgrades` is running and last upgraded 2026-08-02, so this is the usual non-security backlog rather than a stalled updater — worth a glance at the laptop, not an action item.

### Interim manual mitigation (hand-applied from a phone)

Constraints at the time: owner remote with phone-only SSH to hifipi — no laptop, so no Ansible deploy, and no `git push` (Touch ID). `read_agent` is read-only, so the agent could not apply it either. The fix was therefore written to the repo *first* and then hand-transcribed, so the two are byte-identical by construction and the eventual Ansible run is a true no-op, **not drift**.

Procedure: back up both scripts to `~/*.bak.20260802`, then `cat > ~/.scripts/<script> <<'EOF' … EOF` with the exact repo contents of `scripts/services/audio/{check_audio_output,restart_audio_services}.sh`, then `chmod 755`.

**The verification that makes this safe** — these must match the repo exactly:

```
4eaeef7b4c269e3e57de2dbadcac2632300a7aa7  check_audio_output.sh
aafb6939693bb06e262dccc363c845aae7fbb40f  restart_audio_services.sh
```

If a hash differs the paste was mangled (phone keyboards, smart quotes, the em-dash in the restart script's comment) — restore from `~/*.bak.20260802` rather than hand-patching.

Smoke test: `~/.scripts/check_audio_output.sh` → `✅ Audio system is configured correctly (DAC volume: 100%)`, exit 0. Note this does **not** exercise the new `sudo /usr/sbin/alsactl store`, which only runs when DAC < 90%. Only `restart_audio_services.sh` exercises it — and that restarts MPD/Shairport/Raspotify, so run it deliberately, not while listening.

- [ ] Delete `~/check_audio_output.sh.bak.20260802` and `~/restart_audio_services.sh.bak.20260802` once the repo fix is deployed and verified

### Fleet-wide drift audit (done this session — no systemic problem)

Checksummed every deployed script against its repo counterpart on all six Debian hosts:

| Host | Checked | Drifted |
|---|---|---|
| dockassist | 34 | 0 |
| cobra | 24 | **1** (inactive, see below) |
| hifipi | 16 | **2** (this issue) |
| vinylstreamer | 13 | 0 |
| cwwk | 14 | 0 |
| unifi | 12 | 0 |

Also confirmed **every cron entry on every host is Ansible-managed** (job count == `#Ansible` count on all six) — no unmanaged scheduled code anywhere.

- **cobra `internet_speed_monitor` — stale but inert.** A pre-migration copy, older than `a000f71`, missing the `type:"result"` JSON filter. It is *not* in cobra's crontab and *not* called by `run_all_monitoring.sh`. The live copy is owned by the **homeassistant** role on dockassist (`roles/services/homeassistant/tasks/main.yml:467`) and is in sync. Orphaned leftover; delete rather than deploy.
- Remaining unmatched files are benign: rendered `.j2` templates (`dockassist_monitor.sh`, `vinylstreamer_monitor.sh`, `backup_ha`, `update_ha`), scripts generated inline by task files (`check_auto_updates.sh` → `debian_updates.yml`, `check_ssh_security.sh` → `ssh_hardening.yml`, `run_all_monitoring.sh` → `deploy_monitoring.yml`), and manual `*.bkp` / `test*` leftovers.
- **`import_gpg_github.sh`** is on every host with no repo counterpart and no inline generator — genuinely unmanaged, but not scheduled. Low priority; identify and either codify or delete.
- ⚠️ **OPNsense was NOT audited** — `read_agent` has no key there (`opnsense-agent`: `Permission denied (publickey)`). Its 13 scripts under `scripts/services/opnsense/` are unverified. See Priority 2.

### Prevention — the more valuable half

- [ ] Repo-vs-host drift on role-owned scripts is currently **undetectable**: `deploy_monitoring.yml` reports success while leaving them stale, with no failing signal. Options, cheapest first:
  1. Fix `CLAUDE.md`, which describes `deploy_monitoring.yml` as "Deploy monitoring scripts to all hosts" — it deploys only `scripts/common/`. **That wording is what made this trap invisible; do this one regardless.**
  2. Add a periodic checksum drift check (repo vs host) alerting to `#home-logging`. The audit loop above is the prototype — note `ssh` inside a `while read` loop eats stdin; use `ssh -n`.
  3. Extend `deploy_monitoring.yml` to also sync `scripts/services/*/` by `primary_function`, so the obvious playbook does the obvious thing.
- [ ] Clean up: cobra's orphaned `internet_speed_monitor`, and the `*.manual.bkp` / `monitoring_wrapper.last.working` / `test*` clutter in `~/.scripts` fleet-wide.

---

## Cabinet-Wide Thermal Monitoring — ambient sensing + fan strategy (NEW, 2026-08-01)

**Risk:** Medium. The cabinet holds cwwk (→ OPNsense → all internet), several Raspberry Pis, and a 10Gb switch. Today thermal health is inferred *only* from CPU die temperatures, which conflate workload with airflow — and only cwwk has any thermal history at all. Neither 2026-06-30 nor 2026-07-31 was detected as "the cabinet lost cooling"; both surfaced as CPU throttle alerts after the fact.

### The gap
- **No ambient sensor in the cabinet.** cwwk's `acpitz` is the only proxy (27.8°C on 2026-08-01 vs 26.5°C living room) and it is a motherboard sensor, not cabinet air.
- **No temperature history for the Pis.** `save_temps.sh` is proxmox-only. Spot check 2026-08-01: hifipi 69°C, cobra 56°C, dockassist 56°C — but with no baseline there is nothing to compare against. hifipi in particular is worth a baseline. **Cabinet contents: `cwwk`, the Zyxel switch, and the Pis `cobra`, `hifipi`, `dockassist`. `vinylstreamer` is NOT in the cabinet** (confirmed 2026-08-02) — it read 45°C against the others' 56–70°C in the same sweep, so it makes a useful *control* for house ambient but must be excluded from cabinet heat-budget calculations.
- **No telemetry at all from the 10Gb switch**, which the operator reports runs hot.

### Next Steps
- **Switch telemetry: RESOLVED — none available.** The 10Gb switch is a **Zyxel XGS1250-12**, *not* UniFi, so it is invisible to the `unifi-lxc` controller. It is a *web-managed* (not smart-managed) switch and **does not support SNMP**, confirmed by Zyxel staff on their own community forum: *"the XGS1250-12 is designed primarily for basic home use and small office setups, which is why it currently does not support SNMP"* — with SNMP "under evaluation" but at "currently low" priority. Source: <https://community.zyxel.com/en/discussion/21955/support-snmp-feature-on-xgs1210-12-xgs1250-12>
- **BUT there is an indirect signal — the switch's own Overheat Protection.** Verified in the official user guide §7.3: *"If any 10G Ethernet copper port on the XGS1250-12 overheats for too long, the port speed will decrease from 10 Gbps to 1 Gbps for Switch protection."* The web UI flags it with an exclamation icon and offers a **Restore** button to force the port back to 10 Gbps; if the underlying heat problem persists, *"protection will be triggered again and the port speed will change back to 1 Gbps."* The guide also specifies **ambient air around the switch must not exceed 40°C**, which gives a citable threshold for the cabinet sensor. Recent firmware additionally added "Smart Fan" control that ramps the fan at high temperature — so the switch actively cools itself and is *designed* to run warm.
- **That free monitoring path does NOT apply to this topology — checked and ruled out (2026-08-01).** The single 10G link is cabled to cwwk but PCI-passed-through to the **OPNsense VM (100)**, so it terminates in FreeBSD. `ifconfig` on opnsense reports `ix0: media: Ethernet autoselect (`**`10Gbase-Twinax`**` <full-duplex,rxpause,txpause>)` — i.e. an **SFP+ DAC** link on the switch's SFP+ port, *not* one of its three 10G **copper** ports. Zyxel's Overheat Protection is documented only for *"any 10G Ethernet **copper** port"*, so there is no downshift signal to watch here. Correction to an earlier note in this file: the web UI shows no *numeric temperature*, but it does surface a binary overheat indicator (for copper ports).
- **Thermal upside of that topology.** 10GBASE-T copper PHYs are the dominant heat source in this class of switch (roughly 2–5W per active port); a passive SFP+ DAC is a fraction of that. With the three 10G copper ports unused and everything else at gigabit, **the switch is already running in its lowest-heat configuration** — which is consistent with Overheat Protection never having tripped. If the 10G copper ports are ever populated, expect a materially hotter switch and revisit this.
- **Net: no switch telemetry of any kind is obtainable.** External probe confirmed as the only route.
- **Baseline as of 2026-08-01:** the Zyxel web UI reports the port at **10G**, i.e. Overheat Protection has *not* triggered despite the heatwave and the cabinet fan being dead. The switch running warm to the touch is so far not corroborated by any distress signal from the switch itself.
- **Conclusion: no numeric temperature is obtainable from the switch by any means.** An external probe remains the only way to get a real reading, which makes the cabinet ambient sensor below the single highest-value item in this section rather than a nice-to-have.
- **Add one cabinet ambient sensor.** Cheapest path that fits the existing stack: a Shelly H&T (or Shelly Add-On + DS18B20 probe) reporting into HA via the existing authenticated Mosquitto broker on dockassist. This is the sensor that would have caught *both* incidents directly, as an airflow signal rather than a CPU-load signal.
- **Alert on ambient, not just on die temps.** A cabinet-ambient threshold is the honest "the cabinet is too hot" alert the current throttle alert is standing in for.
- **Extend `save_temps.sh` fleet-wide** (or a lightweight equivalent) so the Pis get the same thermal history cwwk has. Low effort, makes any future "is this hot?" question answerable with data instead of a spot check.
- **Fan strategy — see the design lesson in the cwwk section above.** Preference is a dumb always-on fan on unswitched power. An external thermostat (e.g. Inkbird ITC-308 driving a mains fan) was considered; it is acceptable *only* if wired fail-safe (fan ON on controller fault/power loss), since fail-off is the exact mechanism behind both outages. A Shelly plug + HA automation gives telemetry and control but adds a circular dependency (HA runs on dockassist, inside the same cabinet).

### Acceptance Criteria
- [x] Zyxel switch telemetry question answered — **XGS1250-12 has no SNMP and no temperature readout; external probe is the only route** (verified 2026-08-01 against Zyxel staff statement)
- [ ] Cabinet ambient temperature visible in HA and retained in the recorder
- [ ] Ambient-based alert to #home-alerts, verified end-to-end
- [ ] Pi temperature history collected fleet-wide
- [ ] Cabinet fan cannot end up OFF after a power cut or a human switching it

---

## Priority 1 — Autonomous Agent LXC (Phases A + B delivered; C remains)

**Risk:** Medium. A production container with SSH reach to all 7 hosts. Compromise exposes read-only infrastructure visibility plus a spend-capped API key. Scoped by `from=` IP pinning on `authorized_keys`, read-only NOPASSWD sudo, OpenCode `deny` on all writes, UFW default-deny inbound, and revocation in one Ansible run.

### Status

**Phases A and B are built and live** (A 2026-07-22, B 2026-07-25/26). CT 103 (`agent-lxc`) runs the free hourly Tier 1 sweep, plus Tier 2 investigation on OpenCode + Sonnet 5: anomaly-triggered, Slack-alert-triggered, and a weekly digest. It has produced real root-caused plans for real failures (hifipi audio-check bug, HA backup tar race, a failing smartmontools unit). **Full operator reference: [`docs/AGENT_LXC.md`](AGENT_LXC.md).** Decision log: `docs/ARCHITECTURE_DECISIONS.md` § Agent LXC.

**Only Phase C (operator mode) remains** — see below. One Phase-B acceptance criterion is deliberately deferred with a documented decision: the destroy/rebuild reproducibility test (SSH-key management), covered under "What remains".

### What Phase A delivered

- `ansible/playbooks/provision_agent_lxc.yml` — creates CT 103 via `pct` (unprivileged, 1 vCPU / 2GB / 16GB on `local-zfs`, `onboot: 1`, static 10.30.40.203, `searchdomain local`), installs the minimum for Ansible to adopt it, and seeds `authorized_keys`. Idempotent: second run is `changed=0`.
- Inventory `agent-lxc` (`container_id: 103`, `primary_function: agent`, `enable_ufw: true`) + `group_vars/agent.yml`.
- `roles/services/agent/` — generates the container-resident `agent_lxc_ed25519`, deploys the fleet `~/.ssh/config`, the Tier 1 script, and its hourly cron under `enhanced_monitoring_wrapper`.
- `scripts/services/agent/fleet_health_check.sh.j2` — per host: reachability, disk, failed systemd units, monitoring-run freshness; plus zpool health and onboot-aware CT/VM state on cwwk, and disk/default-route on opnsense. Writes `~/.agent/last_anomaly.json` on a finding (the Phase B trigger input).
- `agent_access` gained per-key `alert` control and a per-sender cooldown.

### DNS for agent-lxc — DONE 2026-07-22

The container has a **static IP set in its `pct` config**, so it never requests a DHCP lease and cannot be registered the way the Raspberry Pis are (they have DHCP static mappings, which Unbound registers automatically). The two statically-addressed hosts most like it — `unifi` (CT 101) and `cwwk` — are registered as **Unbound Host Overrides** in `config.xml` (`<host>` entries with `<domain>local</domain>`, `<rr>A</rr>`, `<addptr>1</addptr>`). That is the pattern to follow.

Added via the UI on 2026-07-22 and verified: `dig +short @10.30.40.254 agent-lxc.local` returns `10.30.40.203`, reverse returns `agent-lxc.local.`, and `ssh agent-lxc` works (its host key needed adding to `known_hosts` under the new name). Note the inventory still pins `ansible_host: 10.30.40.203` deliberately, so Ansible can still reach the observer when DNS or OPNsense is the thing being diagnosed. This only affects typing `ssh agent-lxc` as a human.

**To add** — Services → Unbound DNS → Overrides → Host Overrides → **+**:

| Field | Value |
|---|---|
| Host | `agent-lxc` |
| Domain | `local` |
| Type | `A (address)` |
| IP address | `10.30.40.203` |
| Add reverse DNS | ☑ (matches `unifi`/`cwwk`) |
| Description | `Agent LXC (CT 103) — fleet observer` |

Then **Save** → **Apply**. Verify with `dig +short @10.30.40.254 agent-lxc.local` (expect `10.30.40.203`).

There is no CLI path today: the only OPNsense-adjacent vault key is `vault_ns_api_key`, which is the Dutch railways key for HA train notifications, not an OPNsense API credential. Provisioning a scoped OPNsense API key would make this and future firewall changes automatable — worth considering separately, since it also unblocks any future infrastructure-as-code for OPNsense.

### What remains

**Phase B is done** (OpenCode + Tier 2, live 2026-07-25/26; see `docs/AGENT_LXC.md`). Two spend-capped credentials in the vault (`vault_anthropic_api_key`, `vault_slack_read_token`); everything verified live except the rebuild test below.

**Phase C — operator mode. Designed, not built. This is the sprint *after* the current one.** The decision round this line used to call for happened on 2026-07-26 and is settled in `~/.claude/plans/phase-c-operator-plan.md` §0: **no dedicated operator key, no operator user, no scoped sudo, no `operator_access` role.** Access is `choco` via the existing per-device Secure-Enclave biometric keys, forwarded — nothing new is created. Every command is gated twice, by an OpenCode `ask` and a biometric tap, and there is no headless path. The plan files Phase B writes are its input, already in a stable format.

Two additions from 2026-08-05, both in the plan as §0b/§0c:
- **The test rig changes what approval means.** As designed you approve a command that has never run anywhere. With CT 199/198 the flow becomes propose → dry-run on a container → present the diff **and the test result** → approve → apply. A plan whose dry-run failed is never offered; a plan that *cannot* be dry-run must say so, so a missing test result is never mistaken for a passing one.
- **Do not cut a Phase C branch yet.** `fix/agent-lxc-logs-dir-2026-08` already modifies `ansible/roles/services/agent/tasks/main.yml`, the same file Phase C changes, and deploying the agent role before the Tier 2 fixes restarts the CrowdSec ban loop. Cut `feat/agent-lxc-phase-c` off main *after* that branch merges.

Independent of all of it, and needing no branch: add the phone's SSH key to GitHub (the exclusive GitHub-keys mechanism then authorises it for `choco` fleet-wide) and add a `ForwardAgent` stanza for agent-lxc to the laptop's `~/.ssh/config`. Agent forwarding on the phone needs a client that supports it — Termius does, on its paid tier; other clients are under consideration. The design does not depend on which one wins, so this is not a blocker.

**Follow-up surfaced while building Phase B** (small, not blocking):
- **`read_agent` can read Slack tokens via the cron journal** — the wrapper cron lines carry the webhook tokens, and `journalctl -u cron` is permitted. This is Priority 3 (tokens out of cron); Phase B's `0600` env-file pattern is the model to extend fleet-wide.

**Rebuild reproducibility + agent SSH-key management — `V:High E:Med`, deferred 2026-07-25.** The "destroy and recreate CT 103 from Ansible with nothing but the vault password" criterion (below) is **unverified**, and there is a known reason to expect it currently *fails* as written: `roles/services/agent` generates `agent_lxc_ed25519` fresh on the container, and its public half is hard-committed in `group_vars/all/main.yml` as `agent_lxc_ssh_pubkey`. A rebuild therefore mints a **new** keypair whose pubkey must be copied back into `group_vars` and pushed fleet-wide via `agent_access.yml` — a manual step beyond the vault password. Two ways to close it, decide before testing:
  1. **Accept + document** — a rebuild is rare; treat "capture the printed pubkey → commit → re-run agent_access" as a documented two-command step, and reword the criterion.
  2. **Vault the keypair** — store `agent_lxc_ed25519` (private + public) in the vault and deploy it on rebuild, so identity is stable and rebuild really is vault-password-only. Trade-off: the private key now lives in the (encrypted, committed) vault instead of never leaving the box — a weaker but arguably acceptable posture for a read-only, IP-pinned, one-run-revocable key.
  The actual destroy/recreate test is disruptive (~15-20 min, the box is now doing real work) so it is deferred; do it under option (1) or (2), not blind. This is the single highest-value unproven claim about the system.

### Acceptance Criteria
- [x] CT 103 exists, runs, `onboot: 1`
- [x] Provisioning playbook is idempotent — second run changes nothing
- [x] `ssh agent-lxc` works from the laptop
- [x] `site.yml --limit agent-lxc` converges to `changed=0` on the second pass
- [x] Container SSH key accepted on all 7 hosts, IP-restricted — sweep reports `7/7 hosts reachable` in ~12s; `agent_access.yml` is `changed=0` fleet-wide on re-run
- [x] A synthetic Tier 1 fault produces a real `#home-alerts` message, and recovery clears — verified in Slack (`ALERT: Script Failed on agent-lxc`, 09:06:02), plus a valid `last_anomaly.json`
- [x] Opportunistic: the key is rejected from a source other than 10.30.40.203 — throwaway key pinned to `192.0.2.1` was denied from the container; file restored by re-running the role
- [x] **Phase B:** permission tests fail closed — a write auto-rejects headless (file absent); `ssh` to a non-`-agent` host is denied
- [x] **Phase B:** a synthetic anomaly, and three *real* `#home-alerts` failures, each produced a coherent Slack summary + a plan file, zero human steps
- [x] **Phase B:** the weekly digest runs end-to-end (swept all 7 hosts, clean summary to `#home-logging`, ~$0.51)
- [x] **Phase B:** the agent uses the scoped-read helpers — a re-investigation read the actual check script and produced a materially better root cause
- [ ] **Phase B (deferred):** container can be destroyed and recreated by Ansible with no manual step beyond the vault password — unverified, and expected to fail as written (SSH-key regeneration); see "Rebuild reproducibility" above for the two options and decide before testing

**Amended from the original plan:** the criterion "each use fires the existing `ssh_alert` Slack ping" was deliberately dropped. At hourly × 7 hosts it meant ~168 pushes/day into the watched channel, and it would have kept the shared 30-minute cooldown permanently hot, *suppressing the laptop key's alerts* — the opposite of a control. Replaced with journal attribution, verified live: sshd records `Accepted publickey for read_agent from 10.30.40.203 ... SHA256:fpnOSa5…` persistently, and Slack shows the laptop's ping firing while the container produced none.

---

## ✅ opnsense `scripts_dir` — MADE CONSISTENT 2026-08-06 (not deployed)

Branch `refactor/opnsense-scripts-dir-2026-08`. `/usr/local/bin` → the fleet default `/home/choco/.scripts`, set at the `freebsd_hosts` group level rather than overridden per host.

**Two reasons, and one non-reason.** The host was already *half* consistent — logs went to `/home/choco/.logs`, only scripts were elsewhere — and `deploy_monitoring.yml` creates `{{ scripts_dir }}` owned by the infrastructure user, which is why the internet-facing firewall had a `choco:wheel` directory on root's `PATH`. ⚠️ **It is NOT an upgrade-durability fix and must not be recorded as one**: measured on the box, OPNsense reverts what it *generates* from `config.xml` and leaves files it never owned, and `/usr/local/bin` still holds our scripts from Nov 2025 across the June firmware upgrade.

**What the move had to carry, beyond the variable:**

- **Removal of the old copies** (`state: absent`). Ansible does not clean up after a moved path, and stale scripts that look current are the drift class that had hifipi running a four-month-old file. **The list is explicit and was enumerated from the live host** (`ls -l /usr/local/bin | awk '$3=="choco"'`), not from reading the role — the first draft, written from the role, was wrong in both directions. A wildcard was rejected: `/usr/local/bin` also holds `import_gpg_github.sh`, `switch-vpn-country.sh`, `monit-slack.sh` and `monit-slack.sh.old`, none of which this repo manages.
- **Restoring `root:wheel` on `/usr/local/bin`.** Ansible merely stops asserting `choco`; it does not chown back. Without this the security finding survives the fix that was supposed to address it, with nothing left in the repo to explain it.
- **Both tasks are LAST in the role, deliberately.** Everything above them deploys to the new location and repoints all 13 crons first, so a run that fails part-way leaves the old layout intact and working. Cleaning up first would open a window where the firewall's crons point at files that no longer exist — silently, which is this repo's signature failure.

**Checked before writing, not after:** every script reference in the role is `{{ scripts_dir }}`-relative, so nothing is hardcoded; the crons' `/usr/local/bin/bash` is the interpreter and is unaffected; and no script depends on `PATH` to find a sibling. `backup_last_mod` uses `$(dirname "$0")/do_backup`, which follows the move; `backup_opnsense.sh` searches `/usr/local/bin/do_backup` **then** `$HOME/.scripts/do_backup`, so it works before, during and after the transition.

🔴 **Post-deploy verification, corrected 2026-08-06 — the obvious check reads as a failure.** `crontab -l | grep -c /usr/local/bin` returns **13** today, and the instinct is to expect **0** afterwards. It will be **9**, and that is correct: **9 of the 13 crons invoke `/usr/local/bin/bash` as the interpreter** (8 from the monitoring loop plus the backup cron), which has nothing to do with `scripts_dir` and must not move. Counted from the role, and consistent with the independent 2026-08-06 crontab reading.

  So the check is two numbers, not one:

  ```sh
  crontab -l | grep -c /home/choco/.scripts   # expect 13  (was 0)
  crontab -l | grep -c /usr/local/bin         # expect 9   (was 13) — the bash interpreter
  ```

  ⚠️ **Verified against the live host before deploying, not after:** `ls -l /usr/local/bin | awk '$3=="choco"'` returns exactly the eight entries the removal task names — `backup_last_mod`, `backup_opnsense.sh`, `clean_old_backups.sh`, `do_backup`, `enhanced_monitoring_wrapper`, `heartbeat_backup.sh`, `system_health_check.sh`, `monitoring/` — plus `import_gpg_github.sh`, which is deliberately left alone. The list is complete and touches nothing unmanaged.

📌 Minor leftover, deliberately untouched: that `/usr/local/bin/do_backup` first entry becomes a dead path once the cleanup runs. Harmless — it is a fallback list and the file will not exist — but worth removing next time that script is edited.

---

## Priority 2 — read_agent on OPNsense: RESOLVED as far as it can be (detection is the remainder)

**Status 2026-07-21: mitigated, not eliminated — and eliminating it is not possible without granting the agent full firewall admin.** Kept as a priority only for the detection half, which rides on Priority 1.

### What Happened
`ssh opnsense-agent` failed `Permission denied (publickey)` while the other 6 hosts were fine. The `read_agent` account was **gone** — home dir and `authorized_keys` survived as orphaned uid 2001, and `sshd_config` had reverted to `AllowGroups wheel`. Cause: the 2026-06-13 upgrade to OPNsense 26.1.9 (`pkg query` timestamp), between the 2026-04-07 rollout and discovery. `local_sync_accounts` (`auth.inc`) enumerates accounts with uid ≥ 2000 and reconciles them against `config.xml`, deleting anything absent. `choco` survived because it is a config.xml user. Undetected for ~3 months.

### Why the obvious fix is closed
Creating the account in OPNsense's user manager so it lives in `config.xml` **was tried live and does not work for a least-privilege account.** `local_user_set` (`auth.inc:351`):

```php
$is_admin = userIsAdmin($user['name']);
$user_shell = $is_admin && !empty($user['shell']) ? $user['shell'] : '/usr/sbin/nologin';
```

`userIsAdmin()` is `userHasPrivilege(…, 'page-all')` — full GUI administrator. **OPNsense has no concept of a non-admin account with a login shell**; the `<shell>` field is ignored unless the user is an admin. Observed exactly that: the UI-created user passed key auth, then `This account is currently not available`. It is also *worse* than `pw` management — a config.xml account has its shell reset on every config apply, not just upgrades. Granting `page-all` to fix it would hand a read-only agent complete control of the firewall. Route closed; see `docs/ARCHITECTURE_DECISIONS.md`.

### What was done instead
- **Account stays `pw`-managed**, expected to be wiped by firmware upgrades, with recovery reduced to one idempotent command: `ansible-playbook ansible/playbooks/system/agent_access.yml --limit opnsense` — **verified from a fully wiped account: ~9s, all access restored, second run `changed=0`.** Documented with symptoms in `docs/AGENT_ACCESS.md`.
- **sshd `AllowGroups` made genuinely durable.** The role's `lineinfile` on `sshd_config` was erased by upgrades *and* by any SSH settings change (`openssh.inc` hardcodes `AllowGroups wheel`). Replaced with `/usr/local/etc/ssh/sshd_config.d/10-read_agent.conf`, the documented override point — `Include`d at the top of the generated config, and sshd takes the first value per keyword. `sshd_config` itself is now left at OPNsense's native `AllowGroups wheel`, so regeneration is a no-op. Verified by reverting sshd_config to its native state and confirming login still works, plus `sshd -T`.

So the sshd half is now upgrade-proof; only the account itself still needs the one-command repair.

### Remaining work — detection only
Nothing currently alerts when agent access breaks, on any host, for any reason. That is what turned a routine upgrade side-effect into a 3-month blind spot. **This is already covered by Priority 1**: `fleet_health_check.sh` (Phase A step 5) iterates `ssh <host>-agent` across the fleet hourly and fails on unreachability. No separate work — just don't drop that check from Tier 1.

Until the LXC lands, the gap is open and the only detection is someone trying to use it.

### Acceptance Criteria
- [x] Recovery is a single idempotent command, verified from a fully wiped account
- [x] sshd `AllowGroups` survives sshd_config regeneration
- [x] The closed config.xml route is documented so it is not retried
- [ ] Loss of agent access on any host raises an alert within a day (via Priority 1 Tier 1)
- [ ] Survives the next real firmware upgrade — confirm `ssh opnsense-agent` afterwards, run the repair if not

---

## 🔴 Nothing tells you a host needs attention — raised 2026-08-07, and it is a gap not a trade-off

Raised while reviewing the cwwk auto-reboot decision: *"I don't know if I'll know I need to do anything on those hosts until I access them."* That is correct, and the honest accounting is worse than it first looks, because the decision above **creates** the exposure it does not cover.

**What IS covered once this sprint deploys:**

- A pending kernel/libc reboot on any Debian host → `check_pending_reboot` → **error after 7 days** → `#home-alerts`. ⚠️ For the **first 7 days it is a warning**, and warnings exit 0, so they land in `#home-logging`, which is an unwatched firehose. The window is deliberate — it is what makes rebooting the hypervisor a choice rather than a page — but it is a *silent* window, not a quiet one.

**What is covered by nothing at all:**

1. **🔴 Proxmox VE package updates on cwwk.** `unattended-upgrades` origins are **Debian-Security only**, so PVE packages — *including PVE kernel updates* — are neither installed automatically nor reported anywhere. Proxmox's own mechanism is an email to `root@pam`, and nothing in this repo configures where that goes. **This is precisely the case the `auto_reboot: false` decision was about**: the reboot was made a human decision, and the update most likely to require one is invisible.
2. **🔴 OPNsense firmware updates.** No script, no check, nothing. The 26.1.9 upgrade of 2026-06-13 — the one that deleted `read_agent` and went unnoticed for three months — would have been visible only in the GUI. There is no repo-side awareness that the firewall has an update pending, or that one was applied.
3. **🟠 Non-security apt updates on every Debian host.** `check_auto_upgrades` counts them and prints `Pending updates: N (informational)` with an explicit comment saying it deliberately never alerts. Defensible for security updates, which install themselves — but it means an arbitrarily large backlog of everything else is invisible by design.

**Why this is a gap and not a considered trade-off:** in each case the *absence* of notification was inherited, not chosen. Nobody weighed "we will find out about firewall firmware when we happen to open the GUI" and accepted it. `read_agent` disappearing for three months is what that costs in practice.

### 📌 The broader question, and it is the right one

Raised in the same breath: *"what other similar risks are we just accepting blindly?"*

**This sprint has been entirely about a different class.** Every fix here — the exit status that was always 0, the state-file collision, the tag mismatch, the re-billing snapshot — is a check that *existed and did not work*. The class above is **things nothing watches at all**, which no amount of fixing existing checks will surface, because there is nothing to fix.

Those need a different method: enumerate what would have to go wrong for each host to matter, then ask which of those has an alerting path — rather than starting from the checks that exist and asking whether they work. **Proposed as its own piece of work, after Phase C**: a coverage audit per host, output being a table of *failure mode → what tells you → how fast*, with the blanks made explicit. The blanks are the deliverable.

⚠️ Do not fold this into any `L` session. It is not a fix; it is a review, and its value is entirely in being systematic.

---

## ✅ cwwk auto-reboot — DECIDED AND WRITTEN 2026-08-06 (not deployed)

Branch `chore/cwwk-no-auto-reboot-2026-08`. `auto_reboot: false` at host level on cwwk; every other Debian host keeps `true`.

**Provenance, corrected mid-investigation.** The first answer named
`tasks/debian_updates.yml`'s `lineinfile` tasks — **wrong**: they are gated on
`auto_reboot is defined`, which was never true anywhere, so they had never run.
The setting comes from `templates/debian/50unattended-upgrades.j2:53`,
`{{ auto_reboot | default(true) }}`, deployed unconditionally. The capital `T`
in the live `"True"` was the right clue pointing at the wrong task. Confirmed a
third way: cwwk's live file carries `// Generated by Ansible - 2026-03-30`,
matching its mtime.

**Three things this change had to carry, none of them optional:**

1. **The two dead `lineinfile` tasks are deleted, and that is a correctness fix rather than tidying.** Their regexps match the *commented* stock lines, which the template does not emit. Defining `auto_reboot` for the first time — which this change does — would have made them live, found nothing to match, and appended a **second, conflicting `Automatic-Reboot` directive** to a file the template had just written. The bug was latent only because the variable was undefined.
2. **The render timestamp is gone from the template.** `// Generated by Ansible - {{ ansible_date_time.iso8601 }}` made the deploying task report `changed` on every host on every run, forever — the same defect `deploy_monitoring.yml`'s restart task was already fixed for, where permanent churn masks the diffs that matter. It cost a real verification here: with it, a run that flipped cwwk's flag was indistinguishable from a run that changed nothing. Two renders a second apart are now byte-identical.
3. **`check_pending_reboot` ships first.** Different branch, different playbook — see the pending-reboot section above. Without it this is a downgrade.

**Verified by rendering against each host's real variable scope and diffing against the live file:**

```
dockassist   only the header line changes
cwwk         the header line, plus line 43:
             - Unattended-Upgrade::Automatic-Reboot "True";
             + Unattended-Upgrade::Automatic-Reboot "False";
```

That is the whole blast radius, measured. **Deploy order: `deploy_monitoring.yml` (the check) → `platform/debian.yml --tags updates` (this).**

---

## Priority 3 — Healthchecks.io + Slack Tokens Out of Cron Command Lines

**Risk:** Medium (hygiene, not exploitable in place). Promoted from Lower Priority on 2026-07-21: it should land *before* the Agent LXC bakes another consumer of `enhanced_monitoring_wrapper` into the fleet, rather than after.

Every monitoring cron across the fleet embeds both healthchecks.io tokens and the Slack webhook as positional args to `enhanced_monitoring_wrapper`. Tokens surface in `ps`, `crontab -l`, `--diff` output, and cron-mail subjects — observed repeatedly during the 2026-07-01 cwwk session. For a personal box with no untrusted users it's tolerable (the tokens only authorize pings to a public endpoint), but it is not portfolio-clean.

Cleaner pattern: env file at `/etc/monitoring/tokens.env` (`0600`) sourced by the wrapper. Scope: refactor the wrapper with a positional-arg fallback during rollout, deploy `tokens.env` from vault before any cron task uses it, strip token args from every `cron:` task across roles, then a coordinated redeploy. Given the repeated exposure, **rotate the two webhooks** as part of this.

See `memory/followup_tokens_in_cron.md` for the full kickoff context.

---

## Priority 4 — SMART Disk Health Monitoring — DONE 2026-07-26

**Risk (was):** Medium. `rpool` on cwwk is the single storage layer under every VM/CT (including the agent LXC); cobra's T7 holds the Plex library. Neither had any early-warning signal — first sign of trouble would have been a ZFS scrub error or a dead drive.

**Delivered:** `smart_monitoring` role (top-level, gated on `enable_smart_monitoring`, mirrors the `agent_access` cross-cutting pattern) + shared `scripts/services/storage/check_smart_health.sh`, deployed to cwwk and cobra via `ansible/playbooks/system/smart_monitoring.yml` (wired into `site.yml` Phase 6b and `deploy_monitoring.yml`). Daily cron (06:17) under `enhanced_monitoring_wrapper`.

### What the original sketch got wrong (verified on hardware 2026-07-25)
Both drives are **NVMe**, not ATA — so there is no attribute table, no `Reallocated_Sector_Ct` / `Current_Pending_Sector`. The check parses the **NVMe health log** instead (`smartctl -j -x`, JSON via `jq`):
- cwwk `rpool` = `/dev/nvme0n1`, native NVMe (`nvme:` spec).
- cobra media = Samsung **T7**, an NVMe SSD behind an **ASMedia USB bridge**. Plain smartctl and `-d sat` both fail to pass SMART through; it needs **`-d sntasmedia`** (`sntasmedia:` spec). This was the make-or-break unknown and is the main reason the parser had to be designed against real output, not the sketch.
- Boot media (cwwk USB-flash recovery, cobra SD card) deliberately out of scope — no useful SMART, and the recovery drive is already covered by backup-freshness monitoring.

### Thresholds (env-overridable)
`smart_status.passed == false`, `critical_warning != 0`, or `available_spare < available_spare_threshold` (compared against each drive's **own** reported threshold — they differ, 1% vs 10%) → CRITICAL. `media_errors >= 100`, `temperature >= 75°C` → CRITICAL; `media_errors >= 1`, `percentage_used >= 90%`, `temperature >= 65°C` → WARNING. Unreadable/wrong-bridge output → WARNING (doesn't hard-fail on a transient USB hiccup).

### Privilege
Cron runs as `choco` (already `NOPASSWD: ALL`, like every other privileged check); the script escalates via `sudo -n /usr/sbin/smartctl`. No dedicated sudoers rule — it would be redundant and inconsistent with the rest of the monitoring.

### smartd masked (resolves the "failing smartmontools unit" the agent LXC found)
Installing the package auto-enables the `smartd` daemon. We poll on-demand via cron, not the daemon, so the role masks `smartmontools.service` and clears its lingering failed state (`reset-failed`). On cobra smartd was *failing* — it can't poll the T7 through its USB bridge without `-d sntasmedia`, which its default `DEVICESCAN` doesn't apply — which is exactly the failed unit the Tier 1 sweep flagged. One SMART path now, no dead daemon; both hosts report 0 failed units.

### Acceptance Criteria
- [x] `smartmontools` installed on cwwk + cobra (cwwk already had it as a Proxmox dep)
- [x] `check_smart_health.sh` alerts on concerning NVMe health fields — CRITICAL/WARNING/unreadable/no-args paths all unit-tested via fixtures
- [x] Cron runs daily via `enhanced_monitoring_wrapper` on both hosts
- [x] Slack alert fires on test with simulated threshold breach — forced CRITICAL through the real wrapper produced a `#home-alerts` ALERT; recovery run cleared it (state left OK)
- [x] Idempotent — `smart_monitoring.yml` reports `changed=0` on a second run
- [x] Verified via the real production path (script run as `choco` using `sudo -n smartctl`, both drives OK)

### Follow-ups (minor, not blocking)
- The daily cron embeds the Slack tokens in the command line — another instance of **Priority 3**, which will strip them fleet-wide. Consistent with every existing check until then.
- Only the primary data drive per host is monitored. If a second non-redundant drive is ever added, append its `TYPE:DEVICE` spec to that host's `smart_devices`.

---

## Priority 5 — cwwk Memory Optimization (OPNsense VM)

**Risk:** Low. OPNsense is allocated 12GB but only uses ~3.5GB (175M active + 2GB wired + 1.3GB ZFS ARC). 8.6GB is completely free inside the VM. Reducing the allocation from 12GB to 6GB would free 6GB for the hypervisor while leaving OPNsense with ~2.5GB headroom. Requires VM restart = brief network outage.

### Current cwwk Memory Allocation
| Resource | Allocated | Actual Use | Notes |
|----------|-----------|------------|-------|
| OPNsense (VM 100) | 12 GB | ~3.5 GB | 8.6GB free inside VM |
| UniFi (LXC 101) | 4 GB | ~1.4 GB | Java 1.1G + MongoDB 270M |
| pihole (LXC 102) | 2 GB | Stopped | `onboot: 0` |
| ZFS ARC | 10.7 GB max | ~10.2 GB | Shrinks on demand |
| **Total host** | **32 GB** | **~26 GB** | 5.4 GB available |

### Recommended Changes
- Reduce OPNsense from 12GB → 6GB (saves 6GB, requires VM restart)
- Optionally reduce UniFi from 4GB → 2GB (saves 2GB, requires LXC restart)
- Net result: ~13GB additional headroom for ZFS ARC and future LXCs

### Next Steps
1. Schedule a brief maintenance window (VM restart = ~30s network outage)
2. `sudo qm set 100 -memory 6144` on cwwk
3. Restart VM: `sudo qm shutdown 100 && sudo qm start 100`
4. Verify OPNsense starts normally and all WireGuard tunnels come up
5. Optionally: `sudo pct set 101 -memory 2048 && sudo pct restart 101`

---

## Lower Priority

These items have value but are not urgent. Ranked by value-to-effort ratio to help pick low-hanging fruit. Revisit quarterly.

### High Value/Effort — Quick wins worth picking up

- **The network layer has no source of truth outside `config.xml`** `V:High E:Med` — Surfaced 2026-08-04 in a session that probed the live firewall and then wrote nothing down; recorded here 2026-08-05 before that session is cleared. **These figures were read off `opnsense` by that session, not re-verified since** — treat as a starting point, not gospel.

  Every other layer of this infrastructure is reconstructible from the repo. This one is not. Grepping the whole repo for VLAN/WireGuard/subnet facts returns one line in `CLAUDE.md`, one in `README.md`, and some hardcoded `10.30.40.x` test IPs. What was actually running: **6 VLANs** (`.20`, `.40`, `.80`, `.100`, `.200` on `ix0`, WAN on `.300`/`igc0`) where only `.40` appears in the repo incidentally; **13 WireGuard tunnels** (`wg0`, `wg2`–`wg12` sharing one Mullvad exit address, plus `wg1` = `10.30.41.0/24` inbound with ≥3 peers); **131 pf rules**; and **policy routing that pins `9.9.9.9` down `wg9`** — DNS forced through one specific exit. None of it documented anywhere.

  That last one is the argument for the whole item: it exists only in Ignacio's head, and an agent debugging DNS would never find it. Two recent incidents were network-layer failures diagnosed blind — the CrowdSec ban that gateway-blocked agent-lxc, and the port-53 interception that broke the connectivity test's first design. `docs/BACKUP_AND_RECOVERY.md` already calls the OPNsense config "highest risk — loss means full manual rebuild of 13 WireGuard tunnels" and then describes not one of them.

  **Format: Mermaid in markdown, not Excalidraw** — despite Excalidraw looking better. Excalidraw is a JSON blob: diffs are unreadable so drift is invisible, and an agent loading it gets noise instead of facts. Mermaid greps, diffs and reviews, and `docs/AUDIO_AUTOMATION.md` already proves the pattern here. If a pretty version is wanted, Mermaid stays canonical and the export is derived — never the reverse.

  ⚠️ **The repo is public.** The live config contains the WAN address, Mullvad endpoint IPs and peer public keys. **None of that goes in** — RFC1918 internals, VLAN roles and tunnel *purposes* are publishable; anything identifying the edge or the VPN peers is not. Write it sanitized from the start rather than scrubbing later. (Deliberately omitted from this entry for the same reason.)

  **Blocked on Ignacio for two things**, and no agent can supply them: what each VLAN is *for* (which is IoT, trusted, guest, cameras — only `.40` = infrastructure is inferable), and why there are 12 Mullvad exits with traffic policy-routed across them. `read_agent` cannot read `/conf/config.xml` — root-only, not in its sudo allowlist — so this has to come from him or from a command run in his own session.

  📌 **One fact for that diagram, measured 2026-08-06 and free to record now: the control machine is not on the fleet's segment.** The laptop sits on `10.30.80.1` and reaches `10.30.40.0/24` via `10.30.80.254` — so **every laptop→fleet connection crosses the firewall, including the ones a test makes.** This was asserted the other way round mid-session ("same segment, so this probe won't reach CrowdSec"), which was wrong; `route -n get <ip>` settles it in one command and should be the reflex before claiming any traffic stays local. Consequence worth carrying into the diagram: a CrowdSec ban on the laptop's address would look exactly like the agent-lxc incident — same symptom shape, different victim.

- **🔴 `system_health_check.sh` reports THREE false failures on opnsense — fixed and verified on the box 2026-08-06; latent, since the script is not scheduled there** `V:High E:Low` — Measured on the live firewall 2026-08-05 (run by hand from a phone, as `choco` and again as root). The script currently exits 0 regardless, so none of this has ever been visible. **After the aggregation fix lands, opnsense pages every 15 minutes, permanently.** Three separate causes:

  1. **The FreeBSD load check has never worked, on any run, ever.** `check_load` does `uptime | sed 's/.*load average://'` — but FreeBSD's `uptime` prints **`load averages:`**, plural. The substitution never matches, nothing is stripped, and `awk '{print $1}'` returns the *first field of the whole uptime line* — the clock. Observed: `❌ Load: 12:27AM on 6 CPUs (200%)`, while the real averages were `0.24, 0.25, 0.24`. The 200% comes from awk coercing `12:27AM` to `12`, then `12/6*100`. A textbook case of the rule this repo already writes down: verify what a parse *yields*, not that the pattern matched.
  2. **`sshd` is not the service name on OPNsense.** `check_services` uses `SERVICES="sshd cron"` on FreeBSD; OPNsense's is `openssh` — the repo already knows this, in `ssh_hardening`'s note about `service openssh onereload`. So `service sshd status` always fails and reports `❌ Service sshd: not running` **on a host reached over that very SSH session**.
  3. **`cron` status is permission-dependent.** `❌ not running` as `choco`, `✅ running` as root, same host, seconds apart. The cron job runs as `choco`, so the fleet sees the false answer. Same class as the `adm` bug below — and again invisible to `tests/run_tests.sh`, which connects as root.

  Fix all three before deploying to opnsense. **No container can verify this** — there is no FreeBSD target (see §8b) — but it is directly verifiable by hand on the box, which is how it was found.

  ⚠️ **Do not blanket-rename `sshd` → `openssh`.** `openssh` is the *OPNsense* service name; **stock FreeBSD uses `sshd`**. A hardcoded rename fixes the one host in the fleet and silently breaks the moment §8b's stock-FreeBSD test VM exists — i.e. it breaks the thing built to catch exactly this class of bug. Make the critical-service list **inventory-driven** (a `critical_services` var per platform, defaulted in group_vars) rather than a hardcoded `SERVICES=` string per `$OS_TYPE`. That also removes the Debian hardcode, which has the same latent problem: `fail2ban` is in the list for every Debian host whether or not it is installed there.

  **Status 2026-08-06 — all three fixed in code on `fix/agent-lxc-logs-dir-2026-08`, none verified on FreeBSD.** What changed:

  1. **Load.** `check_load` now reads the kernel — `/proc/loadavg` on Linux, `sysctl -n vm.loadavg` on FreeBSD — instead of parsing `uptime` prose, and the `uptime` route survives only as a last-resort fallback with a `load averages*` pattern that matches both spellings. A new guard validates what the read *yielded* (`case` against `*[!0-9.]*`) before any arithmetic; it rejects the exact observed `12:27AM` and accepts `0.24`. The old guard only inspected the computed percentage, and `200` is a perfectly plausible integer — which is why the fault survived a guard that was already there.
  2. **Service names.** `CRITICAL_SERVICES` is now inventory-driven: `deploy_monitoring.yml` writes `{{ monitoring_config_dir }}/health_check.conf` (`/usr/local/etc/monitoring` on FreeBSD, `/etc/monitoring` elsewhere) when a host defines `critical_services`, and removes it when one stops. The script keeps a built-in default, because the script and its config ship from different tasks and the script must be correct on its own — and that default *probes* for an `openssh` rc script rather than assuming, so OPNsense and stock FreeBSD each get the right name with no configuration at all.

     📌 **The mechanism currently has no users, and that is deliberate rather than an oversight.** The opnsense override was removed once the script stopped being deployed there, and no Debian host needs one *yet* — the pre-flight confirmed `ssh`, `cron` and `fail2ban` are all active on cwwk, dockassist and agent-lxc. It exists for the case the entry above names: `fail2ban` is in the hardcoded Debian list for every Debian host whether or not it is installed there, and the first host where that stops being true needs a one-line inventory entry rather than a script change. If a fourth Debian host ever turns out not to run it, that is the escape hatch.
  3. **Permission-dependent status.** On FreeBSD the check falls back to the process table when `service <name> status` declines to answer. ⚠️ **As first written this used a `service[:process]` entry syntax and assumed `pgrep` was permission-independent. Both were wrong — see the measurements below, which supersede this line.**

  ### Measured on opnsense 2026-08-06, as `choco` and again as root — two of the three fixes were wrong

  Run by hand on the live firewall. The load fix survived; the service fix did not, and the impact assessment was wrong twice over.

  ✅ **Load — confirmed correct.** `sysctl -n vm.loadavg | awk '{print $2}'` returns `0.25`, matching `uptime`'s first figure exactly; as root, `0.16` both ways. The field index is right. The old parse returned `2:07AM`, as before.

  ✅ **Service name — confirmed correct.** Only `/usr/local/etc/rc.d/openssh` exists (`/etc/rc.d/openssh` does not), and as root `service openssh status` succeeds while `service sshd status` fails. The inventory value and the rc-script probe both land. Note the inventory value is now `["openssh", "cron"]` — see below.

  🔴 **The `pgrep` fallback did not work, and the reason kills the whole approach.** As `choco`, `pgrep -x cron` finds **nothing** on a host where root finds it seconds later. OPNsense hides other users' processes from unprivileged callers, so the process table is not a permission-independent oracle there — it is a second way of being told "no". `/var/run/cron.pid` is `0600 root:wheel`, which is the other half. And `pgrep -x sshd` finds nothing **even as root**, so the `openssh:sshd` process mapping was wrong too.

  **Rewritten accordingly.** `freebsd_service_state` returns `running | stopped | unknown`, and **`unknown` is not a failure**: `service X status` first, then the process table *only when it can actually be seen* — probed by looking for PID 1, which exists everywhere and belongs to root, rather than by reading `security.bsd.see_other_uids`. The `service[:process]` syntax is gone; its only use case was a host where the fallback cannot run. Stock FreeBSD, where rc name and process name agree and an unprivileged user can see the process table, still gets a real second opinion.

  📌 **Correction, twice over, to what this entry claimed about impact.** First: `tasks/deploy_monitoring.yml` schedules `system_health_check.sh` bare on FreeBSD — no wrapper, no tokens — so a non-zero exit would be local cron mail, not a page. Second, and settled by reading the live crontab: **it is not scheduled on opnsense at all.** The Ansible-managed entries there are the opnsense role's own `check_system_health.sh` and `check_dns_health.sh`, both correctly wrapped. `system_health_check.sh` is *deployed* to `/usr/local/bin` by the fleet-wide script copy and never run. So all three opnsense faults are **latent, not live** — real, worth fixing, and not urgent.

  ✅ **RESOLVED 2026-08-06 — stop deploying it there.** `roles/platform/opnsense` already schedules eight wrapped checks including its own `check_system_health.sh`, which covers memory, disk and load with FreeBSD-native probes — and better: **the common script's FreeBSD memory branch runs two sysctls and prints "Memory check completed" without comparing anything to anything.** Unifying on the common script would have *lost* real memory monitoring on the firewall. Running both would duplicate three checks at two different sets of thresholds.

  So `deploy_monitoring.yml` now skips `system_health_check.sh` on FreeBSD and removes any existing copy, and the FreeBSD cron block in `tasks/deploy_monitoring.yml` is gone — replaced by `state: absent` for its two entries, so a host that ever received them gets cleaned. **That block's second entry pointed at `check_pf_status.sh`, which has never existed anywhere in this repo**: a cron installed against a missing script, which is the same silent-failure shape as the `logs_dir` bug. Neither entry was on the live box.

  **What is lost: nothing measurable.** Disk, memory and load → the role's own check. Internet reachability → `check_gateway.sh` every 10 min plus the healthchecks.io WAN ping. Cron liveness → those pings are dead-man's switches, so a dead cron pages by silence. sshd liveness → Tier 1's hourly `ssh opnsense-agent` sweep, which is how the July account breakage was found. Failed systemd units and unattended-upgrades have no FreeBSD meaning at all.

  📌 The FreeBSD code paths stay in the script — it is cross-platform by contract and §8b's stock-FreeBSD VM would exercise them — but note they now have **no host on the current fleet**, so they are unexercised by definition until that VM exists. The decorative FreeBSD memory branch is the one worth fixing first if it is ever built.

- **✅ Fleet pre-flight for L3 — ALL SIX Debian hosts measured from a phone, 2026-08-06** `V:High E:Low` — Before deploying checks that have never been able to fail anywhere, the probes behind each check were run by hand on every host that will receive them. Two findings, both fixed; everything else confirmed rather than assumed.

  | Host | `detect-virt` | failed units | ssh/cron/fail2ban | `adm` | mem | PSI |
  |---|---|---|---|---|---|---|
  | `cwwk` | none | 0 | all active | **NO** | 82% → **52%** after the ARC fix | present |
  | `dockassist` | none | 0 | all active | yes | 44% | **absent** |
  | `cobra` | none | 0 | all active | yes | 15% | **absent** |
  | `hifipi` | none | 0 | all active | yes | 13% | **absent** |
  | `vinylstreamer` | none | 0 | all active | yes | 51% | **absent** |
  | `unifi-lxc` | **lxc** | 0 | all active | **NO** | 32% | `0.00` |
  | `agent-lxc` | **lxc** | **1** → fixed | all active | **NO** | 3% | `0.00` |

  **What this establishes:**

  - **`systemd-detect-virt` picks the right metric on 7/7.** `none` on the four Pis and cwwk (they keep the load average), `lxc` on both containers (they switch to CPU pressure). That branch had only ever been tested on CT 199.
  - **The container pressure path is confirmed on both real containers**, read as `choco` rather than over `read_agent`, both `0.00` across all three windows — including on a 2-core LXC. The 80 threshold has an enormous margin over observed normal.
  - **`fail2ban` is active on all six**, so the hardcoded Debian service list needs no per-host override anywhere. The `critical_services` escape hatch stays deliberately unused.
  - **The `adm` split is now directly measured rather than part-inferred:** missing on exactly cwwk, unifi-lxc and agent-lxc; present on all four Pis. The "3 of 7 hosts will page" claim is closed, and L2a will report `changed` on precisely those three.
  - **No filesystem above 75% anywhere**, and no memory near threshold once the ARC fix landed.
  - **One failed unit fleet-wide**, on agent-lxc, now fixed.
  - **All four RPis lack PSI entirely** — the kernel is built without it, so this is the platform, not a dockassist quirk. Harmless, since a Pi never takes the container branch, but the pressure path has no RPi coverage even in principle.

  ⚠️ **What this is not.** These are the *probes* the checks run, not the script itself — only `cwwk` had the real script executed against it (clean, exit 0). It predicts the new behaviour rather than demonstrating it everywhere.

  ⚠️ **One thing it deliberately could not test: upgrade freshness on the four Pis.** They are in `adm`, so `check_auto_upgrades` will parse the log and apply the 7-day staleness rule for the first time ever — that coverage has been invisible on every host, always. If `unattended-upgrades` has stalled on a Pi, L3 will report it. **That would be a true positive, not a false one**, so it is not a blocker; it is simply the first time anyone will hear about it. One command settles it per host: `grep "Starting unattended upgrades script" /var/log/unattended-upgrades/unattended-upgrades.log | tail -1`.

  📌 Also observed, informational: `cwwk` reports **133 pending updates**. The check deliberately does not alert on that count, and held-back packages are normal on Proxmox — worth a glance once L2a makes freshness visible there.

- **🔴 `check_load` divides the HOST's load by the CONTAINER's core count — a fifth false failure, and it also gates the fleet deploy** `V:High E:Med` — Found 2026-08-06 while verifying §1a, by the suite failing a case that had just passed. Measured, not inferred: `/proc/loadavg` inside CT 199, unifi-lxc and agent-lxc returns cwwk's values **byte for byte**, sampled against cwwk in the same second (`0.85 0.70 0.49` in both). `nproc` inside returns the container's limit — 1, 1 and 2 against cwwk's 8. lxcfs *is* mounted over `/proc/loadavg`, so the obvious detection does not work: Proxmox runs it without `--enable-loadavg`, in which mode it passes the host's file straight through. It virtualises `/proc/cpuinfo` either way, which is precisely what creates the mismatch — **container-scoped divisor, host-scoped numerator.**

  So the arithmetic is meaningless on every LXC. `agent-lxc` (1 core) reports `❌ Load` whenever cwwk's 1-minute average exceeds **0.8 — about 10% of an 8-core box**, which is routine; `unifi-lxc` (2 cores) at 1.6. Both were observed above threshold during this session. Invisible today for the same reason as the other four — the script exits 0 regardless — and it pages the moment the aggregation fix lands, which puts it in exactly the same class as §1a's four. **The Pis and opnsense are unaffected** (bare metal and a VM respectively).

  Not introduced by the 2026-08-06 load fix — `uptime` read the same passed-through file — and not fixed by it either, since the fix corrected *which* number is read, not whose machine it describes.

  ✅ **DECIDED AND FIXED 2026-08-06.** Option 1: **report, never fail, on a container.** `in_container` uses `systemd-detect-virt --container` (verified on CT 199 → `lxc`, rc 0) with a `security.jail.jailed` fallback for FreeBSD, and `check_load` prints `⚠️ Load: 0.63 (host-wide) on 1 container CPUs - not comparable` and returns 0. Chosen over PSI because it cannot false-page, it is three lines, and swapping metrics deserves its own calibration rather than being dropped into the existing 80% comparison mid-sprint.

  Verified both directions: on CT 199 the run exits 0 with the warning; on a genuine non-container (the Mac, 8 cores, real load 1.76) the same code path errors and counts the issue once the threshold is crossed. `tests/cases/health_container_load.sh` asserts the target *is* a container reading a host-scoped file before asserting anything else, so it fails loudly rather than passing vacuously if lxcfs is ever reconfigured; against `main` it fails with `❌ Load: 0.90 on 1 CPUs (90%)`, the fault itself.

  ✅ **Coverage restored the same day — the container branch now reads cgroup CPU pressure**, not a host-wide number it refuses to act on. `/sys/fs/cgroup/cpu.pressure` is cgroup-namespaced and genuinely container-scoped.

  **It is a better signal than the load average was, not merely a safe one.** One busy task on a 1-core container measures `0.00`: nothing is *waiting*, the container is simply using what it has — where a load average of 1.00 read as 100%. Pressure appears only under real contention. That is the question `check_load` was always trying to answer.

  **Threshold calibrated, not picked** — 80% on `avg300`:

  | Measurement | `some` pressure |
  |---|---|
  | `unifi-lxc`, normal operation | `avg10/60/300 = 0.00` |
  | `agent-lxc`, normal operation | `avg10/60/300 = 0.00` |
  | `cwwk` root cgroup (busiest host in the fleet) | `avg300 = 16.7` |
  | CT 199, one busy task on its one core | `avg10 = 0.00` |
  | CT 199, sustained 2–4× oversubscription | `avg60 = 88–96`, `avg300` through 48 in 3 min |

  80 sits far above every observed normal and below genuine starvation; `avg300` rather than `avg60` so a burst cannot fire it, and the check runs every 15 minutes anyway. All four thresholds are now environment-overridable, which is also how `health_container_load.sh` forces the failing direction: it reads the container's *actual* pressure and sets the threshold one point below it, so the failure comes from a real reading. Against `main` that case fails on three of four assertions.

- **✅ logrotate skipped every user log on a host whose `logs_dir` was 0775 — fixed 2026-08-06** `V:Med E:VLow` — Found via the failed unit on agent-lxc. `system/baseline.yml` writes `/etc/logrotate.d/{{ primary_user }}` for `{{ logs_dir }}/*.log` **with no `su` directive**, and logrotate refuses to rotate anything whose parent directory is writable by a group other than root unless told which identity to rotate as. `logs_dir` is owned by the infrastructure user *by design*, so the config only works while the directory happens to be `0755`.

  On agent-lxc it was `0775`: created by hand on 2026-08-03 with umask 002, during the fix for the 12-day outage. Result — `fleet_health_check.log`, `investigate.log` and `system_health_check.log` all skipped, and the unit exiting 1, **every night from 2026-08-04 to 2026-08-06**, entirely invisible.

  Fixed by adding `su {{ primary_user }} {{ infrastructure_group }}` to the config, which is what logrotate's own error message asks for. Enforcing `0755` on the directory would also work, but only until the next host whose `logs_dir` arrives by a route other than the two tasks that set the mode — `su` removes the coupling rather than restating it. **Reproduced and cleared on CT 199:** at 0775 with no `su`, `logrotate -d` emits agent-lxc's error verbatim; with `su`, nothing. Render verified against the test inventory.

  ⚠️ **Deploy path is `system/baseline.yml --tags logging`, not `deploy_monitoring.yml`** — a third playbook, so do not assume L3 carries it. Until then, `chmod 0755 ~/.logs` on agent-lxc is the one-command equivalent.

  📌 **The wider lesson, and it is the point of this sprint:** this ran silently for three days on a host under active investigation, and was found only because a check for failed units was added. Two independent Ansible tasks had a permissions coupling neither of them stated.

- **✅ `check_memory` counted ZFS ARC as used — fixed 2026-08-06** `V:High E:VLow` — Found by the L3 pre-flight above. `cwwk` reported **82% used** where the true figure is 52%: `MemAvailable` does not count ZFS ARC, which is neither free memory nor page cache in the kernel's accounting, so a 10 GiB ARC cap reads as 10 GiB used. Measured: ARC `size` 9.91 GiB, `c_min` 0.97 GiB, MemTotal 31.09 GiB, MemAvailable 5.67 GiB.

  The check now adds the part above `c_min` to available — that is what the ARC shrinker actually returns under pressure, and only that. **It is not a threshold fudge and it does not lobotomise the check:** genuine pressure shrinks ARC first, so the unreclaimable share rises and the check still fires. Verified on cwwk by running the script there, both directions — `81% → 52%` with a clean run and exit 0, and `❌ 53% (above 40%)` with `THRESHOLD_MEM=40`, exit 1.

  ⚠️ **No container can cover this** — none of them have ZFS, so `/proc/spl/kstat/zfs/arcstats` does not exist on the rig. Verified on the host and nowhere else, same as the FreeBSD branches. cwwk is the only ZFS host; the containers see lxcfs-virtualised `meminfo` and are unaffected.

  📌 Side effect worth knowing: this also removed a flake. CT 199 has 1 core and read an 8-core host's load, so **any case asserting exit 0 was flaky whenever cwwk was busy** — one run of the 7 cases failed that way and passed on retry, which is how the fault was found in the first place.

- **⚠️ `check_auto_upgrades` false-alerts on 3 of 7 hosts — check-side fix DONE 2026-08-06, group side still open** `V:High E:VLow` — Diagnosed 2026-08-04; this is the "❌ Upgrade log not found on agent-lxc even though the directory is populated" symptom, root-caused. `/var/log/unattended-upgrades/` is `root:adm 0750`, and `bootstrap.yml` creates the infrastructure user with `groups: sudo` and nothing else. So on every host whose user came from bootstrap the log is simply unreadable and the check reports it as missing. Measured, not inferred: **`cwwk`, `unifi-lxc` and `agent-lxc` — `choco` is NOT in `adm`** (the first two over `read_agent` on 2026-08-04, agent-lxc confirmed by hand 2026-08-05: `groups=1000(choco),27(sudo)` against a `drwxr-x--- root adm` directory). `dockassist` (and by provenance the other three Pis) **is** in `adm`, because that user predates bootstrap and inherited the Pi image's group list. That asymmetry is exactly why this went unnoticed: it never fired on the hosts anyone watched.

  Cosmetic today because the script exits 0 regardless. **Once the aggregation fix on `fix/agent-lxc-logs-dir-2026-08` lands, those three hosts page every 15 minutes** — the false-positive risk that branch's deploy notes warn about, now with names attached.

  ⚠️ **The obvious fix does not work, checked 2026-08-05.** "Add `adm` to `groups:` in `bootstrap.yml`" is wrong: that task (line ~104) sits inside a block gated on `connected_as_root` **and** the infrastructure user not already existing. On every live host the user exists and Ansible connects as that user, so the block never runs. Editing it changes nothing on the fleet and only affects future rebuilds. Anyone "fixing" this that way will see a green playbook and an unchanged fault.

  Two parts, and they are independent:

  1. ✅ **The check side — DONE 2026-08-06, and this is what unblocks the deploy.** `check_auto_upgrades` now branches four ways instead of one: directory absent → error (unchanged); directory present but not readable/traversable → **warning naming the mode and the user, run still passes**; log file present but unreadable → warning; otherwise the existing freshness parse. Verified on CT 199 as `choco` across all six states — unreadable dir, unreadable file, absent dir, absent file, 65-day-stale log, fresh log — with only the two permission states passing. Covered permanently by `tests/cases/health_upgrade_log_{unreadable,missing}.sh`, which run the script through the new `run_uut_as` harness helper as the unprivileged user; both fail against `main`.

     ⚠️ **This narrows coverage, deliberately.** On the three hosts that cannot read the log, the freshness check is now silent rather than wrong — `unattended-upgrades` genuinely stalling there would not be caught. The service-enabled, service-active and config checks still fire. Part 2 is what closes it properly.
  2. ✅ **The group side — DONE 2026-08-06, and it restores what part 1 gave up.** A new idempotent task in `tasks/debian_baseline.yml` (`tags: [users, groups, logs]`) ensures the infrastructure user is in `adm` regardless of how the user got there, rather than editing bootstrap's create-user block, which never runs on a live host. Deploy path: `ansible-playbook ansible/playbooks/platform/debian.yml --tags groups` — a one-task run, far lighter than `site.yml`. Verified end to end on CT 199: `⚠️ cannot verify freshness` before, `✅ Last upgrade: 2026-08-05` after; second run `changed=0`. Also gets `journalctl` without sudo.

     ⚠️ **Gotcha that will cost the next person what it cost this session.** It looked like it had failed. **SSH `ControlPersist` was serving a session established before the change**, so `id` reported the old group set for ten minutes, while `id -nG <user>` — which queries the database rather than the process — showed the new one. Group changes are invisible to a multiplexed "new" connection. Check with `-o ControlPath=none` before concluding anything about group membership. The test suite is immune: `run_uut_as` uses `su`, which calls `initgroups` fresh.

- **`deploy_monitoring.yml --tags scripts` deploys into a directory it skips creating** `V:High E:VLow` — **Reproduced end to end 2026-08-04** on CT 199, previously only reasoned about. The scripts-dir task is tagged `[monitoring, scripts]` and the logs-dir task `[monitoring, logs]`, so `--tags scripts` against a fresh host creates `~/.scripts`, deploys all six scripts, exits green — and leaves no `~/.logs`. Every monitoring cron redirects into that directory, so each one dies at `>> ~/.logs/x.log: No such file or directory` before the script ever runs: no output, no wrapper, no Slack, exit 1. That is the CT 103 12-day silence, mechanism for mechanism. `tasks/deploy_monitoring.yml` (the `services.yml` half) is worse — it never creates `logs_dir` at all, installs the cron pointing into it, and prints `✅ Monitoring deployed`. `system/preflight.yml` only asserts the *variable* is defined, not that the directory exists. Fix: one task creating both directories, tagged with every tag that deploys anything into them.

  **✅ FIXED IN CODE 2026-08-06** (`fix/deploy-plumbing-dirs-2026-08`, not deployed). One task file — `ansible/playbooks/tasks/monitoring_dirs.yml` — creates both directories and is imported by all four consumers: `deploy_monitoring.yml`, `tasks/deploy_monitoring.yml`, `tasks/ssh_hardening.yml`, and (as its own copy, since roles are self-contained here) `roles/services/unifi`.

  Verified in **both directions on CT 199 itself**, not reasoned about. Against `main`, from a wiped host: `--tags scripts` deploys all six scripts, exits green, no `~/.logs`; `services.yml --tags cron` installs the crontab entry and creates *neither* directory. That installed cron was then **run by hand** — `sh: 1: cannot create /home/choco/.logs/system_health_check.log: Directory nonexistent`, **exit 2, on stderr, wrapper never invoked**. That is the mechanism end to end, observed rather than inferred. On the branch, both runs create both directories; full `deploy_monitoring.yml` and `services.yml --tags monitoring` each converge and then report `changed=0` on CT 199 *and* CT 198 (Debian 12).

  ⚠️ The tag list on that task is load-bearing and will rot silently: any new tag that deploys into `scripts_dir` or `logs_dir` must be added to it. There is no test that catches forgetting.

  ✅ **Fleet pre-flight, 2026-08-06 — the deploy is a measured no-op, not an assumed one.** `stat` was run as `choco` on all eight hosts before claiming the new task would be quiet. Every one is already `choco:choco 0755`, and opnsense `choco:wheel 0755`, which is exactly what the task sets. **So it reports `ok` on every host and `changed` on none.** A `changed` at L3 therefore means a host was genuinely missing a directory its crons already redirect into — a finding, not noise.

  ⚠️ **One inference this overturned.** agent-lxc's `~/.logs` was expected to be `0775` (hand-created with umask 002 during the outage fix, and the reason `logrotate.service` failed nightly). It is **`0755`** — the chmod was already applied — and `logrotate.service` now reports `inactive` with `ExecMainStatus 0` and **zero failed units on the host**. The L2b hazard ("agent-lxc pages on its first run after L3") is therefore already gone in practice. The `su` directive fix is still worth deploying, but as prevention for the next host, not as a prerequisite.

- **Rotate the UniFi read-only password** `V:Med E:Low` — Added to the vault 2026-08-07 as `vault_unifi_readonly_user` / `vault_unifi_readonly_password` (UniFi Network controller, View Only role, enforced server-side). **The current value was transmitted in plaintext when it was set up**, so it should be changed. Storing it in the vault is fine and matches how every other credential here is handled — this item is purely about the one-time exposure, not the storage. To rotate: change it in the controller (Settings → Admins), then `ansible-vault edit ansible/inventory/group_vars/all/vault.yml` and update the value. Nothing consumes these variables yet; they exist so topology reads (`docs/NETWORK.md` § *Reading the UniFi controller*) do not need the password pasted in.
- **Failures alert the watched channel; recoveries land in the unwatched one** `V:Med E:Low` — Observed 2026-07-22 while testing the Tier 1 alert path. `enhanced_monitoring_wrapper` sends failures via `alert_token` (#home-alerts) but the "recovered / notify-fixed" message via `logging_token` (#home-logging). So a check that fails and then self-heals leaves a red `:x: ALERT` in the watched channel with the all-clear posted somewhere you don't watch — the alert looks permanently open unless you go looking. This is fleet-wide wrapper behaviour, not specific to any one check, and it is probably why stale-looking alerts accumulate. Fix is a one-line change to route the recovery path to `alert_token`; decide whether recoveries should be as loud as failures, or whether a threaded/quieter form is preferable.


- **`read_agent` is pinned to a /16, not a single IP** `V:Med E:VLow` — Surfaced 2026-07-22 while verifying the container key. `vault_agent_control_ip` is `10.30.0.0/16`, so the laptop's `read_agent` key is accepted from anywhere on the internal network — including any host the agent itself can reach, and the new container. `docs/ARCHITECTURE_DECISIONS.md` describes this control as `from="<control-machine-IP>"` with the rationale "even if the key leaks, it's only usable from one source IP", which is not what is deployed. The container's own key *is* correctly pinned to the single `10.30.40.203` (verified: a key pinned elsewhere is rejected). Decide: tighten the vault value to the laptop's address, or correct the decision doc to describe a network-scoped restriction. Tightening risks lockout if the laptop's DHCP lease moves — check whether it is reserved first.

- **Unexplained `Script Failed on dockassist` at 04:00, 2026-07-22** `V:Med E:Low` — Seen in `#home-alerts` while verifying the Tier 1 alert path; predates and is unrelated to the agent LXC work, and dockassist reports healthy since. Five wrapper-driven checks fire at 04:00 (`check_tado_health`, `check_container` ×2, `check_ha_web`, `heartbeat_ha`), and **which one failed cannot be determined from the agent account** — the per-script logs live under `/home/choco` (`0700`). Diagnose from the host itself, or grep `~/.logs/*.log` around 04:00. A concrete instance of the read_agent visibility gap noted below.


- **`baseline.yml` had two broken `playbook_dir` paths — FIXED 2026-07-22** `V:High E:VLow` — Surfaced while onboarding agent-lxc. `playbook_dir` resolves to the directory of the *executing* playbook, so inside `system/baseline.yml` it is `ansible/playbooks/system/` and `../../` lands on the non-existent `ansible/` — not the repo root. Two consequences, one loud and one silent: `templates/netrc_curlbin.j2` **failed hard**, aborting `site.yml` for any host with `curlbin_user` defined; and `scripts/common/` **failed silently** — `find` matched nothing, the loop was empty, and "Deploy all common scripts" reported `skipping` with no error, so baseline never deployed the common scripts it appears to. Both corrected to `../../../`. Sibling files already used the correct depth (`tasks/debian_updates.yml`), which is why this was inconsistent rather than uniformly broken. **Fleet impact:** the next `site.yml` on any host will now actually deploy `scripts/common/*` from baseline (same files `deploy_monitoring.yml` pushes, so the end state is unchanged) and will deploy `~/.netrc`. Worth a `--check --diff` pass per host before applying.

- **`bootstrap.yml` and `ssh_hardening.yml` were fighting over `UsePAM` — FIXED 2026-07-22** `V:Med E:VLow` — bootstrap's `lineinfile` set `UsePAM no`; `templates/debian/sshd_config.j2` sets `UsePAM yes`. Each run flipped it back, so every Debian host was permanently `changed` on `site.yml` and its effective value depended on which play ran last. bootstrap aligned to `yes` (the template is canonical, and it is also the Debian default and what hosts running `services.yml` already have). The other four directives in that loop already matched. Same bug class as the 2026-05-10 `TCPKeepAlive`/`LoginGraceTime` fix — worth a rule: **anything bootstrap sets with `lineinfile` must match the value the canonical template ships.**

- **`apt` cleanup task reported `changed` forever — FIXED 2026-07-22** `V:Med E:VLow` — one task did `autoremove` + `autoclean` + `clean` together. `clean` empties the download cache, which the apt module always reports as changed (there is no "already clean" state), so every host was permanently changed twice per `site.yml`, masking real drift. Split: `autoremove`/`autoclean` report honestly (removing an orphaned package *is* real), `clean` carries `changed_when: false`. With this and the `UsePAM` fix, `site.yml --limit agent-lxc` now converges to a true `changed=0`.

- **`read_agent` cannot read the monitoring wrapper's state files** `V:Med E:Low` — Confirmed on cobra: `/home/choco` is `0700`, so `~/.logs/*.json` are unreadable by the agent account. Any future "is this host's monitoring still alive?" check must not assume it can stat those files. Tier 1 uses `sudo journalctl -u cron` instead, which the existing sudoers already permits. Worth knowing before writing Phase B checks.

- **Slack/healthchecks tokens are visible to `read_agent` via the journal** `V:Med E:Med` — `journalctl -u cron` prints each cron command line in full, including the webhook tokens embedded in `enhanced_monitoring_wrapper` invocations, and `read_agent` is permitted to read it. This widens Priority 3 (tokens out of cron command lines) from "hygiene" to "a read-only account can read the alerting credentials." Same fix closes both — an env file sourced by the wrapper.

- **`enable_ufw` must be set on the host entry, not in `group_vars/{function}.yml`** `V:Low E:VLow` — `group_vars/{function}.yml` is loaded by `services.yml` via `include_vars`, which happens long after `bootstrap.yml` owns the ufw install/allow-22/enable sequence. Setting it in the function file silently does nothing. `bootstrap.yml:287` already documents "host vars"; noted here because agent-lxc is the first host to actually enable it. Recorded in `group_vars/agent.yml` as a comment.

- **Ansible deprecation: `INJECT_FACTS_AS_VARS` removal in ansible-core 2.24** `V:Med E:Med` — Every play in this repo emits deprecation warnings for bare `ansible_os_family` / `ansible_user_id` style facts; the guidance is `ansible_facts['os_family']`. Currently harmless noise on ansible-core 2.21, but it will break broadly at 2.24. Mechanical, repo-wide, and best done as one sweep rather than incidentally.


- **TV idle auto-off for the amp** `V:Low E:Med` — A left-on TV keeps the amp powered (by design: TV `on` → `amp_source_active`). If it bothers in practice, `cobi_tv_3` exposes `is_volume_muted`/`volume_level`/`app_id` (optimistic `assumed_state`) as candidate idle signals. First confirm the exact OFF value of `cobi_tv_3` (off vs standby vs unavailable) with the TV powered down — it sat `unavailable` overnight 2026-07-14→15. Context: `docs/AUDIO_AUTOMATION.md` + memory `now-playing-ir-automation-plan`.

- **`detect_audio.log` empty after ~10h of active service — RESOLVED 2026-07-20** — Root cause found and fixed on `fix/detect-audio-journal-only-logging`. `DirectLogger` (`detect_audio.py.j2`) opened `~/.logs/detect_audio.log` once at process start (`mode='a'`) and held that file descriptor for the service's entire uptime — often many days (`Restart=always`, uptime observed at 4+ days). `/etc/logrotate.d/choco` rotates `~/.logs/*.log` **daily**. Rotation renames the inode out from under the held-open handle: the old fd keeps writing to what's now `detect_audio.log.1`, while the *current path* `detect_audio.log` sits at 0 bytes until the process restarts — which for a long-lived service can be days. Confirmed live: `detect_audio.log` was 0 bytes since the 2026-07-16 00:16 rotation while `detect_audio.log.1` had content through 2026-07-19 19:16, matching the PID's actual start time (2026-07-15). This fully explains the 2026-07-12 observation as a routine instance of the pattern, not a one-off.
  Fix: `detect_audio.py.j2`'s `DirectLogger` replaced with `JournalLogger` (stdout only, `flush=True`); the systemd unit already sets `StandardOutput=journal`, so persistent journald (merged 2026-07-14, see above) is now the sole durable record — sidesteps the whole held-open-fd-vs-logrotate class of bug rather than working around it. `vinylstreamer_monitor.sh.j2`'s `check_log_errors` updated to `journalctl -u detect_audio -o cat` instead of tailing the file (verified `choco`'s `adm` group grants non-root journal read access; output format matches the old grep pattern exactly). `logs_dir` directory-creation task retargeted to serve the cron logs that still use it (`vinylstreamer_monitoring.log`, `root_disk_space.log` — these are safe: each cron invocation opens/closes the file fresh, no held-open handle across rotation). Deployed + live-verified: service restarted clean, `vinylstreamer_monitor.sh` run manually confirms journal-based error check passes. Old `.logs/detect_audio.log*` files left in place (harmless, `missingok` covers them); will age out via existing `rotate 7`.
- **`/var/log/liquidsoap/phono.log` has no logrotate entry** `V:Low E:Low` — Surfaced 2026-07-20 while investigating the item above. Liquidsoap logs to `/var/log/liquidsoap/phono.log` (`liquidsoap-native.liq.j2`, `log.file.path`) but no `/etc/logrotate.d/` entry covers it — `/etc/logrotate.d/choco` only globs `~/.logs/*.log`, and there's no liquidsoap-specific rule. File was ~110KB after months of runtime, so growth is slow and not urgent, but it's unbounded. Fix: add a logrotate stanza for `/var/log/liquidsoap/*.log` (liquidsoap reopens its log on rotation via its own signal handling, so this shouldn't hit the same held-fd bug as detect_audio — verify before relying on that assumption).
- **Unattended-Upgrades Config Drift (cobra + unifi)** `V:Med E:Low` — Both hosts have manually configured `/etc/apt/apt.conf.d/50unattended-upgrades` with `"origin=*"` wildcard (upgrades ALL packages). Ansible template enforces security-only origins. Re-running `site.yml` on these hosts will overwrite their configs. Decision needed: adopt the Ansible template (security-only, matching all other hosts) or update the template to support a toggle for full-upgrade mode. Recommend aligning to security-only — the 145-173 pending non-security packages on hifipi/vinylstreamer confirm that security-only is sufficient.
- **Claude Code Autonomy — Sandbox Configuration** `V:Med E:Low` — SSH commands from Claude Code are blocked by the network sandbox proxy (can't resolve SSH config aliases like `dockassist-agent`). Fix already identified and tested: add `"excludedCommands": ["ssh", "scp", "ansible", "ansible-playbook", "ansible-vault", "ansible-lint"]` to `.claude/settings.local.json` sandbox config. This was used successfully via `dangerouslyDisableSandbox` workaround in the 2026-04-08 session but the settings watcher didn't pick up the config change mid-session. Will work in fresh sessions.
- **Vinylstreamer Session-Aware Monitoring** `V:Med E:Low` — `vinylstreamer_monitor.sh` currently alerts when `phono_liquidsoap.service` is inactive, but liquidsoap is intentionally off when not streaming. This generates false positives and unnecessary restart attempts. Fix: make liquidsoap/icecast checks conditional on `detect_audio` indicating an active streaming session. One script change.
- **`ssh_hardening` "Disable root user login" breaks OPNsense console — RESOLVED 2026-07-21** — Surfaced 2026-05-12; fixed 2026-07-21. The task in `ansible/playbooks/tasks/ssh_hardening.yml` set `shell: /sbin/nologin` on root unconditionally. On OPNsense root's shell is `/usr/local/sbin/opnsense-shell` — the console admin menu on VGA/serial — so applying it would have removed the console recovery path. Fixed by making the shell conditional on the inventory `os_family` var (the repo's own convention, used elsewhere in the same file) rather than the `ansible_os_family` fact: `shell: "{{ '/sbin/nologin' if os_family == 'debian' else omit }}"`. `omit` leaves the existing shell untouched on FreeBSD while `password_lock` still applies everywhere. Verified in check mode against opnsense: root's shell stays `/usr/local/sbin/opnsense-shell`. `--tags ssh` is now safe to run on opnsense. Note the task still reports `changed` on every run there — that is `password_lock` alone (see the FreeBSD idempotency wart below), not the shell.
- **`ssh_hardening` uri fetch skips in check mode → misleading diffs — RESOLVED 2026-07-21** — Surfaced 2026-05-12; fixed 2026-07-21 by adding `check_mode: false` to the `Fetch authorized keys from GitHub` uri task. It is a read-only fetch, so it must run in check mode too; previously `--check --diff` skipped it, `github_keys_fetched.content | default('')` collapsed to `""`, and the follow-up task rendered a diff that looked like "wipe all authorized keys" — a false positive indistinguishable from a real one.
- **Fresh-laptop bootstrap doc** `V:Low E:VLow` — The vault-password handoff (`bin/vault_pass.sh` → keychain item `ansible-vault-master`) is now documented as a one-liner in `docs/ARCHITECTURE_DECISIONS.md`. Consider adding a short "Set up a new control laptop" section to `README.md` (or a dedicated `docs/SETUP.md`) that lists the full handoff: clone repo → restore iCloud Keychain → done. So future-you doesn't have to grep decisions.md.
- **unifi-lxc not fully standardized via codebase** `V:Med E:Med` — Surfaced 2026-05-12 while recovering SSH access. Several signals suggest unifi-lxc drifts from what Ansible would render: it was missing the touchid-agent ssh key in `authorized_keys` (so `services.yml` clearly hasn't been re-applied since the keychain rotation); the 2026-05-10/11 log-path audit explicitly listed verification across cobra, dockassist, hifipi, vinylstreamer, cwwk — unifi-lxc not in that list; the already-noted "Unattended-Upgrades Config Drift (cobra + unifi)" item is another instance of unifi drifting from the template. Audit: run `ansible-playbook ansible/playbooks/site.yml --limit unifi-lxc --check --diff`, review every changed task, decide per-item whether to align the host to the codebase or update the codebase to match the host (LXC-specific quirks may justify the latter). Note: container migrated from a dedicated Pi to LXC under Proxmox, which is when the divergence probably started.
- **Slack Notification Strategy Review** `V:Low E:Low` — Current two-channel split (logging/alert) is architecturally sound but has some inconsistencies. A focused audit of ~20 notification sources to reassign channels would improve signal-to-noise.

- **Dead `docker-compose.yml.j2` in homeassistant role** `V:Low E:VLow` — Surfaced 2026-07-12 while adding the Mosquitto broker. `roles/services/homeassistant/templates/docker-compose.yml.j2` is never deployed — no task templates it to the host (confirmed: no compose file exists in `~/homeassistant` on dockassist), and the running containers are all created by individual `community.docker.docker_container` tasks. Its only referrer is the unused `stop homeassistant` handler (`docker_compose_v2`, never notified). The template even drifts from reality (missing the Mosquitto service the container tasks now deploy). Delete both the template and the dead handler, or — if a compose-based model is preferred — migrate all containers to it and wire it in. Recommend deleting; git has history.

- **Shelly Gen1 device config (CoIoT peer, AP-roaming) not captured in IaC** `V:Low E:Med` — Surfaced 2026-06-30. The CoIoT unicast peer + `ap_roaming=false` set on the four Gen1 Shellys (`…f510`, `…fb5f` gas; `.229`, `.243` lights) live only on device flash — a factory reset or unit swap silently loses them and reintroduces the unavailable-flap → phantom-alert bug. Consider a small idempotent script/playbook asserting `coiot.peer` and `ap_roaming.enabled=false` per Gen1 device via its HTTP API, run opportunistically. Low urgency; documented so the dependency is known.

### Medium Value/Effort — Worth planning

- **Provision a scoped OPNsense API key** `V:Med E:Med` — Raised 2026-07-22 after the `agent-lxc` DNS entry had to be added by hand in the web UI, against the standing "CLI over UI, always" rule. There is no OPNsense API credential anywhere today (`vault_ns_api_key` is the Dutch railways key used by HA's train notifications, not OPNsense). A key scoped to just what is needed would make Unbound host overrides, and firewall changes generally, automatable from Ansible instead of clicked. Worth doing before the next thing that needs a firewall change, not during it.
  - Create in System → Access → Users → API keys, on a dedicated non-admin account, with the narrowest privilege set that covers the intended endpoints (start with Unbound: `/api/unbound/settings/*` + `reconfigure`).
  - Store as `vault_opnsense_api_key` / `vault_opnsense_api_secret`; never in a cron line or command argument.
  - Caveat worth respecting: OPNsense is the internet SPOF, and `config.xml` changes apply immediately. Any automation should be `--check`-able and touch one setting at a time.
  - Related: this is also the prerequisite if "Full Infrastructure as Code (Proxmox/OPNsense)" (Very Low Value/Effort, currently deferred) is ever revisited, and it would remove the last manual step from an `agent-lxc` rebuild.


- **Healthchecks.io Tokens out of Cron Command Lines** — *Promoted to Priority 3 on 2026-07-21* so it lands before the Agent LXC adds another consumer of `enhanced_monitoring_wrapper`. See above.
- **CI: Undefined Jinja Variable Detection** `V:Med E:Med` — The Jinja2 syntax check added 2026-05-11 (`scripts/ci/check_jinja_syntax.py`) catches parse errors like the `{{ .Names }}` Docker-format collision that bit `stop_run_ha.j2`. It does NOT catch undefined variables like the `{{ container_name }}` reference that escaped to production for months — those need actual rendering against an inventory. Enhancement: extend CI to render every `.j2` against the `.example` inventory (vault dummified) and fail on `UndefinedError`. Closes the bigger bug class.
- **Backup Integrity Verification** `V:Med-High E:Med` — Backup freshness monitoring confirms "the script ran recently" but never validates that backups are actually restorable. A periodic script that downloads the latest backup, runs `age -d`, and validates tarball contents would close the gap. Could run weekly on Proxmox.
- **Cobra Post-Processing Monitoring** `V:Med E:Med` — Plex, Transmission, and Samba are all monitored with hourly health checks. The gap is the tvnamer/rename pipeline: if RSS downloads content but post-processing fails to organize it, nothing alerts. Needs design work — what does "tvnamer failed" look like? (stale files in download dir? log parsing?)

### Low Value/Effort — Deferred

- **`user` module reports perpetual `changed` for `password_lock` on FreeBSD** `V:VLow E:Low` — Surfaced 2026-07-21 while fixing the OPNsense root-shell gate. `Disable root user login` reports `changed` on every run against opnsense even with the shell now left alone; isolating the module (`-m user -a "name=root state=present password_lock=true"`) reproduces it with no other attribute set. The module can't reliably read back the locked state on FreeBSD, so it always assumes a change. Purely cosmetic `--diff` noise, but it's the same class of "perpetually changed" wart cleaned up in the 2026-05 SSH-play idempotency pass, and it makes real diffs on opnsense harder to spot. Consider `changed_when: false` with a comment, or a `getent`-based guard.

- **`scripts/ci/check_jinja_syntax.py` can't run under system python3** `V:VLow E:VLow` — Surfaced 2026-07-21. The script imports `jinja2`, which the Homebrew system `python3` doesn't have, so a local pre-push run dies with `ModuleNotFoundError` even though CI passes (CI's `pip install ansible-lint` pulls jinja2 in). Ran it locally via the ansible-lint venv's interpreter instead. Worth a one-line note in `AGENT_INSTRUCTIONS.md`, or a shebang/venv guard, so the local check isn't quietly skipped.


- **`deploy_monitoring.yml` restarted cron unconditionally — FIXED 2026-07-21** `V:Med E:VLow` — The task literally named "Restart monitoring services if needed" had no condition on anything having changed, so every run of the playbook bounced `cron` on all 6 Debian hosts and reported `changed=1` per host forever. Two real costs: the permanent non-zero `changed` count masked genuine diffs (the playbook could never be used as a drift check), and it needlessly restarted cron fleet-wide. It also confused the cobra timezone diagnosis in this same session — cobra's cron looked "recently restarted" only because a `deploy_monitoring.yml` run 15 minutes earlier had bounced it. Fixed by registering the script-copy loop and gating the restart on `is changed`; the playbook now reports `changed=0` across all 7 hosts on a second run. **Open question:** the restart is probably unnecessary *at all* — cron re-reads modified crontabs by itself, and deployed shell scripts are read fresh at each invocation, so nothing is cached that a restart would clear. Left in place (now correctly gated) rather than deleted, because "cron never needs a restart here" is a claim worth verifying before acting on it. Delete if confirmed.
- **Backup-State File Path Inconsistency** `V:Low E:Low` — Multiple roles (`platform/proxmox`, `platform/opnsense`, `services/homeassistant`, `services/unifi`, `services/plex`) write JSON state files to `{{ home_dir }}/.log/<script>.json` (singular `.log`), while all logs now live under `{{ logs_dir }}` (`.logs` plural). Surfaced during 2026-05 log-path audit. Decision: keep the split (state files ≠ logs, separate concern) or align under one directory. Working as intended today; cosmetic.
- **Cobra Media Config Consolidation** `V:Low E:Low` — Merge separate cobra repo into media role. Cosmetic, single-source-of-truth hygiene.
- **Bathroom Radiator flapping `unavailable` → "Heating offline" alert storm** `V:Med E:Low` — Surfaced 2026-07-12. `homekit_tado_climate_offline_alert` fired ~9× in 24h for **Bathroom Radiator** (`climate.tado_smart_radiator_thermostat_va0612513536`). Root cause is device-isolated: over an 18h window the bathroom head flapped `heat`↔`unavailable` in ~10–90 min bursts while **all 5 other Tado heads on the same Internet Bridge logged 0 unavailable** — so it's not the bridge, HA, or the network, it's that one thermostat's RF link to the bridge. Onset 2026-07-11 ~15:54 (rock-stable before). Heating itself is fine (runs its schedule locally; Tado app shows no issue). Two fixes: (1) **device — done 2026-07-12/13, validated**: batteries swapped ~17:30 CEST Jul 12 (the 3-min `unavailable` at 15:27 UTC is the swap itself). Post-swap: ~21h fully clean, then only 3 short blips in 24h (10/4/2 min vs the pre-swap 56–102 min hourly bursts) — one of them (Jul 13 18:08 UTC) was **all 8 entities simultaneously** (bridge/HA-side blip, not the bathroom). Tado cloud API cross-check (via `/homes/{id}/devices` inside the HA container, token rotation persisted): `batteryState=NORMAL`, `connectionState=true` for all devices. Residual: the bathroom still has occasional minutes-long RF blips its peers don't — marginal link (distance/tiles), harmless, heating unaffected; re-seat head / move bridge only if it worsens. (2) **monitoring — done 2026-07-12, validated end-to-end 2026-07-13**: global 6h cooldown condition on `homekit_tado_climate_offline_alert` via `this.attributes.last_triggered`. The Jul 13 13:01 UTC firing (a 10-min outage landing exactly on the `for:` threshold) proved trigger + condition + alert delivery live. Deliberately chose the one-line global cooldown over per-entity timer helpers — rejected as overengineered: HomeKit Tado entities are monitoring-only (heating runs locally when HA sees `unavailable`), so the worst case of the shared cooldown is one page delayed ≤6h if a *second* device fails inside another's window — acceptable. Upgrade to per-entity timers only if multi-device flapping ever becomes real. **Threshold bumped `for:` 10→20 min (2026-07-13), validated against 10 days of recorder history (37 outages / 8 entities):** healthy devices' blips are *all* <5 min (22 events, mostly bridge-wide) → zero pages at any threshold ≥10; the degraded bathroom head produced 10–102 min outages. At 20 min the blip class (≤10 min residual RF drops) never pages while a real episode still pages within ~30 min; 15 and 20 min are empirically identical against this dataset, 20 chosen for margin. With the 6h cooldown the threshold's only job is blip-vs-episode discrimination, so detection delay is immaterial (monitoring-only entities). Gas/smoke offline checks deliberately untouched (life-safety, tighter thresholds are correct there).
- **Stale `unavailable` Tado automations in HA `.storage`** `V:Low E:VLow` — Surfaced 2026-07-12 investigating the "bathroom Tado battery" alerts. Five UI-created automations persist in `.storage` but sit permanently `unavailable` (reference services/entities that no longer exist): `automation.tado_away_schedule`, `automation.scheduled_mon_tue_tado_home`, `automation.tado_integration_down_alert`, `automation.tado_integration_recovery_alert`, `automation.tado_health_check`. Superseded by the current IaC automations (`homekit_tado_climate_offline/online`, shell_command presence, `check_tado_health.sh` cron). Harmless but they clutter the automations list and are not captured in the repo. Delete via HA UI (they're `.storage`, not template-managed).
- **Agent API Expansion (Phase 3)** `V:Low-Med E:Med` — Add read-only API access for OPNsense, UniFi, and optionally Plex. SSH access to all three hosts already covers the same ground — API access adds richer diagnostics on top, not new capability.
- **Ephemeral Ansible Testing Environment** `V:High E:High` — **Phase 1 delivered 2026-08-04, unplanned.** `tests/provision_test_container.sh` creates a disposable Debian LXC (CT 199, `testlxc`) on cwwk from the same pinned template as agent-lxc, and `tests/run_tests.sh` runs a behavioural suite against it. Built because three monitoring bugs could not be verified any other way: forcing a full disk or stopping cron on a fleet host is a worse outage than the check is meant to catch.

  What exists: a POSIX harness (`tests/lib/harness.sh`), six container cases, one host-independent unit test, and `docs/TEST_CONTAINER.md`. Every case asserts its precondition before its assertion, so a test that could not arrange its fault aborts rather than passing vacuously — three of the first five did exactly that on their first run. Each fix is verified in **both** directions: the suite is run against `main` as well, and a case that does not fail there is not evidence of anything.

  ⚠️ **Network fact discovered while building this, with consequences beyond testing: OPNsense transparently intercepts outbound port 53.** Verified 2026-08-04 from CT 199 — ICMP to `192.0.2.1` (RFC 5737, unroutable) is dropped, while a DNS query sent to that same address returns a valid answer. No host on this LAN can be pointed at a different resolver by editing its own `resolv.conf`; every lookup goes to Unbound regardless. Good for control, and it blocks the usual DNS-bypass path — but it invalidates any test or diagnostic that assumes `resolv.conf` governs resolution, and it is worth remembering before debugging a DNS problem by editing a client's config. The connectivity test now breaks name resolution via `/etc/hosts` instead.

  Deliberately *not* Ansible: the container is scaffolding that must be creatable when the inventory, the vault, or the playbooks themselves are what is being tested, so it takes no dependency on them. `provision_agent_lxc.yml` remains the pattern for real infrastructure, and the `community.general.proxmox` question is now moot for this purpose.

  **Phase 2 — playbook testing — started 2026-08-04.** `ansible/inventory/test_hosts.yml` now describes CT 199 and CT 198 instead of a host that never existed, and `.example` converges with the provisioning script's defaults. `deploy_monitoring.yml` runs against both containers and converges: all six common scripts land, and a second run is `changed=0`. `services.yml --tags monitoring` converges too. The other three plays never execute — `proxmox_hosts` and `freebsd_hosts` match no test host, and SMART is gated on `enable_smart_monitoring` — so the rig covers the fleet-wide half of `deploy_monitoring.yml` and none of the platform-specific half.

  Getting there took three fixes, each a case of the rig differing from a real host rather than a bug in the playbook:

  1. **Every path derives from `ansible_user`, which is `root` here.** `group_vars/all` sets `primary_user: "{{ ansible_user }}"`, so without an override the playbooks deploy to `/home/root/.scripts`. Fixed with a host-level `primary_user` override. Note *host*-level: `group_vars/all` is precedence 4 and overrides any group defined inside an inventory file (precedence 3), so the obvious placement silently does nothing.
  2. **The container had no infrastructure user**, so the very first task died with `chown failed: failed to look up user`. The provisioning script now creates it exactly as `bootstrap.yml` does.
  3. **A template's `/bin/ping` carries no capability xattr**, so ICMP works for root and fails for everyone else, and `system_health_check.sh` reported `Internet: unreachable` on a container whose network was fine. `apt-get install --reinstall iputils-ping` does not restore it; `setcap cap_net_raw+ep` does, even unprivileged. Confirmed against production: `unifi-lxc`'s ping has the capability and `net.ipv4.ping_group_range` is `65534 65534` on both, so the capability is what the fleet relies on.

  **Phase 2b — done the same day.** Three things closed out:

  - **The rig connects as the infrastructure user over sudo, not as root.** Root was inherited from the provisioning script only ever authorising the key for root, and it was wrong twice over: `become` becomes a no-op, so every privilege-escalation path goes untested, and `scripts_dir`/`logs_dir` follow `ansible_user` to `/home/root`. Authorising the key for `choco` removes the `primary_user` override entirely — the inventory got both simpler and more faithful. `TEST_CT_BARE=1` provisions the opposite, a root-only container, which is the only state where bootstrap's user-creation branch runs.
  - **`ssh_hardening.yml`'s `devpi` escape hatch generalised to `is_test_environment`**, and the lockout hazard closed properly rather than by skipping hardening. On a flagged host the connecting key is appended to the `exclusive: true` set, root login stays reachable as a second way in, and the password lock is skipped; an `assert` ordered *before* the write fails the play if the key is missing or empty. Verified both directions on CT 198: with the flag, a fresh SSH as `choco` and as `root` both work after a real hardening run; with `is_test_environment: false` the same run plans to remove the rescue key and renders `PermitRootLogin no`. `services.yml --tags ssh` now converges against a container.
  - **`tests/sandbox.sh`** — the manual counterpart to `run_tests.sh`. `--shell`, `--push` (working tree straight onto the box, no Ansible, uncommitted included), `--run`, `--status`, `--reset`, `--deb12`, `--root`. Same test-container name guard as the runner. `--reset` is soft; a true rebuild still needs `pct`.

  Still not run against a container: `bootstrap.yml` and a full `site.yml`. Hardening was the piece that made them dangerous and that is handled, but the rest of them remains unexercised.

- **`run_tests.sh` connects as root and so cannot see permission-class faults** `V:Med E:Med` — Found 2026-08-04, by the suite reporting green on a bug that was live on the same container. The cases fill disks and stop services, so the runner connects as root; the fleet's checks run as the infrastructure user under cron. Same script, same host, same minute: `❌ Upgrade log not found` as `choco`, `✅ Last upgrade: 2026-08-04` as root. Every fault that depends on file ownership is structurally invisible to the whole suite, which is exactly the class the `adm` bug above belongs to. Documented in `tests/run_tests.sh` and `tests/README.md`, and `tests/sandbox.sh --run` covers it manually, but the proper fix is for the runner to connect as the infrastructure user and have the cases escalate with `sudo` where they genuinely need to. Not attempted yet because it means editing every case, and breaking a working suite to widen it is the wrong order.

  **Partly closed 2026-08-06, from the other end.** Rather than change how the runner connects, `tests/lib/harness.sh` gained `run_uut_as <user> <script>`: the case still arranges its fault as root and then runs the script under test as the unprivileged user, which is the combination the fleet actually has. `health_upgrade_log_unreadable.sh` uses it and fails against `main`, so the permission class is no longer structurally invisible. The original item stands for the general case — every *other* case still runs the script as root — but the cheap version of the fix turned out to be per-case opt-in, not a runner rewrite.

- **`--check --diff` can be green on a run that fails immediately** `V:Med E:VLow` — Worth knowing before every laptop deploy, since the whole workflow leans on it. Observed 2026-08-04: `deploy_monitoring.yml --check --diff` against a fresh container reported `changed=4`, `failed=0` and rendered full file diffs; the real run then failed on the *first* task with `chown failed: failed to look up user choco`. Check mode does not resolve users, groups or paths on the target, so anything whose failure mode is "this identity or directory does not exist" passes silently. A clean `--check` is evidence that the *diff* is what you expect, not that the run will succeed. This is a documentation/expectation item, not a code fix — the existing note on `baseline.yml` says "worth a `--check --diff` pass per host" and should be read with this caveat.

- **Let agent-lxc build and test against the containers before anything reaches a host** `V:High E:Med` — Raised 2026-08-04, once the rig could actually run playbooks. Phase C as planned goes from *investigate* straight to *operate on a real host*, with the human tap as the only gate. The harness makes a safer middle step possible: agent-lxc proposes a fix, applies it to CT 199 or CT 198, runs `tests/run_tests.sh` and the relevant playbook there, and presents **a diff plus a test result** for approval — instead of presenting a plan and asking to run it on dockassist. The unattended half stays structurally incapable of touching the fleet, which is the property Phase B was built around, and the human still approves the apply.

  Needs: `agent_lxc_ssh_pubkey` authorised on the test containers (its key is not the laptop's `read_agent` key — see `group_vars/all/main.yml`); a repo clone on agent-lxc; and the containers running, which conflicts with `onboot 0` — either start them on demand from the sweep or accept the agent skipping when they are down.

  ⚠️ **Not now.** Tier 2 has never completed a successful run, its two bugs still block the agent-role deploy, and its cost per investigation ($0.32–0.56, July figures) is unmeasured for a loop that adds a test cycle. Sequence it after the Tier 2 fixes land and Tier 2 has demonstrably run clean for a while. Revisit as part of Phase C rather than as a separate build — see `~/.claude/plans/phase-c-operator-plan.md`.

- **`devpi` — decide: proper Pi test target, or gone** `V:Low E:Low-Med` — Resolved in the repo 2026-08-04 and recorded here so it is a decision rather than a drift. devpi was **never in `ansible/inventory/hosts.yml`**; it existed only in the old `test_hosts.yml` and one `ssh_hardening.yml` guard, both replaced. Nothing executable references it now.

  It should not come back as a general test host — the containers do that job and reset in seconds, which is exactly what a Pi requiring a reflash could not. But there is one gap no container can ever close: **aarch64 and the Pi hardware paths** (ALSA on hifipi, `vcgencmd`, thermal sysfs). LXC shares the host kernel, so an aarch64 container cannot run on x86_64 cwwk. That gap is real and has cost before — the hifipi `amixer` bug lived four months.

  If it is ever rebuilt, scope it narrowly: a fifth Pi used *only* for hardware-path checks, treated as rebuildable-from-bare by `bootstrap.yml` rather than resettable — which is now testable, since the hardening path that made bootstrap dangerous is covered. Cheaper partial alternative, **unverified**: an arm64 Debian 12 container on the laptop via Docker's `--platform linux/arm64` would cover aarch64 coreutils/util-linux/python behaviour, though not systemd and not hardware. Worth ten minutes before buying anything. An emulated aarch64 VM on cwwk is possible but a bad idea there — no KVM for arm on x86 means full emulation burning CPU on the internet SPOF that has overheated twice.

- **The hardened `sshd_config` drops Debian's `Include /etc/ssh/sshd_config.d/*.conf`** `V:Med E:VLow` — Noticed 2026-08-04 reading the hardening diff on CT 198. `templates/debian/sshd_config.j2` replaces `/etc/ssh/sshd_config` wholesale and has no `Include` line, so every drop-in under `sshd_config.d/` silently stops applying the first time the template lands. Nothing on the fleet currently depends on one, which is why it has never bitten — but it means a drop-in is not a usable mechanism on these hosts, and anyone adding one later would watch it be ignored with no error. Either add the `Include` and let the template's own settings win by ordering, or state in the template that drop-ins are deliberately unsupported.

- **🟠 `unattended-upgrades` auto-reboots every Debian host at 04:00, and nothing ever chose that per host** `V:Med E:VLow` — Surfaced 2026-08-06 while pre-flighting upgrade freshness. `tasks/debian_updates.yml:39` sets `Automatic-Reboot "{{ auto_reboot | default(true) }}"` and **`auto_reboot` is not defined anywhere in the inventory**, so every Debian host takes the default `true` with `Automatic-Reboot-Time "04:00"`. Confirmed live on cwwk.

  The origins list is **Debian-Security only** (plus Raspbian on the Pis) — Proxmox repos are *not* included, so PVE packages are never auto-upgraded. That part is right, and it means only a Debian security update can trigger a reboot. But when one does:

  - **cwwk reboots the hypervisor**, taking the OPNsense VM — and therefore the house's internet — plus every LXC, unannounced, on the box that has overheated twice.
  - **dockassist reboots Home Assistant**, including heating control.
  - **Nothing alerts on either.** An unattended 04:00 reboot is indistinguishable from a crash in everything the fleet currently monitors.

  ⚠️ **It interacts with L7.** The hand-applied drift on cwwk (PL2, `ksmtuned`) is runtime state Ansible does not manage, so an auto-reboot before L7 silently reverts it and changes what "restore the drift" means. Checked: cwwk booted **2026-07-31 13:45** (the second overheating incident) with no reboot since and no `/var/run/reboot-required` pending, so the drift is currently intact.

  **Provenance settled 2026-08-06: this repo set it, not Proxmox.** Three independent confirmations on cwwk — the value is `"True"` with a capital T, which is Jinja rendering a Python bool and not Debian's stock lowercase `"false"`; the stock line ships *commented out* and line 43 is uncommented, matching `lineinfile`'s regexp; and `apt-mark showmanual` lists `unattended-upgrades`, so the package was installed deliberately rather than pulled in as a PVE dependency. File mtime 2026-03-30, `root:root`.

  **And there is no Proxmox standard to follow, because Proxmox does not ship one.** `unattended-upgrades` is not installed by default on PVE, and the official Package Repositories documentation says nothing about unattended upgrades or automatic reboots — the only automatic behaviour it documents is *notification*: "Proxmox VE automatically checks for package updates on a daily basis. The root@pam user is notified via email about available updates." So the vendor model is notify-and-let-a-human-apply. Forum consensus (not official) is against auto-upgrading PVE hosts without testing. **"Follow the vendor standard" therefore resolves to `auto_reboot: false` on cwwk.**

  📌 **opnsense is not affected at all** — `platform/debian.yml` targets `hosts: debian_hosts`, and FreeBSD has no `unattended-upgrades`. There is nothing to decide there; it is already at vendor default.

  📌 **The reboot is not the security control.** Patches install either way; `Automatic-Reboot` only decides *when* a kernel or libc update takes effect. So `false` costs latency on kernel CVEs, not patch coverage. It is also already non-deterministic: `Automatic-Reboot-WithUsers "false"` suppresses the reboot whenever anyone is logged in, so a lingering phone SSH session silently prevents it.

  **Decision (2026-08-06): `auto_reboot: false` on cwwk only; leave `true` everywhere else.** dockassist is safe to keep rebooting — all four containers were verified `restart=unless-stopped`, so Home Assistant, Matter, Mosquitto and cloudflared all come back on their own. The Pis are media/audio and a 04:00 restart is harmless.

  ⚠️ **`false` is only safe with a detection half, and that does not exist yet.** Turning it off trades an unannounced reboot for an *unnoticed unpatched kernel* — nothing currently reports `/var/run/reboot-required`. **Add a pending-reboot check to `system_health_check.sh`** (warning, not error: a pending reboot is a to-do, not a fault) in the same change. Without it this is a downgrade, not a fix — the exact "a check that does nothing is also silent" shape this sprint exists to remove.

- **🔴 The firewall's `/usr/local/bin` is owned by an unprivileged user** `V:High E:VLow` — **Measured on opnsense 2026-08-06, and it is pre-existing, not new.** `scripts_dir` resolves to `/usr/local/bin` on that host (host-level override in `hosts.yml`), and `deploy_monitoring.yml` has always created `{{ scripts_dir }}` with `owner: {{ infrastructure_user }}`. So the directory is `choco:wheel 0755` — timestamp `Jul 21 22:47`, matching a deploy — instead of `root:wheel`. **Anything that can write as `choco` on the firewall can plant a binary in a directory on root's `PATH`**, on the host that is the internet SPOF and runs CrowdSec. It is not a privilege *escalation* by itself (`choco` has sudo) but it removes a step, and it means a compromise of the unprivileged account is immediately persistent and root-reachable.

  ✅ **"Will a firmware upgrade revert it, like it did the users?" — answered with evidence, 2026-08-06. No.** The two failure modes are different mechanisms and it matters:

  **OPNsense reverts what it *generates* from `config.xml`. It does not delete files it never owned.**

  | Thing | Generated from config.xml? | Observed across the 2026-06-13 upgrade to 26.1.9 |
  |---|---|---|
  | User accounts, uid ≥ 2000 | yes — `local_sync_accounts` reconciles and deletes | 🔴 `read_agent` **deleted** |
  | `sshd_config` | yes — `openssh.inc` hardcodes `AllowGroups wheel` | 🔴 **reverted** (hence the `sshd_config.d` override) |
  | Files in `/usr/local/bin` | no | ✅ **survived** — `clean_old_backups.sh` and `import_gpg_github.sh` (both `choco`-owned) are dated **Nov 16 2025**, `switch-vpn-country.sh` Nov 29 2025, `monit-slack.sh` Oct 6 2025, `enhanced_monitoring_wrapper` Mar 28 2026. All predate the June upgrade by 3–8 months |
  | Files in `/home/choco` | no | ✅ **survived** — read_agent's home dir and `authorized_keys` outlived the *deletion of the account itself*, left as an orphaned uid 2001 |

  So both the current and the proposed location are proven durable, by direct observation on the live host. **The move is for consistency and to fix the ownership finding — not because `/usr/local/bin` is at risk.** Do not restate it as an upgrade-durability fix; that would be an unverified claim, and the evidence points the other way.

  📌 Marginal argument for `/home` anyway: `/usr/local` is `pkg` territory, `/home` is in neither the base set nor any package set. Strictly less exposed, though nothing has ever exercised the difference.

  🧹 **Cruft found on the firewall while checking this** — unmanaged files in `/usr/local/bin` that the repo does not deploy and nothing appears to call: `monit-slack.sh` and `monit-slack.sh.old` (monit is not in the current stack), `switch-vpn-country.sh`, `import_gpg_github.sh`. Predate everything current. Worth an inventory pass when the `scripts_dir` move happens, since that change is already touching this directory — but check each is genuinely uncalled before deleting anything on the firewall.

  ✅ **Resolution chosen 2026-08-06: make opnsense consistent with the fleet** — `scripts_dir: /home/choco/.scripts`, like every other host. Feasibility checked rather than assumed:

  - **Nothing outside the inventory pins it.** The other `/usr/local/bin` references in the repo (`agent_read`, `ha_state`, `cscli` in the FreeBSD sudoers, `pve_backup_helper`, `usb_recovery_helper`) are all explicitly pathed and none derive from `scripts_dir`, so they are untouched.
  - **`logs_dir` on opnsense is already `/home/choco/.logs`**, so the host is currently *half* consistent — scripts in a system directory, logs in home. There is no design reason for the split.
  - **Ordering is already correct in the role**: directories (line 5) → scripts (18) → crons (112), so a single run cannot leave a cron pointing at a path that does not exist yet.
  - **The home directory persists across firmware upgrades** — evidence from the 2026-06-13 incident, where `read_agent`'s home and `authorized_keys` survived even after OPNsense deleted the account itself.

  ⚠️ **Three things that make this its own change and its own deploy, not a line in the plumbing branch:**

  1. **Moving `scripts_dir` does NOT fix the ownership.** Ansible simply stops asserting `choco` on `/usr/local/bin`; it does not chown it back. An explicit task setting it to `root:wheel 0755` is required, or the firewall keeps a choco-owned directory on root's `PATH` forever, now with nothing in the repo explaining why.
  2. **The old copies must be removed** (`state: absent`), or nine wrapped crons' worth of stale scripts linger in `/usr/local/bin` — precisely the drift class that let hifipi run a four-month-old script. The role already has `Remove legacy …` tasks, so the pattern exists.
  3. **It is the firewall.** 9 of 13 crons invoke `enhanced_monitoring_wrapper` from `scripts_dir`. A botched run leaves the internet SPOF's monitoring pointing at nothing — silently, which is this sprint's entire subject. Verify all 13 crons resolve after deploying, by running each path through `test -x`.

  ⚠️ **Noted while widening the directory task, and deliberately not fixed in the same commit.** The new `tasks/monitoring_dirs.yml` is a **no-op on opnsense** — same owner, group and mode the old task already set, verified against the live host — so this branch neither causes nor worsens it. But it does *re-assert* it on more playbook runs than before, because `ssh_hardening` now imports the directory task too. Fixing it properly means deciding what `scripts_dir` should be on FreeBSD (a `choco`-owned `~/.scripts` like every other host, with the wrapper moved there, versus `root:wheel /usr/local/bin` and a deploy that uses `become` to write into it) — a behaviour change on the firewall, which is its own change with its own verification. **Do not bundle it into the plumbing deploy.**

- **Repo-wide audit for the `cmd | while` subshell trap — done 2026-08-06, and it is a one-instance problem** `V:Med E:VLow` — POSIX runs the right-hand side of a pipeline in a subshell, so a `while` loop fed by a pipe discards anything it accumulates. This nearly defeated the `system_health_check.sh` exit-status fix (`check_disk_usage` counted its findings inside `df | grep | while` and threw the count away, so the one check most likely to fire would still have returned 0 while printing a red ❌). The obvious worry was that the pattern was everywhere. **It is not.** Six `| while` sites exist in the repo; five of them only `echo`, which needs no state to survive:

  | Site | Verdict |
  |---|---|
  | `scripts/common/system_health_check.sh:59` | 🔴 the real one — already fixed on `fix/agent-lxc-logs-dir-2026-08` (rewritten as a here-doc) |
  | `scripts/common/enhanced_monitoring_wrapper:453` | ✅ echo-only (output preview) |
  | `ansible/roles/platform/proxmox/files/usb_recovery_helper:195,204` | ✅ echo-only, into a redirected block |
  | `ansible/roles/services/homeassistant/templates/backup_ha.j2:103` | ✅ echo-only |
  | `scripts/services/agent/fleet_health_check.sh.j2:188` | ⚠️ accumulates, but into a **file** (`note()` appends to `$FINDINGS`), so it survives the subshell and the count read afterwards is correct |

  `scripts/services/proxmox/check_vm_status.sh:33` uses `while read … done < "$CONFIG_FILE"` — a redirect, not a pipe, so its arrays persist. That is the correct shape. Also checked and clean: `| {`, `| read`, `| for` (no instances; the `|| {` hits are error handlers).

  ✅ **Guarded 2026-08-06** (on `fix/agent-lxc-logs-dir-2026-08`, where that file lives). `note()` now carries a comment saying the file write is load-bearing and why: one of its callers runs inside `sed | while`, so a counter or an appended-to variable would be discarded in the subshell and the sweep would under-report **without failing**. It was correct by accident of how `note()` happened to be written; it is now correct on purpose.

- **`agent_access` on FreeBSD "should assert the user exists" — RETIRED 2026-08-06, the premise is stale** `V:VLow E:VLow` — Carried forward as "creates a user with `pw` that OPNsense deletes, and reports success; should assert the user exists and fail with a pointer to OPNsense user management." Both halves are wrong against what Priority 2 above already established:

  1. **The pointer would point at a closed route.** Creating the account in OPNsense's user manager so it lives in `config.xml` was tried live and does not work for a least-privilege account — `local_user_set` forces `/usr/sbin/nologin` on any user without `page-all`, i.e. full firewall admin. Telling a future operator to go there is telling them to grant a read-only agent complete control of the firewall.
  2. **The assert could never fail.** `ansible.builtin.user` uses `pw` and the account exists the moment the task returns; OPNsense removes it *later*, on a firmware upgrade, when no playbook is running. A check placed right after the creation is satisfied by construction — the exact "a check that does nothing is also silent" shape this sprint exists to remove.

  The account being wiped by upgrades is **accepted and documented**, not a bug: recovery is one idempotent command (`agent_access.yml --limit opnsense`, ~9s, verified from a fully wiped account) and the real gap was always *detection*, which Tier 1's hourly `ssh <host>-agent` sweep now covers — with back-off, so a wiped account is reported rather than hammered. Nothing to build. The open acceptance criterion stands as written: confirm `ssh opnsense-agent` after the next real firmware upgrade.

- **`roles/services/unifi` never creates `logs_dir` either** `V:Low E:VLow` — **✅ FIXED 2026-08-06.** Third instance of the class, and the direct twin of the agent-role bug that caused the 12-day outage: three of this role's crons redirect into `logs_dir` (service check `*/13`, web check `*/15`, backup at 03:00) and nothing in the role creates it. Latent only, because unifi-lxc's directories were made by an earlier `deploy_monitoring.yml` run — it would bite a rebuild, which is exactly the situation agent-lxc was in. Fixed with the role's own directory task rather than an import, matching `roles/services/agent`, since roles are self-contained here. ⚠️ **Not verified on a host** — there is no UniFi test container and installing the controller on CT 199 is well out of proportion. Tag selection was checked with `--list-tasks` under a static `roles:` include (`cron`, `scripts`, `logs`, `backup` all select it); the task itself is the same three-line `file:` module already proven on CT 199 through the playbook half.

- **`Create SSH monitoring script` deploys into `scripts_dir` without ensuring it exists** `V:Low E:VLow` — Fourth instance of the same class, found 2026-08-04 when a hardening run hit a container whose `~/.scripts` had been reset away: `Destination directory /home/choco/.scripts does not exist`, play fails. Same root cause as the tag mismatch above — tasks that write into `scripts_dir`/`logs_dir` assume some other playbook created them. Worth fixing as one change: a single directory-creating task that every consumer depends on. **✅ FIXED 2026-08-06** — done exactly that way; this task now imports `monitoring_dirs.yml` first. It is the only one of the four instances that fails *loudly*, which is why it was the last found and the least harmful.

- **`services.yml` errors on a host with no `primary_function`** `V:Low E:VLow` — Found 2026-08-04 pointing the test inventory at a fresh container. `services.yml:46` evaluates `primary_function == "media"` with no `is defined` guard, and `import_tasks` applies that `when` to every imported task, so the play aborts rather than skipping. Latent on the fleet (every host sets it) but it makes any new or test host fail on first contact. `primary_function | default('') == "media"` in both places (media_storage and cobra_scripts).

  **✅ FIXED 2026-08-06** — and it was **seven** comparisons, not two: media_storage and cobra_scripts plus the five `include_role` gates for pihole, unifi, plex, transmission and samba. Reproduced first (`services.yml --tags media` against a scratch inventory host with no `primary_function` → `A 'when' expression failed ... 'primary_function' is undefined` at `services.yml:46`), then re-run on the fix → 25 tasks skipped, 0 failed. The test inventory's comment saying `primary_function` "has to be set to *something*" is now obsolete and has been corrected.

### Very Low Value/Effort — Revisit only if conditions change

- **Tidal and Qobuz Receiver on hifipi** `V:Low E:Blocked` — Depends on a good open-source receiver emerging. Not actionable today.
- **DNS Failover Wrapper Consistency** `V:VLow E:High` — `monitor_dns_failover.sh` is intentionally standalone: it resolves Slack by IP when DNS is down, which the wrapper can't do. Risk of refactoring outweighs cosmetic benefit.
- **Mullvad DoT Fallback** `V:VLow E:Med` — Encrypting DNS during full VPN outage. Near-irrelevant with 4-tunnel architecture.
- **Full Infrastructure as Code (Proxmox/OPNsense)** `V:Med E:VHigh` — High complexity for rarely-changing configs. Good config backups are sufficient.

---

## Resolved Items

- **April 2026 deployment backlog — deployed and verified 2026-07-21** — Three items (old Priorities 1–3) had been written, linted, and committed on 2026-04-08, then never applied: each one's "Next Steps" was gated on a Touch ID-backed Ansible run that never happened. They sat as *code in the repo describing infrastructure that did not exist* for ~3.5 months, while the doc read as though the work were essentially done. All now deployed and live-verified:
  - **disable-hdmi fix** — `tvservice -o` → `vcgencmd display_power 0`. Deployed to hifipi (vinylstreamer had somehow already received it). **The April scoping was wrong on two counts:** it named only the two Trixie hosts, but `dockassist` (Bookworm) had the identical `status=203/EXEC` failure — `tvservice` is absent there too, so this was never Trixie-specific. Fixed on dockassist as well. Fleet now reports **0 failed systemd units on all 6 Debian hosts** (was 3).
  - **read_agent sudoers expansion** — deployed to all 7 hosts. All four April acceptance criteria now PASS (`systemctl --failed` on cwwk, `fail2ban.log` on dockassist, `service crowdsec status` and `cscli decisions list` on opnsense). Two bugs found and fixed while verifying: the new `cscli decisions list *` / `alerts list *` / `metrics *` and `systemctl --failed *` / `list-timers *` rules all had a **trailing `*`, which sudo requires to match at least one argument** — so the bare, most obvious invocation (`sudo cscli decisions list`) still prompted for a password. Added explicit no-args variants alongside each wildcard rule, matching the pattern already used for `zpool list`/`zfs list` after the same bug was found there in April. Lesson: a trailing `*` in a sudoers rule is not "optional arguments".
  - **system_health_check.sh** — `SERVICES="ssh cron fail2ban"` deployed to all 6 Debian hosts (verified by reading the rendered file on each). opnsense correctly keeps the FreeBSD branch (`sshd cron`) — it runs CrowdSec, not fail2ban.

  The `read_agent` sudo expansion paid for itself immediately: the first fleet-wide `systemctl --failed` sweep it enabled is what surfaced the dockassist HDMI failure above, which no existing monitoring reported.

  **Process takeaway:** "code merged" was recorded as "done". The acceptance criteria in this document were the right ones and would have caught all of it — they were simply never run. Prefer verifying against live hosts over trusting the doc; where a change can't be applied in-session, the item should stay conspicuously open rather than reading as complete.

- **opnsense `read_agent` access restored** — 2026-07-21. Found fully broken (`Permission denied (publickey)`); root cause was the account having been dropped by OPNsense config regeneration, not a key problem. Re-running `agent_access.yml --limit opnsense` recreated the user, restored `AllowGroups wheel read_agent`, and reinstalled sudoers; verified `id`, `service crowdsec status`, and `cscli decisions list`. **This will recur** — tracked as Priority 2, which is about durability and detection, not this one-off recovery.

- **Now-Playing Amp Control (power + IR input switching)** — Completed 2026-07-18, physical E2E verified same day. Full architecture + behavior documented in `docs/AUDIO_AUTOMATION.md`. Power control merged #4 (2026-07-13), phantom-start/night-cycling fix merged #6, input switching merged #10 (signed `dafc92a`): `automation.amp_input_select` drives the 4-way RCA switcher via the RM4 Mini (`rca_switcher/input_pi`|`input_tv`, 3s debounce on source change, instant re-align on plug power-on); learned codes checked into the role and seeded to `.storage` only-if-missing. Physical verification with the amp wired (recorder data 2026-07-18): instant power-on with ~12W idle draw, three full 5-min-grace auto-offs (13:06/13:11/14:19 UTC), input switching fired on real source changes (pi↔tv including the both-active Pi-wins case), cycling watchdog silent, zero Broadlink errors. Remaining ideas tracked separately: TV idle auto-off (Lower Priority), extra switcher positions only if new sources get wired.

- **Shelly Gas false "back to normal" alert storm — root cause + fix** — Resolved 2026-06-30. The kitchen gas detector spammed `#home-alerts` with `✅ Gas detector back to normal` (14 in 6 days) despite no real event and the Shelly app showing every device online. Traced via the recorder DB + HA log: the two Shelly **Gen1** gas units (`SHGS-1` — `…f510` Kitchen, `…fb5f` Boiler Room), plus the two Gen1 lights, had CoIoT in **multicast** mode (`coiot.peer` empty), so HA got no reliable push and fell back to HTTP polling — every timed-out poll flipped the entity `unavailable` for a few seconds, and `shelly_gas_fault_recovery` fired on each `unavailable→normal` with **no debounce** (the FAULT side has `for: 5min`; recovery had none). Two-part fix: (1) **device** — set CoIoT unicast peer `10.30.100.100:5683` on all four Gen1 devices (`GET /settings?coiot_peer=…`), the HA-recommended config for Gen1; confirmed push flowing via raw-socket capture of device→HA:5683, which also empirically proved there's no client isolation on the `…_iot` SSID. (2) **automation** — added a symmetric `condition: template` to `shelly_gas_fault_recovery` so recovery only alerts when the prior unavailable/fault lasted ≥300 s, mirroring the FAULT debounce; deployed via ad-hoc `template` module + HA restart, `check_config` clean, and verified the restart's own `unavailable→normal` blip fired the recovery automation **0 times** (pre-fix this produced a phantom alert per restart). **Caveat — self-inflicted incident:** an AP-roaming tweak attempted mid-session (`/settings/ap_roaming?enabled=true`) knocked both gas units off Wi-Fi (no AP stronger than the −70 threshold → scan/drop loop); recovered by reverting `ap_roaming=false` from the OPNsense gateway (authoritative cross-VLAN ARP/reach) and the device's own `shellygas-XXXX` recovery AP. **Do not enable AP roaming on marginal-signal Gen1 devices.** Device-side CoIoT/roaming config lives only on device flash — see new Lower Priority items.
- **Shelly smoke + gas detector Slack alerts** — Completed 2026-06-13. Added HA automations for two Shelly Gas units (`shellygas-…f510`, `…fb5f`) and one Shelly Plus Smoke (`shellyplussmoke-3076f523fd68`) in `automations.yaml.j2`. Gas: alarm (mild/heavy)/cleared/sensor-fault/recovered → `slack_alert` (#home-alerts), self-test → `slack_notify`. Smoke: alarm/cleared/low-battery(<15%)/offline(26h debounce) → `slack_alert`, back-online → `slack_notify`. Trigger states verified against live entities; `area_name()` templating resolves the gas unit to "Kitchen". Verified end-to-end via Slack: self-test fired the automation and posted correctly. Key finding: the system *looked* broken only because routine messages were going to `#home-logging` (a firehose with a `Script Execution: SUCCESS` every ~10 min) instead of the watched `#home-alerts` — see memory `slack-alert-channels`. The smoke detector's "broken integration entry" errors were just the battery/sleeping device having been added while asleep; waking it populated all entities. Offline detection for the sleeping smoke unit uses a deliberately long (26h) `for:` debounce — may need tuning once its real reporting cadence is observed. Not live-fire tested: a real mild/heavy gas alarm and a real smoke alarm (would require injecting a fake reading or pressing the physical test button) — alarm path proven by composition (alert-channel delivery + identical automation mechanism both confirmed).
- **unifi-lxc + opnsense SSH key recovery + vault password handoff** — Completed 2026-05-12. After rotating to a new touchid-agent ssh key, `ssh unifi` and `ssh opnsense` both failed `Permission denied (publickey)` — these two hosts had drifted off the GitHub key set while the others had been re-synced by a recent `services.yml` run. Recovered access by appending the touchid-agent pubkey to `/home/choco/.ssh/authorized_keys` via `sudo pct exec 101` (unifi LXC) and `sudo qm guest exec 100` (opnsense VM with QEMU guest agent). Then re-ran `services.yml --tags keys --limit unifi-lxc,opnsense` to canonicalize authorized_keys against `https://github.com/ignaciojimenez.keys` — verified `changed=0` on second pass, so both hosts now match the codebase and consume GitHub as source of truth going forward. Side fixes: vault password handoff moved from missing `~/.ansible/vault_pass` to repo-tracked `bin/vault_pass.sh` (calls `security find-generic-password -s ansible-vault-master`); ansible.cfg updated; ARCHITECTURE_DECISIONS.md documents the iCloud-Keychain handoff. Also fixed: `/usr/local/bin/update_keys` shebang was `#!/bin/bash`, which is missing on FreeBSD — changed to `#!/bin/sh` in `ssh_hardening.yml` (body is a single curl call, fully POSIX). Several deferred findings captured in Lower Priority above: root-shell lock breaking OPNsense console, uri fetch skipping in check mode, fresh-laptop setup doc, full unifi-lxc standardization audit.
- **Monitoring log-path audit + SSH-play idempotency + CI Jinja check** — Completed 2026-05-10/11. Investigated `update_ha` cron alert (`tee: /home/choco/logs/ha_update.log: No such file or directory`) and uncovered a structural bug in the HA role: `with_fileglob` was deploying both `update_ha` (plain, hardcoded `$HOME/logs/`) and `update_ha.j2` (templated, correct path) side-by-side — the plain script was the one running. Audit found the same pattern in `backup_ha`, `stop_run_ha`, `dockassist_monitor.sh`, `vinylstreamer_monitor.sh`. All converted to templates rendering `LOG_FILE` against `{{ logs_dir }}`. Templates moved from `roles/.../files/` to `roles/.../templates/`. Standardized `detect_audio.log` onto `logs_dir`. Deleted orphan `scripts/services/homeassistant/backup_ha.sh`. Added `scripts/ci/check_jinja_syntax.py` to the lint workflow — would have caught the `{{ .Names }}` Docker-format/Jinja2 collision in `stop_run_ha.j2`. Fixed `services.yml` auto-discover `include_role` so `--tags <role>` works without also passing `services`. Resolved SSH hardening play perpetually-`changed` noise: removed `ansible_date_time.iso8601` from `sshd_config.j2`, folded `TCPKeepAlive`/`LoginGraceTime` into the template (was fighting `lineinfile`), dropped the redundant standalone backup task (the template module already does `backup: true`). Verified `changed=0` on second pass across cobra, dockassist, hifipi, vinylstreamer, cwwk. Codified script-location convention in `AGENT_INSTRUCTIONS.md` (lifecycle scripts → role templates/, monitoring → `scripts/services/`, cross-service → `scripts/common/`). Commits: `3687808`, `63b63bf`, `4ea62c3`.
- **fail2ban Backend Fix (dockassist + cobra)** — Resolved 2026-04-08. fail2ban 1.0.2 on Bookworm needs `backend = systemd` because auth logs go to journald, not `/var/log/auth.log`. SSH brute-force protection was absent since October 2025 — fail2ban crashed on every boot with `"Have not found any log file for sshd jail"`. Fix: added task in `install_base_software.yml` to deploy `/etc/fail2ban/jail.d/sshd.conf` with `backend = systemd`. Deployed via Ansible ad-hoc and verified active on both hosts. Also added fail2ban to `system_health_check.sh` critical services list. Note: Trixie hosts (hifipi, vinylstreamer) run fail2ban 1.1.0 which auto-detects this — unaffected.
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
