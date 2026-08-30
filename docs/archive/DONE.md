# DONE — the executed backlog

Completed work, distilled. **One entry per finished item: what changed, and the
decision behind it — "we did X because otherwise Z".** Not a diary.

**What this file is for:** stopping a future session re-deriving a conclusion
that was already paid for, or re-proposing something already refused.

**What it is not:** the architecture. Standing rules you would consult *before
designing something new* live in
[`ARCHITECTURE_DECISIONS.md`](../ARCHITECTURE_DECISIONS.md); entries here point
there rather than restating. Open work lives in [`TODO.md`](../TODO.md).

> Full narrative — measurements, forced-failure tables, retractions — is in git
> history. `git log --follow docs/TODO.md` and read the commit that removed a
> section. Nothing here needs to reproduce it.

---

## 2026-09-01 — vinylstreamer's wifi lockout: every software layer excluded, and parked

**Decided: accept the plug as permanent remediation, because the fault is below
everything software can reach.** Not "gave up" — each layer was excluded by
direct test, in order, over five days.

The host stays fully running and drops off wifi. NetworkManager times out
mid-association (`ASSOC-REJECT status_code=16`, all-zero BSSID — no AP ever
answered), misreads that as missing credentials *one line after logging that
secrets exist*, and lands on `failed (reason 'no-secrets')` — a reason meaning
"a human must intervene". It then emits nothing at all: 28 minutes of silence on
2026-08-24, ~22 hours on 08-23.

**What was tried, and what each attempt proved:**

| Attempt | Result |
|---|---|
| `connection.autoconnect-retries=0` | **Disproven.** Verified in effect via `NetworkManager --print-config`; the host gave up anyway. A `no-secrets` failure appears to *block* autoconnect rather than exhaust a counter, and a counter cannot reach a block |
| `802-11-wireless.powersave=2` | **Helped, did not fix.** Took the fault from roughly 4-hourly to roughly daily, for a measured **+0.049 W** (+3.3%, ≈0.43 kWh/yr). Kept |
| `nmcli con up` (ladder layer 1) | Tried, failed |
| interface bounce (layer 2) | Tried, failed |
| **`brcmfmac` reload (layer 3)** | **Ran for real on 08-30 and failed** — `rmmod brcmfmac_wcc: ok / rmmod brcmfmac: ok / modprobe brcmfmac: ok`, and the radio still would not associate |

Only removing power clears it. **So the fault sits below NetworkManager, below
the link layer, and below the driver** — the on-board Broadcom radio or its
firmware reaches a state that a cold start resets and a software reload does not.

⚠️ **The 08-29 verdict was void and nearly became the conclusion.** The ladder
reported "all three layers failed", but `brcmfmac` is held by `brcmfmac_wcc`, so
`modprobe -r brcmfmac` failed with *module in use* — and the error was swallowed.
The tell was that the journal for that window contained **no brcmfmac lines at
all**. Layer 3 now removes the dependent first and reports every step. *A layer
that cannot run must never be mistaken for a layer that ran and did not help.*

**Ruled out along the way:** an AP or VLAN-wide event — HA drove the Shelly plug
(wifi, same VLAN, same AP) while vinylstreamer was off-network, and wired
dockassist saw nothing.

**What stays, and why:**
- **The plug watchdog is now load-bearing, not a backstop.** It is the only thing
  that recovers this host. Its 15-minute threshold and 1 h cooldown are
  production settings.
- **`powersave=2`** — measurably free, and it cut the frequency several-fold.
- **`wifi_reconnect.sh`** (`*/5`) — it can no longer recover anything, but its
  per-layer reporting is what produced this verdict and is what would show the
  fault changing shape.

📌 **The one untried avenue is hardware: swap in a newer Pi.** Spares are on
hand. A Pi 4/5 has a different wireless chain and the option of wired, so it
replaces the failing part rather than nursing it. **Keep everything else
identical — same SSID, same position, same `powersave=2` — so the radio is the
only variable.** If the fault stops, that confirms the on-board radio; if it
does *not*, that is the more interesting result and points at the AP or the
environment instead.

🔴 **Do not give `wifi_reconnect.sh` a reachability-based health check.** An
early version pinged the VLAN 100 gateway, which by firewall policy answers no
ICMP from inside that VLAN — while answering normally from every other VLAN, so
it looked entirely sound tested from a laptop. On cron it reloaded the wifi
driver every two minutes against a perfectly healthy radio until the host fell
over. Health is judged from local facts only.

🔴 **Reading `wifi_reconnect.log` for evidence: decompress the rotations.**
`agent_read` returns raw gzip bytes, so grep over a `.gz` returns 0 matches and
reads as "it never happened". That produced a false negative twice, including
once on this very question (`ladder_starts: 0` in the live log while both runs
sat in a rotated file). Tracked as item 22.

---

## 2026-09-01 — the health check that pages the whole fleet on the 1st of every month

Six hosts paged between 00:02 and 00:32 — unifi, cobra, dockassist, hifipi, cwwk,
agent-lxc — every one otherwise green, every one failing the same line:
`No upgrade activity found in logs - ACTION REQUIRED`.

`check_auto_upgrades` measured upgrade freshness by grepping only the **live**
`unattended-upgrades.log`. Debian rotates that log **`monthly`**
(`rotate 6, compress`), so on the 1st it is an empty file from just after midnight
until `apt-daily-upgrade.timer` fires at ~06:00–07:00. Every host whose `2-59/15`
health check lands in that window reports a fault it does not have.

**Fixed by falling back to the newest rotated log (`.1`, then `.1.gz`) when the live
one has no run line yet.** The alternative — widening the window or dropping the
check — would have silenced a probe that still has a job to do. The recovered date
is still parsed and still measured against `STALE_DAYS`, so a host that genuinely
stopped upgrading last month still reads ~30 days and still fails. Only the rotation
window stops lying.

### Three investigations, one cause, and all three wrong about the cadence

The fleet agent investigated **three of the six hosts separately** — unifi $0.44,
cobra $0.33, dockassist $0.22 — and reached the same non-conclusion three times, at
**$0.99**. The other three alerted after those ran and got no investigation at all,
so the spend did not even buy coverage.

🔴 **All three summaries said the rotation was *nightly*** and framed the fix as
stopping a daily recurrence. The config says `monthly`, and the `.gz` files are
dated the 30th/31st of each month. That is not a detail: a nightly annoyance would
have been caught by watching for a week, and this would have "self-cleared" every
morning while returning on the 1st of every month. **Reading one config file changed
the item's whole shape.** An investigation summary is a hypothesis with a price tag,
not a measurement — verify the single fact its recommendation turns on.

### Verified against the live fault, not a fixture

`tests/unit/auto_upgrades_rotation_test.sh` pins both halves — the rotation window
must cost nothing, and a 40-day-old run must still be `ACTION REQUIRED`. Run against
the *pre-patch* script it goes red on exactly the production line, under macOS `sh`
and under Debian `dash` on cwwk.

The stronger proof came from the clock: the deploy landed at ~00:55, while the live
log was **still 0 bytes** on every host. So the fix was exercised against the real
fault condition rather than a fixture — cwwk, dockassist and hifipi each reported a
green `Last upgrade: 2026-08-31`, and `system_health_check.sh` exits **0 on all seven
Debian hosts**.

