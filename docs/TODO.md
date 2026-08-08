# Infrastructure TODO — Prioritized Action List

Updated: 2026-08-01 | Validated against live hosts via read_agent autonomous assessment

This document is the single source of truth for pending infrastructure work.
Each item includes verified current state, concrete next steps, and acceptance criteria.
Items are ordered by risk × effort — highest-impact, most-actionable items first.

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

**Phase C — operator mode.** Sketch only; needs its own decision round (passphrase key vs SSH-CA, sudo scope, audit logging). The plan files Phase B now writes are its input, already in a stable format.

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
- **Ephemeral Ansible Testing Environment** `V:High E:High` — Provision ephemeral LXC containers on Proxmox for end-to-end playbook testing. High payoff for major refactors, but current CI lint + `--check --diff` workflow has been sufficient. Revisit after Priority 5 proves out the `community.general.proxmox` provisioning pattern, which makes Phase 1 nearly free.

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