📌 **Deployed with `--tags scripts --limit debian_hosts`, not the untagged playbook.**
Untagged, `deploy_monitoring.yml` also runs the full `platform/proxmox` and
`platform/opnsense` roles and imports SMART monitoring — a whole platform role against
the internet SPOF to ship a one-line change to a Debian shell script. The narrowed run
touched one file per host and nothing else; `changed=0` on the second pass.

📌 Also corrected: the comment at `system_health_check.sh:953` claimed the
infrastructure user "is not in `adm` on any host bootstrap created". Stale —
`debian_baseline.yml:58` puts the primary user in `adm`, verified on cwwk, cobra,
dockassist and hifipi. The permission-warning branch it justifies is dead code on
those hosts.

## 2026-08-31 — the VFIO residue that was left on purpose, and the reason it was left was wrong

**Decided:** the two VFIO lines cwwk logs once per host boot are now excluded
too — `vfio-pci <BDF>: enabling device (NNNN -> NNNN)` and
`VFIO - User Level meta-driver version: N.N` — **because** the reason given on
2026-08-19 for leaving them was factually wrong, not merely a cost call.

That entry reasoned: *"they are logged once per module load, so their timestamps
are stable, their md5s dedup correctly, and they were already in cwwk's state
file."* The first half is false. `dmesg -T` renders wall-clock timestamps at
**read** time from a ring buffer that is emptied by a reboot, so after every
boot those lines carry new timestamps, hash to new signatures, and dedup cannot
suppress them. Being in the state file was a property of that boot only. The
reboot on 2026-08-30 23:51 paged, exactly as the mechanism requires — and
`last -x reboot` shows four reboots in the preceding three weeks, so the
"one alert per host reboot" this was traded for was not the rare event the
trade assumed.

**Refused, again and deliberately: do not fix this in the dedup.** Hashing the
line with its timestamp stripped would silence every boot-time message forever,
including a passthrough fault that recurs after a reboot — which is precisely
the failure this check exists to catch. The dedup is correct: a new boot's
messages genuinely are new events. Excluding named benign lines stays the only
sanctioned lever, per the rule this same check established
([2026-08-19](#2026-08-19--exclude-the-benign-line-never-the-pattern-cwwks-vfio-false-positive)):
*exclude the benign line, never the pattern.*

Both new patterns are end-of-line anchored, so a bind that fails
(`enabling device (0002 -> 0003) failed`) still alerts.

**Proven by forcing the failure on cwwk**, against real `dmesg` (1,116 lines)
with a **fresh** state file, so dedup could not account for any silence:

| injected line | exit |
|---|---|
| *(none — real buffer incl. both boot lines)* | `0` OK |
| `vfio-pci 0000:01:00.0: Failed to reset device` | `1` WARNING |
| `vfio-pci 0000:01:00.0: enabling device (0002 -> 0003) failed` | `1` WARNING |
| `vfio-pci 0000:03:00.0: DMAR: DMA fault` | `1` WARNING |
| `VFIO - User Level meta-driver version: 0.3 (tainted)` | `1` WARNING |
| the three benign forms, at fresh timestamps | `0` OK |

The deployed copy was then confirmed byte-identical to the repo
(`58645a0aa18234151f72f027e821af74`) and re-run as the cron user with a fresh
state file: exit `0`. `tests/unit/kernel_vfio_benign_test.sh` went 8 → 12
assertions and was confirmed **red against the pre-fix script** first.

🔴 **The lesson is about the shape of the argument, not VFIO.** The 2026-08-19
session enumerated the input space correctly — four distinct line forms — then
declined to act on two of them on the strength of a mechanism it had not
tested. It had *already been burned that same session* by a fixture that went
green while the host failed. Enumerating an input is not the same as verifying
what it does: the two lines were seen, named in the write-up, and reasoned
about, and the reasoning was still wrong. **If a line is inside the pattern and
you are choosing not to exclude it, the claim "it dedups correctly" is a
prediction — force the condition (here: reboot, or empty the state file) and
watch it.**

---
## 2026-08-30 — the public repo mapped the wireless topology (TODO item 24)

`docs/NETWORK.md` carried a full `SSID → Network → VLAN → L2 isolation → PMF`
table plus a section headed *"The IoT SSID has protected management frames
disabled"*, naming the SSID. The repo is public.

**The distinction that decided the fix.** SSID names are broadcast in beacons and
`pmf_mode` is advertised in RSN capabilities — both are readable by anyone in RF
range, and pretending otherwise would have been theatre. What was *not* remotely
discoverable was the **correlation**: which SSID lands in which VLAN, where L2
isolation is absent, and that the weak-PMF one fronts the segment controlling
heating and mains power. That correlation is what dropped recon from *"be on site
and analyse beacons"* to *"read GitHub"*.

**So: publish the mechanism, move the correlation.** The wireless table and
findings 8 and 9 went to `docs/local/WIRELESS.md` (gitignored). `NETWORK.md` keeps
both findings — mechanism, severity, the "very likely deliberate" caveat, and the
statement that redaction is not the fix — and links to where the identifiers went.
A redaction that leaves only hints would have been the worst of both.

**Generalised into a standing rule** rather than left as a one-off:
[*Disclosure tiering*](../ARCHITECTURE_DECISIONS.md#disclosure-tiering--what-goes-in-a-public-repo),
which asks one question — *does this shorten the path from "be in range" to "know
which weakness to hit"?* — and sorts into tracked / `docs/local/` / vault. It also
gave `docs/local/` (which already held `CONSOLES.md`) a README and a reason to
exist beyond "seemed sensitive". A holistic sweep applied the same rule to
`TODO.md`, `archive/DONE.md` and `ARCHITECTURE_DECISIONS.md`: SSID names replaced
by segment descriptions, the HomePod's MAC moved out. Docs stayed readable — the
segment is what the sentences were actually about.

⚠️ **This narrows future exposure only.** The tables are in git history, in every
clone; GitHub serves the old blobs at their commit SHAs. **No history rewrite was
performed** — that is a separate, explicit decision, now TODO item 32, whose
default is *no*.

📊 **Measured while closing this, and it reframed the whole item.** GitHub's
14-day traffic API returned **222 clones from 85 unique cloners** against **4
views from 1 unique viewer**. Nobody reads this repo in a browser; automation
clones it constantly, and a clone takes the full history. So the old tables are
already out at scale, a rewrite would recover nothing (0 forks notwithstanding) —
*and* every future commit here is pulled by ~85 unique cloners within a
fortnight. That second half is the real reason the tiering rule is worth
keeping.

🔧 **Redaction is not remediation.** The weakness itself — PMF disabled on that
SSID — is untouched and is now **TODO item 31**, ranked above the rewrite
question on purpose. Wireless config was deliberately *not* changed in this
work: enabling PMF needs a check of what fails, and belongs in its own change.

## 2026-08-30 — an allowlist entry that was hiding a firewall gap

`dockassist` (VLAN 100) reached the HomePod on `7000` but was **blocked on the
ephemeral port** pyatv negotiates for the AirPlay event channel, so the
`apple_tv` entry never finished setup — it retried once a minute and stalled HA
`bootstrap` on every restart since ~23 Aug. Cause: the floating AirPlay rules are
**fixed destination ports only** (`5000`/`7000`/`7100`/UDP `3722`), and VLAN 100
is not in the `Trusted_VLANs` allow-all group.

**Fixed** with one floating rule: source `10.30.100.100` only, destination the
**`Music_Players` alias** (so hifipi is covered by the same rule), TCP
`49152–65535`. ⚠️ **Rejected:** adding VLAN 100 to `Trusted_VLANs` — that hands
every IoT device an allow-all to fix one integration.

📌 **The lesson: it had already been silenced.** `media_player.bathroom_2` and
`remote.bathroom_2` were in `ha_entity_health_allowlist` because they were
permanently `unavailable` — which was this bug. **An allowlist entry claims an
entity is expected to be dead; when that claim is wrong it hides a real fault
until someone re-checks it.** Both entries removed once the entities came up.

🐛 **Tag gotcha:** `ha_entity_health_allowlist` is consumed by
`check_ha_entities.sh.j2` under `tags: [homeassistant, monitoring]`.
`--tags config` returns `changed=0` and looks like success.

## 2026-08-30 — the floor lamp that switched itself on, and an alert that was simply true

**The alert:** `check_ha_entities.sh` paged `#home-alerts` at 29 Aug 23:30, exit
5 — five entities of the Shelly Duo Bulb G3 `48f6eebd40d4`
(`light.floor_lamp_new`, `10.30.100.238`, VLAN 100) unavailable past the
15-minute grace. **It was true.** The bulb was gone 23:07 → 23:37, ~30 minutes,
and returned by itself. Signature in the HA log is the same pair every time:
`aioshelly.rpc_device.wsrpc: Invalid Message from host 10.30.100.238:80`, then
`Error fetching … while reconnecting`.

**Decided: change nothing about the check**, **because** the outage was twice
the grace window. Widening `ha_entity_health_grace_seconds` would have turned a
correct alert into a slower correct alert while blunting it for every other
device — the classic trade this repo already refused on 28 Aug for
`light.book_floor_lamp`, where the answer was also the device and not the
threshold. The discriminating evidence was cheap and worth recording: **Home
Assistant logged exactly two lines in the entire 90-minute window, both about
this bulb.** A network or HA-side event cannot be that quiet, so the fault was
localised without touching anything.

**The change that was made is a device default, not repo config.** The bulb's
`CCT.GetConfig` reported `initial_state: "on"`, so *every* reboot switched the
lamp on regardless of prior state — which is why it sat lit at 4% from 23:37
until morning with nobody asking. Set to `restore_last` over
`CCT.SetConfig` (verified against the official CCT docs before writing, not
assumed; `cfg_rev` 51 → 52, `restart_required: false`). **A night-time reboot is
now invisible instead of illuminating an empty room.**

⚠️ **Not concluded, deliberately: whether the bulb wedged or lost power.**
`sys.reset_reason` read `1`, but Shelly does not document that field's value
mapping — the obvious ESP-IDF reading is a guess. Recorded as unresolved rather
than written up as a cause. A future session should not treat `reset_reason` as
meaningful without verifying the mapping first.

📌 **The recurrence is still open as TODO item 27** — four drops in 13 days
(17 Aug ×2, 18 Aug, 29 Aug), all self-healing, and the bar for acting on them is
a fifth, not a hunch.

## 2026-08-30 — CI was red for 11 days with the alarm working perfectly

**The fault:** `ansible-lint.yml` failed on **every push from 18 to 29 Aug** — 22
runs, always the same step (`ShellCheck the test harness`), never any other.
Three findings, introduced with test files added over that window:
`run_unit_tests.sh` checking `$?` after an assignment (SC2181),
`health_maintenance_window.sh` reading `$_uut_status` out of the harness
(SC2154), and `ha_entity_health_test.sh` splitting 200 generated arguments
(SC2046, where the split is the mechanism). Fixed in `0a14ee0`, merged `0e54911`.

**Decided: do not add a local lint gate**, **because** this was never a
detection problem. CI caught the fault on all 22 pushes and emailed every one,
and Ignacio *receives* those emails. Nothing went undetected; nothing went
unsent. A `tests/lint.sh` plus a pre-push hook would have been a 23rd detection
of something already detected 22 times, behind a hook `--no-verify` walks past.
**The broken hop was `notice → act`, and only that hop.**

**So the fix was routing, not detection.** This repo already draws the
distinction in its own vocabulary: `slack_alert` → `#home-alerts` is watched,
`slack_notify` → `#home-logging` is an unwatched firehose. **GitHub's failure
email is `#home-logging`.** A final workflow step now posts a red `main` to
`#home-alerts` (`5e2e5f6`), webhook in a GitHub encrypted secret because the
repo is public.

**Gated to `failure()` on a push to `main`, deliberately.** A red branch is the
author's problem while they are watching it; a red `main` is what went
unnoticed. Alerting on both would turn the one watched channel into a second
`#home-logging` — the exact failure being fixed.

**Verified by forcing it, not by reading YAML.** `3ebfa81` deliberately broke
shellcheck on `main`; run `33280938971` went red and the message reached
`#home-alerts` at 01:26:40 CEST with the right SHA and a resolving run link.
Reverted in `db674fa`, whose green run posted nothing. Both branches observed on
the real runner. The payload is built with `jq` and was checked against a commit
subject carrying quotes, braces, a backslash and a newline — output stayed valid
JSON with exactly the key `text` and no injected key. The commit subject reaches
the script through `env`, never `${{ }}` inside `run`, which on a public repo is
shell injection.

**Two things cost time and are worth not repeating.** The step was first written
one position too early, where `failure()` cannot see the final step fail — a
notifier that would never have fired for a `Validate role structure` failure.
And `- name: Alert #home-alerts …` unquoted: ` #` opens a YAML comment, which
silently truncated the name to `Alert` and turned the rest into a comment
ansible-lint rejected, turning `main` red (`5e2e5f6` → fixed `600e75f`). **A
step-order dump printed `12. Alert` and the truncation was read straight past.**

**Also landed:** `actions/checkout@v4 → v7` and `setup-python@v5 → v7`
(`813a336`), off the deprecated Node 20 runtime — verified against each action's
own `action.yml` rather than assumed, and each major's notes checked for
anything touching this workflow (nothing did).

**Left open, and it needs Ignacio:** the failure email now duplicates the Slack
alert. There is **no API** for that preference — `/user/notification_settings`,
`/settings/notifications` and `/user/preferences/notifications` all 404, so it is
a UI toggle — and it is **global across the 10 repos that have workflows**, not
per-repo. See TODO item 26.

---

## 2026-08-28 — HACS removed, and dockassist proves idempotency for the first time

**Decided:** HACS is gone rather than gated, **because** it was installed,
loaded on every boot, refreshed a 2.6 MB repository catalogue — and had
installed **nothing**. `custom_components/` contained only HACS itself, and its
only entity was `update.hacs_update`.

**What keeping it cost:** three role tasks ran unconditionally on every deploy —
`curl -fsSL https://get.hacs.xyz` then `bash` it — inside the container holding
`secrets.yaml`, the HA monitor token and the Cloudflare tunnel token. Unpinned
remote code execution as root, no checksum, no version pin, re-rolled every run
rather than once at install time.

**Why removal beat gating:** gating means the remote code runs once; removal
means it never runs again, and nothing here used the capability. Reinstalling
deliberately later is cheaper than carrying the path indefinitely.

📌 **It was also why this host could never reach `changed=0`.** Those three
tasks were the permanent `changed=3` on a second run — the repo's own stated
proof of convergence — so dockassist could not demonstrate idempotency at all,
and a genuine unexpected change would have hidden among three expected ones.
**Measured after removal: `changed=0`.** A `wait_for` on port 8123 with a 30 s
delay went too; it existed only to gate the installer.

---

## 2026-08-28 — the container check's self-heal, and the exit code that was an accident

**Decided:** `check_container.sh` no longer attempts self-healing, **because**
the call it made had never once executed and repairing it would have been worse
than deleting it. `source stop_run_ha` was wrong four ways: a bare filename, and
`~/.scripts` is on no PATH anywhere; `source` rather than execute, which would
have imposed the sourced script's `set -euo pipefail` on the caller; no
argument, so the CLI it targets would print usage; and its `CONTAINER_NAME` is
hardcoded to `home-assistant`, so a dead `mosquitto` would have restarted Home
Assistant.

**Nothing is lost.** Every container runs `restart_policy: unless-stopped`,
which covers crashes, non-zero exits and reboots on its own — cloudflared has a
RestartCount of 28 from exactly that. The only uncovered case is a container a
human deliberately stopped, which `unless-stopped` declines to restart by
design. The function is renamed `notify_and_recheck`, which is what it does.

🐛 **Removing the dead line exposed that the check's non-zero exit had always
been an ACCIDENT.** `source` failed on every run, and that failure was the last
command's status, which became the script's. Delete the broken line and the
check would detect a dead container, post its own Slack message, and still
exit 0 — so `enhanced_monitoring_wrapper` would record success, with no state
tracking, no repeat suppression and no ALERT. The function now reports the
container's real state in its exit status.

📌 **The lesson worth keeping: a fix that makes an error message disappear can
remove the only signal that anything was wrong.** Verified by forcing it, not by
reading the diff — mosquitto stopped gives exit 1 and a real
`Sending alert (new or changed failure)` through the wrapper; restarted gives
exit 0.

---

## 2026-08-28 — the regression suite nobody ran

**Decided:** `tests/run_unit_tests.sh` exists and runs every `tests/unit/*_test.sh`,
**because** nothing ran them at all. `run_tests.sh` stages the repo onto a
disposable LXC and connects as root; the unit tests need no container, no network
and no privilege, so they were simply never invoked by anything.

Four of the eleven had been red since `6cfa1f0`, which added **five** variables
to `fleet_health_check.sh.j2` — `agent_opnsense_api_ip`, `_pubkey_pin`,
`_timeout`, `_creds_path` and `agent_opnsense_monitoring_check_name` — without
updating the tests that render it. Eleven days red, and the only reason anyone
noticed was running the suite by hand before adding to it.

📌 **Diff the template's variables against the test's, do not fix them one at a
time.** The first patch supplied `agent_opnsense_api_ip`, and the tests failed
again on the next missing name. Extracting every `{{ … }}` from the template and
subtracting what each test supplies found all five in one pass.

⚠️ **The runner's own failure paths are tested**, because a green runner is
exactly what was missing: a deliberately broken suite makes it exit 1, and a
filter matching nothing exits 1 rather than reporting success — otherwise a
renamed directory would read as "all passed".

**Not merged into `run_tests.sh`**, whose contract (root onto a disposable
container, forcing real faults) is deliberately narrow and stated at the top of
that file.

**Result: 11/11 for the first time in eleven days.** The four recovered suites
cover the agent sweep's snapshot dedup, SSH back-off directives, absence
thresholds and the curl→wget fallback — all read, not merely observed green.

---

## 2026-08-28 — a lamp being switched off is not a fault, and muting it was the wrong price

**Decided:** the HA entity check takes **per-pattern grace windows**, first match
wins, **because** one global 15-minute window cannot serve both a door sensor
that should never be silent and a floor lamp switched off every night. Before
this, such a device could only be allowlisted — which silences its real failures
too. `light.book_floor_lamp` was muted exactly that way earlier the same day,
after paging for 25 hours over ordinary use.

**Why a long window rather than an allowlist entry:** a device that is
legitimately absent part of the day can otherwise only be muted, which discards
its real failures too. A long window keeps both properties — quiet through
normal use, loud on real death.

⚠️ **Corrected the same day: the floor lamp never needed one.** It read
`unavailable` only because its wall switch had been used, cutting power to the
bulb; that switch is meant to stay on. With power restored it reports `on` like
its three siblings, so `unavailable` means broken and the ordinary 15-minute
window is correct. **The fix was the switch, not a threshold** — and a proposal
to stop watching the `light` domain altogether was withdrawn, because six of the
seven lights were already monitored correctly and excluding them would have
deleted working coverage to solve a one-device wiring problem.

The override mechanism stays (it is the right shape for a device that really is
periodically absent) but **the list is currently empty** — nothing needs one.
The television is allowlisted instead, honestly: a TV in standby drops its
network, so `unavailable` is its resting state every night and cannot be told
from a dead TV. Enabling the set's "network standby" option would make it report
`off` and monitorable, like the lights.

📌 **`off` vs `unavailable` is the discriminator worth remembering.** A Shelly
Duo on a *switched* circuit loses power and reports `unavailable`; its three
siblings read `off` because their circuits stay live. `off` means HA is talking
to the device; `unavailable` means it is gone. Three identical bulbs being fine
is what distinguished a real fault from a nightly pattern.

⚠️ **A long window that never fires is an allowlist entry with extra steps**, so
both halves are pinned by unit test: a 12 h switch-off stays silent while a door
sensor beside it still pages, and a week of absence pages anyway. A malformed
override is announced rather than silently falling back to the global default,
which would quietly tighten a window someone widened on purpose.

---

## 2026-08-25 — a controller with every device offline used to read as green

**Decided:** dockassist runs `check_ha_entities.sh` every 10 minutes, asking HA
what entities exist and judging all of them, **because** every check the fleet
had watched the *machinery* — host up, container running, service active, cron
fresh — and all of it was green for the five days the Eve door sensors were
gone. A `matter-server` with zero live subscriptions is byte-for-byte as chatty
as a healthy one.

**Why a grace window rather than instant alerting:** an HA restart flips every
entity through `unavailable` at once. A check that pages on every deploy gets
muted, and a muted check reproduces the exact silence this exists to break. 900 s
was chosen against restarts, not against the fault — the sensors were gone for
five days, so fifteen minutes of patience costs nothing. **Verified by restarting
Home Assistant with the cron live: exit 0 throughout, zero alerts, and the four
transient artefacts cleared themselves.**

**Why stateless domains are excused by DOMAIN, not by an allowlist:** the first
real run found **90 of 296 entities** in `unavailable`/`unknown` and none were
faults. 27 were buttons, which have no state until pressed. An allowlist of 27
button ids stops covering the 28th, and every new Shelly ships one — that is the
hardcoded-list failure the check exists to avoid, reintroduced through the back
door. `unavailable` on the same entity still pages, because that means the
device is gone; proven in both directions by unit test.

**Why the phone's Companion sensors are muted, stated as a cost rather than a
win:** ~20 of them go `unavailable` on any full-tunnel VPN, an already-accepted
edge case. The consequence is that this check can no longer tell a broken
Companion integration from Ignacio being on the VPN. Presence itself stays
covered by `check_presence_health.sh` (renamed from `check_tado_health.sh`
2026-08-26), which watches the trackers by name.

**Refused: seeding the allowlist from whatever was broken on deploy day.** An
auto-baseline would have silently accepted all 90, including anything genuinely
dead, and shipped a check that could never fire. The list is explicit and
versioned; the eleven stale automations in it are holding entries, and item 12
should delete them rather than mute them.

🐛 **A third category the design had not met:** a Shelly Plus Smoke mute button
read `unavailable` — *conditionally available*, since that button exists only
while the alarm sounds. Allowlisted by that one exact name; the detector's real
health rides on `binary_sensor…smoke` and `sensor…battery`, neither allowlisted.

🐛 **The allowlist was seeded from ONE sample, and that was not enough.** The
`--report` run happened while the TV was on. It went off at 23:40 the same night
and the check failed **54 consecutive runs** before anyone looked — a device a
human switches off is `unavailable` for exactly the reason it should be, every
night. Fixed by allowlisting `media_player.cobi_tv*` / `remote.cobi_tv*`, but
the transferable rule is: **a point-in-time baseline only sees what is asleep
right now.** Before trusting a fresh baseline of "normal", ask which devices are
off at this hour and would therefore not appear in it.

📌 **Acceptance was a forced failure, not a quiet check.** `matter-server`
stopped: ten entities dropped, detected in 45 s, alert on `#home-alerts` at exit
code 10 naming both door sensors; restarted: recovery notification, all clear.
That run also exposed [`TODO.md`](../TODO.md) item **20** — `check_container.sh`
has never been able to `source stop_run_ha`, because `~/.scripts` is on no PATH
at all (cron's *or* an interactive shell's). ⚠️ **The first version of this
entry called that "container auto-recovery is a no-op across the host", which
was wrong and is corrected here:** every container runs `restart_policy:
unless-stopped`, which covers crashes and reboots on its own — cloudflared has
restarted 28 times that way. The dead `source` only leaves uncovered a container
a human explicitly stopped, which `unless-stopped` declines to restart by
design. Lesson worth keeping: **a broken remediation is not automatically an
outage risk — check what else already covers the failure before ranking it.**

---

## 2026-08-23 — the door sensors were fine; their only road had moved

**Decided:** dockassist carries a second, **IPv6-only** `wlan0` leg onto VLAN 20
(`thread_wifi_link`, homeassistant role) **because** the Thread border router
now lives there and a Router Advertisement is the only way that route can
arrive — RAs are link-local, and no firewall rule substitutes for one.

Both Eve door sensors read `unavailable` from 2026-08-17 09:37 UTC to 08-22.
Nothing was wrong with them: they never left the Thread mesh and were still
advertising `_matter._tcp` throughout. At 09:33:44 UTC the HomePod acting as
border router moved from the IoT SSID (VLAN 100) to the no-VPN SSID
(VLAN 20) to fix AirPlay. dockassist is on VLAN 100, so its route to the mesh
prefix `fd24:839a:223a::/64` aged out. The first sensor went unavailable 3m36s
later. `ping6` from dockassist returned `Network is unreachable` — no route, not
a timeout.

**Why firewall rules were refused as the fix:** they permit packets a router
would otherwise forward, and none of the three prerequisites existed. dockassist
had no global IPv6 address, no route to the prefix, and **OPNsense carries no
IPv6 at all** — three IPv6 routes, every one of them loopback. There was no
IPv6 transit anywhere on this network to open up. Building it would have meant
ULA addressing on two interfaces, a static route via a *roaming Wi-Fi device's
link-local*, and RAs on VLAN 20 that would have re-disturbed the HomePod — the
device the move was made to protect.

**Why not move the HomePod back:** the move was deliberate and is staying.

⚠️ `ipv4.method=disabled` on that profile is **load-bearing, not tidiness**.
Docker sets `net.ipv4.ip_forward=1` on this host; the only thing stopping
dockassist from bridging the IoT VLAN to VLAN 20 is that `wlan0` holds no IPv4
address. IPv6 forwarding is 0 on every interface.

**The fix rested on a typo, so it now has a guard.** dockassist's Wi-Fi radio
survived only because `config.txt` carried `dt_overlay="disable-wifi"` — the
directive is `dtoverlay=`, unquoted, so it was inert. The role refuses to deploy
if it finds a *valid* disable-wifi overlay, and asserts the route actually
arrived rather than treating an associated radio as success.

---

**Also decided:** the Bluetooth overlay task writes to the config.txt the
firmware actually reads, resolved from where the boot partition is mounted,
**because** it had been writing to `/boot/config.txt` — a 112-byte placeholder
on Bookworm whose first line is `DO NOT EDIT THIS FILE`. `lineinfile` appended
happily and nothing ever read it. dockassist, hifipi and vinylstreamer each
carried `dtoverlay=disable-bt` in the placeholder while the radio stayed
enabled; Bluetooth was off on those hosts **only because the service task beside
it genuinely worked**. Two separate mechanisms, one of which had never done
anything, and the working one masked it.

Standing rules from this went to
[`ARCHITECTURE_DECISIONS.md`](../ARCHITECTURE_DECISIONS.md) — boot-config path,
why `backup: true` cannot be used on vfat, and that a wired host may still need
its Wi-Fi radio.

🐛 **The cleanup regexp was `[[:space:]]` on the first attempt.** `lineinfile`
uses Python regex, where that parses as a character class plus a *literal* `]`,
so it required a `]` at end of line and matched nothing — `found: 0`, reported
`ok`. Caught in `--check` before it reached a host. The same failure mode as the
bug being fixed: config that looks right and does nothing.

**Verified before touching four boot partitions:** all four Pis have `[all]` as
the last section, so an EOF append lands there; `disable-bt.dtbo` exists on each
and the on-device overlay README documents `disable-bt-pi5` as "See disable-bt",
covering cobra's Pi 5; no `config.txt` declares uart or gpio and every
serial-getty is disabled, so restoring UART0 on GPIO 14/15 is inert. Applied
host by host — +21 bytes and exactly one overlay line each, dated backups in
place, `changed=0` on the second run. **Not rebooted:** the overlay lands on each
host's next natural reboot, and Bluetooth was already off at the service layer.

**`disable_bluetooth` is now true for the homeassistant group.** Nothing there
uses BLE: HA's adapter discovery is dismissed (`source: "ignore"`),
`bluetooth.service` is disabled and inactive, `hci0` is DOWN, and
`matter-server` runs without `--bluetooth-adapter`. Companion-app commissioning
uses the phone's radio and is unaffected.

**Left open:** nothing alerted for five days — see [`TODO.md`](../TODO.md) item
15. The mesh still has a single border router — item 16.

---

## 2026-08-19 — exclude the benign line, never the pattern (cwwk's VFIO false positive)

**Decided:** `check_kernel_errors.sh` filters known-benign lines out of the
matches **after** the pattern matches, rather than narrowing the pattern,
**because** the obvious fix — dropping `VFIO` from `WARNING_PATTERNS` — also
makes the check permanently incapable of reporting a passthrough fault. Both
fixes make the alert stop. Only one of them still has a check afterwards.

The benign form, anchored at end-of-line:
`vfio-pci [0-9a-fA-F:.]+: reset(ting| done)[[:space:]]*$`. The anchor is the
whole safety margin — a reset that *fails* carries extra text (`Failed to reset
device`, `resetting failed`, `reset done, device unusable`) and still alerts.

**Why it paged at all:** every OPNsense VM start/stop resets its two passthrough
NICs. The check dedups by md5 of the matched line, but `dmesg -T` renders a
fresh wall-clock timestamp on each, so every restart produced 24 never-before-
seen signatures. The dedup was working exactly as written and could never have
caught these.

**Proven by forcing the failure on cwwk**, against real `dmesg` and a copy of
the real state file, through the *deployed* script as the cron user:

| injected line | exit |
|---|---|
| *(none — the 24 reset lines that paged that evening)* | `0` OK |
| `vfio-pci 0000:03:00.0: Failed to reset device` | `1` WARNING |
| `vfio-pci 0000:01:00.0: resetting failed` | `1` WARNING |
| `vfio-pci 0000:03:00.0: DMAR: DMA fault addr 0xdeadbeef` | `1` WARNING |
| `vfio-pci 0000:01:00.0: reset done` *(benign)* | `0` OK |

A laptop unit test pins the same thing without a host or a container —
`tests/unit/kernel_vfio_benign_test.sh`, 8 assertions. It was confirmed to
**fail against the pre-fix script** before being trusted; a green test that was
never seen red proves nothing.

🔴 **The fixture lied and the host told the truth.** The hand-built laptop
fixture held only reset lines, so it went green while cwwk still exited `1`:
real `dmesg` also carries `VFIO - User Level meta-driver version: 0.3` and
`vfio-pci <BDF>: enabling device (0002 -> 0003)`. **Left unexcluded on
purpose** — reasoning that they are logged once per module load, so their
timestamps are stable, their md5s dedup correctly, and they were already in
cwwk's state file; they would cost one alert per *host* reboot, not per VM
restart, which is the thing that was actually wrong.

⚠️ **That reasoning was wrong and this was reopened on 2026-08-31** — see the
entry at the top of this file. `dmesg -T` timestamps are rendered at read time
from a buffer a reboot empties, so the boot lines do **not** dedup across
reboots, and the 2026-08-30 reboot paged. Both are now excluded.

---

## 2026-08-19 — hifipi's amixer alerts: the fix sat in git for four months

**Closed** (fix hand-applied 2026-08-02, verified 2026-08-19: zero `Script
Failed on hifipi` in `#home-alerts` across two Sunday cycles). The March commit
fixing the alert was never deployed, **because** the audio scripts are deployed
only by the `audio_playback` role — `deploy_monitoring.yml` syncs
`scripts/common/` alone, while its name (and `CLAUDE.md`) promise more. That
drift class is now TODO item 10's checksum blank; the wording fix is item 12.

**It was three bugs, not one**, and redeploying the old fix alone would not have
silenced it: the control names (`Master`/`Digital` never existed on this DAC),
an unprivileged `alsactl store` under `set -e`, and a volume parse whose guard
could never pass — `grep 'Left:|Mono:'` matches the empty `Mono:` header too, so
`VOLUME` was multi-line and the threshold **never evaluated**. A DAC at 10%
would have been reported "configured correctly".

📌 **On any `Script Failed` alert, diff the deployed script against the repo
before diagnosing its logic.** A Tier 2 investigation correctly root-caused this
and still recommended writing a patch that had existed for four months.

---

## 2026-08-18 — the job that stops a service announces it (cobra's 04:00 alert)

**Decided:** the job doing the stopping declares a **maintenance window** —
`~/.maintenance/<unit>`, holding an expiry epoch and a reason — and
`system_health_check.sh` downgrades that one unit from ❌ to ⚠️ while the window
is open, **because** the alternative on the table was making the check tolerate
a flap, which weakens it for every service on all seven hosts to fix one known
22-second stop on one.

**The distinction that makes it safe:** a retry *guesses* that a down service is
coming back, so it must stay small enough not to hide an outage. A window is a
*statement* by the job that stopped it, so it can be believed outright — but only
for the unit it names, and only until it expires.

**Decided:** an **expired** window is a louder error than no window at all
(`EXPIRED maintenance window, the job that stopped it never restarted it`),
**because** the failure it exposes — a backup killed between `stop` and `start`,
leaving the service down indefinitely — is worse than the false positive the
window exists to remove. Same reason a corrupt or truncated marker reads as *no
window*: this fails closed.

🔴 **Suppression is not silence.** A suppressed service still prints a line
naming the job that opened the window; what it stops costing is the exit status.

**Also decided:** `check_plex.sh` honours the same window. It runs `0 * * * *`
and the backup runs `0 4 */7 * *` — the same minute, with no ordering between
them — so its self-heal could `systemctl restart` Plex *while the backup was
copying `Preferences.xml`*, putting a torn config in the archive and hiding it
behind the backup's own `start`. Unfired, but only by luck of scheduling.

**Proven by forcing all three states on cobra**, not by reasoning about them:
during a real `backup_plex_config` run the check printed ⚠️ and exited **0**;
with Plex genuinely stopped and no marker it printed ❌ `(4 checks over 36s)` and
exited **1**; with an expired marker it printed the EXPIRED error and exited
**1**. 15 laptop assertions (6 of which fail against `main`) and a container case
green on CT 199 under `dash`.

✅ **Production-confirmed 2026-08-22**, the next `*/7` run: window announced under
cron at 04:00:02 (which is what proves `$HOME` resolves there — the one thing a
forced run cannot show), Plex back at 04:00:23, backup exit 0, marker cleaned up,
`#home-alerts` silent. ⚠️ **But the suppression did not fire that morning**: the
`2-59/15` check sampled at 04:02, after Plex was back, and `check_plex.sh` read
`active` at 04:00:02 by a fraction of a second. The offset carried it; the window
was insurance. It stays proven only by the forced runs — which is the point, since
the offset stops covering a stop that takes longer than two minutes.

🐛 **`scripts/services/media/backup_plex.sh` was deleted**: a byte-identical,
**unreferenced** copy of the file the role actually deploys
(`roles/services/plex/files/backup_plex_config`) — and every comment in the repo
cited the copy that does not run. Editing it would have changed nothing on cobra.

📌 **The mitigations from 2026-08-15 (D6) are kept, not replaced**: the 36 s
re-check and the `2-59/15` cron offset still cover *unannounced* restarts, which
is hifipi's weekly audio-stack case. This adds the announced kind.

---

## 2026-08-18 — the test rig is green, and no longer root-blind

**Decided:** cases **ARRANGE as root and EXERCISE as `$INFRA_USER`** (the
`run_uut_as` split), **because** the two halves answer different questions and
neither survives being collapsed into the other. Arranging a fault means
stopping cron, filling disks, moving root-owned logs and chowning directories —
running the suite unprivileged end to end was tried and gives **8 of 10
`PRECONDITION FAILED`**, proving nothing about anything. But the fleet's checks
run as the infrastructure user under cron, so a root-only exercise cannot see a
permission fault at all.

**Refused, do not reopen:** G1's prescription that "the runner connects as the
infrastructure user and cases escalate with `sudo`". It is backwards, it was
measured to be backwards, and the runner stays connecting as root.

**The split is demonstrated, not asserted.** `chmod 0600
/etc/apt/apt.conf.d/20auto-upgrades` is a fault only an unprivileged reader
sees. Same case file, same fault: `--case health_baseline` FAILS as `choco` and
PASSES with `INFRA_USER=root`. The A/B is in `tests/README.md` as the way to
re-verify — **if both legs ever agree, the exercise step stopped dropping
privilege and the suite is blind again.**

**Decided:** `health_no_internet` exercises **both** branches of `check_network`
— `/etc/hosts` for the name (→ *resolver problem*) plus a **`/32` blackhole
route** for the probe IP (→ *genuine outage*) — **because** the case had gone
stale: it blocked only the name and asserted `Internet: unreachable`, while the
script had been rewritten to probe a name *and* an IP literal precisely to tell
those two faults apart. **The check was right and the test was wrong**, which is
the dangerous direction: the reflex is to "fix" the script until the old
assertion passes, undoing a real improvement. A `/32` blackhole is used rather
than dropping the default route because the latter severs the SSH session, so
`cleanup` never runs and the container is left unreachable.

**Decided:** the case **parses `NETWORK_PROBE_IP`/`_NAME` out of the script**
and asserts what the parse *yielded*, **because** a case that hardcodes
`1.1.1.1` keeps testing `1.1.1.1` long after the script has moved on, and
reports green while covering nothing.

**Decided:** the runner refreshes the rig's upgrade timestamp during staging by
running `unattended-upgrade --dry-run` for real (0.7 s), **because** CT 199 is
`onboot 0` and sits stopped between sessions — at 7 days `check_auto_upgrades`
fails and hands a non-zero exit to every case on the box. Chosen over appending
a line to the log so the entry comes through the same code path the fleet uses.

**Decided:** `health_disk_full`'s cleanup waits (bounded 30 s) for the space to
come back, **because** rpool frees asynchronously and the *next* case was still
reading `Disk /: 89%` and satisfying `assert_exit_nonzero` on that leftover.

📌 **Asserting on exit status alone lets a case pass for the wrong reason.** It
happened twice in this work — once on a stale-upgrade failure, once on leftover
ballast — and both times only a wording assertion caught it. Every case now
asserts on wording as well as status.

**Still open:** `wrapper_state_collision` has never dropped privilege — see
[`TODO.md`](../TODO.md) item 3.

## 2026-08-17 — opnsense is read over its API, not a shell (L-H)

**Decided:** the fleet sweep checks the firewall over HTTPS with a scoped,
API-only credential — no SSH key, no shell — **because** OPNsense rewrites every
non-admin account's shell to `nologin` whenever it regenerates users from
`config.xml` (`auth.inc:351`). A shell there is on loan and was reclaimed twice.
Nothing in the sweep SSH-authenticates at the gateway any more, which retires the
CrowdSec self-ban that turned monitoring into the 2026-08-03 outage.

**Refused, do not reopen:** `pw usermod` (bypasses an intentional control and
self-reverts) and dropping opnsense from the sweep (its own crons only report
while it is well).

**Decided:** pin the firewall's **public key**, not its certificate, **because**
OPNsense does not auto-renew its self-signed cert (core#4567, #7385), so
`--cacert` guaranteed a page on an expiry date — an alert about a calendar.
Certificate lifecycle is the software's problem; **a cert-expiry pre-warning was
proposed and declined.**

**Decided:** monitoring freshness comes from healthchecks.io via a **new
unconditional heartbeat**, **because** FreeBSD's cron logs no job executions
(unlike Debian's, which syslogs every `CMD`), and **because** the two pre-existing
opnsense heartbeats ping only when the thing they check is healthy — reusing them
would report the firewall's monitoring dead every time the WAN blipped.

Standing rules produced → `ARCHITECTURE_DECISIONS.md` § *opnsense is read over the
API*. Operator reference → `docs/OPNSENSE_API.md`.

---

## 2026-08-16 — cwwk KSM codified, and the power tuner stopped lying (L-E)

**Decided:** `ksmtuned` is **masked** via `proxmox_disable_ksm`, not merely
disabled, **because** the unit ships `UnitFilePreset=enabled` — `disabled` is
precisely the state a rebuild undoes. KSM costs ~3 °C here and pays nothing back
on this guest topology (one large VM plus LXCs already sharing the host kernel).

**Decided:** `cwwk_power_tuning.sh` reads every write back and exits non-zero on
mismatch, logging `before -> after` rather than a final value, **because** both
writes were `|| true` behind silent `[ -w ]` guards — the unit reported success
whether or not it applied anything, and logged nothing on any boot. A correct
final reading does not prove the script caused it.

📌 **A oneshot that exits 0 and prints nothing is indistinguishable from one that
did nothing.**

---

## 2026-08-16 — vinylstreamer's plug automates a manual power-cycle (L-I W2)

**Decided:** Home Assistant power-cycles the Shelly at `10.30.100.217` when
vinylstreamer goes offline, **because** Ignacio had been doing it by hand (twice
in the preceding week) and the host had **no external detection of any kind**.
Both device hazards were verified closed first (`initial_state: on`,
`autorecover_voltage_errors: true`) so the plug cannot latch off and strand it.

**Decided:** every branch pages `#home-alerts` **even when it refuses to act**,
**because** the plug is remediation, not a fix — silence would let a worsening
fault hide behind successful cycles.

⚠️ **W2's forced acceptance tests contaminate the 7-day cycle counter** — exclude
2026-08-16 when judging whether the fault is recurring.

---

## 2026-08-16 — independent monitoring tails, one diagnosed wrong (L-D)

**Decided:** logrotate configs carry `su`, deployed to 7 hosts, **because**
without it rotation fails silently on directories the rotating user does not own.

**Decided:** cobra's `nmbd` is masked, **because** it lost a boot race and its
ordering is already correct — an intermittent race that will recur, not a
misconfiguration.

📌 **Two traps this produced, both reusable:** `--tags <role>` is **not** a scoped
change when the role has never converged on that host — it is a full first-time
apply. And **a code fix does not repair the state the bug already wrote.**

---

## 2026-08-14 — the alert flood is dead, and a dead host reads differently (L-F)

**Decided:** the wrapper suppresses repeat alerts on a doubling interval (1h base
→ 24h cap) rather than re-alerting hourly, **because** ~92% of `#home-logging`
traffic was one fault repeating.

🔴 **The point was never quieter alerts — a lobotomised check is also quiet.**

**Decided:** a host that authenticates but cannot run anything gets its own
branch (`UP but no usable shell`), **because** it previously collapsed into
`UNREACHABLE`, which is what a powered-off box looks like. The detection worked;
the wording hid what it found.

⚠️ **Not covered, and still not:** a *flapping* fault. Deferred as "fix forward if
annoying".

---

## 2026-08-13 — agent-lxc Tier 2 live, and the sweep had never run (L-C)

**Decided:** Tier 2 investigation runs on OpenCode + Sonnet, gated on a snapshot
being newer than the last investigated, **because** an unguarded trigger
re-investigated and re-billed a persistent fault every hour.

🔴 **The container executed zero jobs for its first 12 days** — every cron died on
a redirect into a directory that did not exist, before the script was reached.
Silent because agent-lxc was the only host without a healthchecks.io check.

📌 **"Merged" is not a state this fleet has; `changed=0` on a second run is.**
CT 103 ran a 3-week-old build of already-merged code for ten days, including the
fix for an outage it had itself caused.

---

## 2026-08-13 — the monitoring sprint, live on all 8 hosts (L-B)

**Decided:** `critical_services` is declared per host, **because** every host fell
back to the built-in `ssh cron fail2ban` — so what each host *exists to do* was
covered only by the generic `systemctl --failed` sweep, which sees a crashed unit
and is blind to one stopped cleanly. Proven by a real fault: cobra's `nmbd` had
been dead four days and nothing had said so.

🐛 **A bug this surfaced that would have shipped silently:**
`origin=Ubiquiti Networks, Inc.` **cannot work** — unattended-upgrades splits
patterns on commas into `key=value` pairs, so an Origin containing one *raises*
rather than failing to match. Use `site=`.

🐛 **`'CHANGED' in 'UNCHANGED'` is `True`.** A substring test restarted Home
Assistant on every `services.yml` run since 2026-07-12; `no_log: true` hid the
stdout that would have shown it. Compare whole values, not substrings.

🔴 **The §1a FreeBSD fixes are dormant code running on no production host** —
`deploy_monitoring.yml` excludes `system_health_check.sh` from FreeBSD. Do not
carry them forward as verified.

---

## 2026-08-13 — `system_health_check.sh` could never fail, and now can

Every check printed its ❌ and the script exited 0 — on every host, every 15
minutes, since forever, because nothing aggregated the counts and a script's
status is that of its last `echo`. **Decided:** per-check counted returns summed
into a real `exit`, **because** the wrapper keys purely on exit status — a check
that reports only by printing contributes nothing (a rule that already had to be
re-applied to `check_link_speed`).

**Six false-failure classes were fixed before arming it**, each one a page-every-
15-minutes the moment aggregation landed: the FreeBSD load parse returned the
clock (`12:27AM` → "200%"); containers divided the *host's* load by their own
core count (replaced with cgroup CPU pressure, calibrated at 80% `avg300`); ZFS
ARC counted as used memory (cwwk read 82% for a true 52%); the upgrade log was
unreadable to a user bootstrap never put in `adm`; service names were hardcoded
per OS (now inventory-driven with an rc-script probe); and a pending-reboot check
was added so `auto_reboot: false` on cwwk trades an unannounced reboot for a
7-day-graded to-do, not an unnoticed unpatched kernel.

📌 **"The error stopped" is satisfied by both a fix and a lobotomy.** Every one
of these was closed by forcing the failure and watching it fire, in both
directions — a test that does not fail against `main` proves nothing.

---

## 2026-08-13 — three cron jobs, one state file (the #home-logging flood)

dockassist's three `check_container.sh` jobs shared one wrapper state file —
the state name derives from the script *basename* — so three same-second writers
trampled it, the daily-heartbeat dedup never persisted, and 92% of
`#home-logging` was three duplicated messages. **Decided:** distinct
`--monitoring-name` per job, documented as **required** whenever two jobs on a
host wrap the same script, **because** the flag read as cosmetic — an API
footgun, not operator error (adoption was 0–5 jobs per host).

Wrapper hardened in the same change: `mktemp` for the state temp file (disarms
the race fleet-wide), unrecognised `--heartbeat-interval` values are **fatal**
instead of silently disabling heartbeats, and `never` is first-class. An absent
flag still defaults to `daily` — silence is the one signal monitoring must never
default to.

---

## Smaller closed items

- **2026-08-19 — cwwk memory trim considered and dropped.** OPNsense's VM is
  allocated 12 GB and uses ~3.5 GB, but the host has headroom and shrinking it
  costs a firewall restart (= internet outage). Revisit only if cwwk actually
  runs short; do not re-propose on the numbers alone.
- **2026-08-13 — unifi-lxc `--tags ssh` applied.** It was the one host the SSH
  role had not reached since Oct 2025 — the only sshd_config diff and root-shell
  outlier in the fleet.
- **2026-08-10 — cabinet fan fitted** (Noctua NF-A12x25 G2, mechanical switch
  that survives a power cut — the old fan's soft-latch reset-to-off caused both
  outages). Door position dominates: 94 °C closed vs 81 °C resting on the same
  load. Vent sizing continues as TODO item 8; runaway-process detection the fan
  silenced is item 9.
- **2026-08-06 — Tier 1 backs off a host that rejects auth**, reporting the
  finding without connecting, because retrying hourly is what got the observer
  CrowdSec-banned by its own gateway. Scoped to rejected auth only — a host that
  is merely down keeps being probed.
- **2026-08-01 — Zyxel XGS1250-12 telemetry: none obtainable.** No SNMP
  (confirmed by Zyxel staff), no temperature readout; the overheat downshift
  applies only to 10G *copper* ports and this link is an SFP+ DAC. An external
  probe (TODO item 13) is the only route — do not re-derive.
- **2026-07-13 — bathroom Tado radiator flapping.** Batteries swapped + `for:`
  20 min + a global 6h cooldown, validated against 10 days of recorder history
  (healthy devices' blips are all <5 min; only the degraded head produced
  10–102 min outages). Per-entity timers rejected as overengineered for
  monitoring-only entities.
- **2026-08-16 — dockassist `services.yml` idempotency (D5).** The recorded
  one-character fix was **inert**; the real cause was two writers on one
  container (`docker run` stores binds verbatim, `community.docker` normalises to
  `:rw`). `force_source` dropped from all three pulls.
- **2026-08-06 — opnsense `scripts_dir` made consistent.** Written, deployed
  later; the migration is why opnsense's `.scripts` directory reports `changed`
  where other hosts report `ok`.
- **2026-08-06 — cwwk auto-reboot decided and written.** `Automatic-Reboot
  "False"`, 3 config lines not 4; a fourth means deleted tasks returned.
- **2026-07-26 — SMART disk-health monitoring** deployed.
- **2026-07-20 — `detect_audio.log` logrotate fix.** A held-open fd across daily
  rotation left the log empty for days. Fixed by dropping the file entirely
  (journal-only). General warning for any long-lived process with a custom file
  logger.
- **2026-07-15 — Wyze → Shelly Duo G3 migration.** Entities renamed in the
  registry to the old semantic IDs; `wyzeapi` removed.
- **2026-07-18 — amp power + input switching**, live-verified end to end.
  Architecture: `docs/AUDIO_AUTOMATION.md`.
- **2026-07-12 — MQTT broker on dockassist.** Mosquitto authenticated, HA wired
  via injected config entry. The passwd file must be uid-1883-owned or the broker
  crash-loops.
- **2026-07-01 — Shelly gas false-alert fix.** CoIoT unicast + recovery debounce;
  validated 0 flaps/day against a ~1–3/day baseline.
