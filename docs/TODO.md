# Infrastructure TODO — open work

**The reasoning behind open work.** The queue itself is Linear team `PER`; an
issue points at its section here, and the order below is not authoritative.

Updated: 2026-09-26

| Where a thing lives | |
|---|---|
| **Open work** | this file |
| **Finished work + why** | [`archive/DONE.md`](archive/DONE.md) |
| **How the system is built** | [`ARCHITECTURE_DECISIONS.md`](ARCHITECTURE_DECISIONS.md) |
| **What the test environment is for** | [`TESTING_GOALS.md`](TESTING_GOALS.md) — read before any test work |
| **Full narrative of past sessions** | git history |
| **The queue** | Linear team `PER` — this file is the reasoning an issue points at, not a second queue |

> 📌 The *Infra — What to work on* dashboard artifact is retired. Do not update it;
> Linear replaced it.

> **Network layer:** see [NETWORK.md](NETWORK.md) — topology, VLANs, VPN and DNS,
> plus thirteen findings from deriving it on 2026-08-07/08 that are not yet
> tracked here.
>
> **Documentation consolidation** was briefed in
> `~/.claude/plans/doc-consolidation-brief.md` (2026-08-08). ⚠️ **Partly executed
> and partly superseded** by the 2026-08-17 cleanup, which drained this file
> instead of consolidating into it. Re-read before acting: one of its moves —
> folding `NETWORK.md` findings *into* this file — now cuts against keeping it
> small.

---

> **Completed work has moved to [`archive/DONE.md`](archive/DONE.md).**
> That file is distilled to decisions and their reasons, not a diary — the full
> narrative (measurements, forced-failure tables, retractions) is in git history.
> This file is now open work only.

## 🎯 What to work on next

Ordered by *is it hurting now* → *is it a known risk* → *is it an improvement*.
Each item says what it is, what state it is in, and what the next action is.

**Anything already investigated carries a ready-to-paste prompt.** Anything that
needs a decision from Ignacio says so and does not pretend to be actionable.

🔴 **Open work only — a closed item is *removed* from this section, not struck
through in place.** This section and the dashboard that renders it are a
pick-up queue: everything on them is something to start. A "✅ done" entry left
here is something to read past, every time, forever. The write-up goes to
[`archive/DONE.md`](archive/DONE.md) and the narrative stays in git.

📌 **The queue order is explicit.** Items appear below in *address* order
(numbers never move), but the order to work them is this, and the dashboard
renders it:

> **№1** 36 + 37 *(deployed 13 Sep — waiting on a real alert / a real lockout)* →
> **№2** 42 *(entrance door alert disabled 19 Sep, needs physical inspection)* →
> **№3** 38 *(small follow-ups: MQTT timeout, 403 detection)* →
> **№4** 2 → **№5** 4 (plex) → **№6** 9 → **№7** 3a/3b/3c → **№8** 39 →
> **№9** 5 → **№10** 19 → **№11** 12 → **№12** 10 → **№13** 11 → **№14** 6 →
> **№15** 7 → **№16** 34 *(small; restores `changed=0` as a signal for the docker role)* →
> **№17–19** 8/13/14 · **№20** 32 *(git-history rewrite —
> decision only, default is no)* · **№21** 26 *(one UI toggle, global — his call)*
> *(decision-gated — 32 needs his call on a public
> force-push, the rest need him at the cabinet; not ranked)*

✅ **16 closed on 2026-09-23** — write-up in [archive/DONE.md](archive/DONE.md#2026-09-23--the-thread-spof-stays-the-outage-it-would-guard-against-is-already-fixed-twice-over-per-23); accept-and-monitor, no purchase. Both causes of the original 5-day outage (route aging out, silent alerting) were already fixed by items 15 and the 2026-08-23 IPv6 route fix.

✅ **41 closed on 2026-09-14** — write-up in [archive/DONE.md](archive/DONE.md#2026-09-14--two-dead-mullvad-relays-found-three-days-late-and-a-peer-swap-that-looked-broken); the peer-replacement runbook is in [NETWORK.md](NETWORK.md#replacing-a-mullvad-peer-runbook).

✅ **40 closed on 2026-09-16** — write-up in [archive/DONE.md](archive/DONE.md#2026-09-16--an-alert-that-fails-to-send-is-never-retried-per-60); fixed, tested (19/19 unit cases), deployed to all 8 hosts, `changed=0` on the second run.

🔀 **18, 1c, 1d and 35 were all one cron line's worth of work, worked as one
branch on 2026-09-05, and are now all closed.** 1c and 22 closed 2026-09-05;
18 and 1d closed 2026-09-19 (the readings both came back unambiguous — zero
NIC stalls in 14.6 days, ratio floor set from real data); 35 closed
2026-09-20 (thermal thresholds shipped, forced-tested on the real host).
Numbers remain valid addresses. Write-ups: [archive/DONE.md](archive/DONE.md#2026-09-05--the-speedtest-that-measured-too-much-and-three-false-greens) (1c/22) and
[archive/DONE.md](archive/DONE.md#2026-09-19--three-overdue-readings-land-nic-stalls-gone-a-ratio-floor-set-and-cwwks-thermal-alert-learns-the-difference) (18/1d/35).

**31 was discarded on 2026-09-02, not deferred.** Ignacio tested it: the IoT
devices cannot associate with PMF enabled, so raising it is not a fix that was
skipped — it is a fix that **breaks the segment it was meant to protect**. The
finding stands as an *accepted trade-off* in
[ARCHITECTURE_DECISIONS.md](ARCHITECTURE_DECISIONS.md#wireless--pmf-on-the-iot-ssid-is-refused-not-pending)
so no future session re-proposes it. 🔴 **Do not re-open it on the reasoning that
"the weakness is still there" — that reasoning is correct and was already
weighed.**

**Three items left the queue on 2026-09-02** — 27, 29 and 30 were each
diagnosed to a real mechanism and each ended with nothing worth building, so
they are now
[parked findings](archive/DONE.md#2026-09-02--three-findings-that-were-never-tasks-parked-with-their-reopen-conditions)
with their exclusions and a reopen condition, not queue entries. 🔴 **None of
them can be settled by measuring how often they fail** — the action is the same
at any rate, which is what made them notes rather than tasks. Reopen on a
complaint, not on a number.

**32 sits near the bottom on purpose.** It descends from item 24, closed
2026-08-30, whose disclosure policy is now
[a standing rule](ARCHITECTURE_DECISIONS.md#disclosure-tiering--what-goes-in-a-public-repo).
A git-history rewrite is a decision whose default is *no* — tidiness, not
containment. 🔴 **Its sibling, item 31, was the fix rather than the tidying,
and it is now refused** (see above): redaction is the entire available
mitigation, so nothing here is waiting on a better option.

📌 **Every item carries a paste-ready prompt** — including blocked ones, which
carry *fill-in* prompts that take the physical measurement or decision as
input. An item without a prompt is an item that has not been triaged properly.

### 🔴 P1 — actively hurting

**42. Entrance door sensor flapping false "opened while away" alerts — alert disabled, needs physical inspection**
`binary_sensor.eve_door_20ebn9901_door_2` ("Entrance Door") intermittently reports a real `on` (open) state — not a connectivity dropout, not low battery (100%), not stale firmware (3.2.1, current) — while the door has not actually been opened. Confirmed live 2026-09-19: 14 alerts in ~6 hours, each `on` state held minutes not seconds (one full cycle observed: on ~4.5 min, then off), and it flipped again live during the investigation itself. Escalating: roughly 1/day in August, 3 in one evening on 09-17, 14 in six hours on 09-19.

Its sibling sensor (`binary_sensor.eve_door_20ebn9901_door`, "Balcony Door") shows a *different* failure mode in the entity-health log — `unavailable` → `recovered` cycles, a connectivity dropout. Entrance never appears there; it stays connected throughout, so this is a bad reading, not a lost link.

**Leading hypothesis, not confirmed:** mechanical — a drifted magnet/sensor alignment, or the door not latching fully and flexing (draft/wind) close enough to the reed switch's trip distance to register minutes-long "open" reads. Needs eyes on site; not diagnosable further from read-only tooling.

✅ **2026-09-19: entrance trigger disabled** in `eve_door_open_while_away` (`ansible/roles/services/homeassistant/templates/automations.yaml.j2`) — the balcony trigger is untouched and still alerts. This is a deliberate, temporary blind spot on the house's most important security sensor, accepted because the alert had become pure noise. 🔴 **Re-enable only after the physical sensor/magnet has been checked** — do not re-enable blind, and do not substitute a debounce for the physical check: the observed `on` cycles already run 3–4+ minutes, longer than a sane debounce window would filter anyway.

*State:* alert disabled, root cause not yet fixed. *Effort:* physical inspection, small; re-enabling is a one-line template revert. *Needs:* someone on site at the entrance door.

```
Physically inspect the Entrance Door Eve sensor (binary_sensor.eve_door_20ebn9901_door_2)
and its magnet. Read docs/TODO.md item 42 first — the alert trigger is deliberately
disabled in ansible/roles/services/homeassistant/templates/automations.yaml.j2
(eve_door_open_while_away); balcony is untouched. Battery (100%) and firmware (3.2.1,
current) are already ruled out, and it is not a connectivity/unavailable issue.

Check: does the door latch fully? Is the sensor/magnet gap tight and aligned? Any
visible movement/flex when the door is closed (draft, wind, a loose hinge)?

If a physical fix is made, verify it holds: watch the entity in HA for a few hours
(no unexpected `on` transitions), then restore the second trigger (entity_id
binary_sensor.eve_door_20ebn9901_door_2, to: "on", id: entrance) and the
trigger.id-based message in the automation, and deploy with
services.yml --limit dockassist --tags config.
```

📌 **Numbering is deliberately not compacted.** Several prompts below and in
git history say "read docs/TODO.md item 2" or "item 3a"; renumbering on every
close would silently repoint them. Numbers are addresses, not ranks — the
headings say what is urgent.

### 🟠 P2 — known risk, not currently biting

**36. Tier 2 billed one fault six times overnight — DEPLOYED, waiting on a real alert**
On the night of 2026-09-12/13 agent-lxc ran **6 paid investigations ($1.57)**,
all about one fault (raspotify on hifipi, item 38). The Slack watch keyed on
message text, and one fault produced three texts; anomaly mode keyed on the whole
finding set, so another host joining and leaving re-billed it; and the two modes
shared no state.

✅ **Deployed 2026-09-13** (`44cf961`, pushed): incidents keyed by **host +
subject** (`hifipi.raspotify` — the check script, failed unit, or reachability
the alert names), shared by both modes. A second, unrelated fault on the same host
is still investigated, and its prompt lists the host's open incidents. 26 h quiet
window (longer than the wrapper's 24 h maximum reminder gap), 7-day refresh,
**$2/day cap**. Replay of the night: **2 runs, ≤ $0.61**. 45 dedup checks and the
unit suite 16/16 pass; the host-only first version failed the forced
unrelated-fault cases. On the box: the script parses under dash, all three Tier 2
crons are present, the retired Slack markers are gone, and the first run created
`incidents/`.

⚠️ **Not verified:** behaviour on a real alert — item 38 was fixed the same
evening, so no live alert was left to test it. Also unverified: mawk's `match()`;
timed-out runs log $0, so the cap undercounts; a fault whose checks name it
differently still costs a second run.

*State:* deployed; **waiting on the next real alert**. *Needs:* nothing to build.

```
Verify the Tier 2 host+subject dedup against a real alert. Read docs/TODO.md
item 36 — it is DEPLOYED; do not redesign or redeploy it.

  ssh 10.30.40.203 'tail -n 40 ~/.logs/investigate.log; ls -la ~/.agent/incidents ~/.agent'

For the first alert since 2026-09-13 21:00: exactly ONE paid run per
host.subject, later reminders logged as covered (no new run), and today's spend
ledger written. If two checks described one fault under different subjects and
it cost two runs, report both subject strings — that is the one known gap.
Then move item 36 to docs/archive/DONE.md.
```

**37. vinylstreamer's wifi recovery undid its own fix — DEPLOYED, waiting on a lockout**
On 2026-09-13 wlan0 dropped at 06:31 and stayed off until 09:00; the host itself
stayed up. Layer 3 of `wifi_reconnect.sh` (driver reload) recovered the link on
every run, and 8 s later the script's unconditional `nmcli con up` tore it down.
The journal shows that self-teardown **26× on 13 Sep and 4× on 9 Sep**, and 9 Sep
ended in HA's plug power-cycle at 18:58 — the host's current boot. What should
have alerted did not: the script's own alert went out over the dead wifi (item
40), and the brief reconnects kept resetting the plug watchdog's continuous
15-minute timer (item 39).

✅ **Deployed 2026-09-13** (`ab766fa`, pushed): layers 2 and 3 wait for
NetworkManager's own activation and force `con up` only if it does not arrive;
the recovery message reports the real outage length. The stub test passes under
sh and dash, and the old script fails it with that night's sequence. On the host:
the healthy path was run by hand (`✅ wlan0 healthy`), the script and cron are in
place, and `update_keys` still returns keys. **The script never reboots
anything** — only HA's plug does (15 min offline, at most once an hour) — so the
fix should mean fewer power cycles, not more.

🔴 **Never force a wifi drop remotely to test it:** wlan0 is the only link. The
ladder's host-level proof is the next natural lockout. The AP rejecting
association (`ASSOC-REJECT`) is still the open root cause underneath.

*State:* deployed; **waiting on the next natural lockout**. *Needs:* nothing to build.

```
Read the first vinylstreamer wifi lockout since 2026-09-13. Read docs/TODO.md
item 37 — the fix is DEPLOYED; do not redesign the ladder or force an outage.

  ssh vinylstreamer-agent "sudo journalctl --no-pager -S '<lockout start>' -U '<+1h>' | grep -E 'wifi_reconnect|new activation request|Activation: successful|modprobe brcmfmac'"

Report which layer recovered it; whether any "disconnecting for new activation
request" still follows a successful activation within 15 s (it must not); the
recovery message in #home-logging (does it give the true outage length?); and
whether HA's plug power-cycled. Then move item 37 to docs/archive/DONE.md,
keeping 39 open (40 closed 2026-09-16 — see archive/DONE.md).
```

**2. cobra's Samba is hand-built and the role cannot converge as written**
`--tags samba` has **never run on cobra**. Its live `smb.conf` is stock Debian
with a hand-added `[Plex_Storage]` block, and `group_vars/media.yml` declares
`owner`/`group`/`mode`/`recurse` for `/mnt/almacenNTFS` — an **exFAT** mount that
can store none of them. Running it today rewrites the config and does
`chmod -R 0777` on the media library.

✅ **DECIDED 2026-08-18 (Ignacio): nothing is managed by hand.** So the fix is to
make the role able to converge, not to leave cobra out of it:

1. **Bring the `[Plex_Storage]` block into the role's template**, parameterised
   from inventory. It is the only reason the live file differs.
2. **Drop `owner`/`group`/`mode`/`recurse` from `group_vars/media.yml`** — not as
   a concession, but because exFAT physically cannot store them. Permissions come
   from the mount options (`uid=`/`gid=`/`umask=`), which is where they belong.
3. That also removes the `chmod -R 0777` hazard, since it came from `recurse`.

🛑 **Do not run `--tags samba` on cobra until 1 and 2 are done.** 📌 The tell that
a role has never converged: its `force: false` backup task reports `changed`.

*State:* decided, not built. *Effort:* small–medium. *Needs:* a laptop (Ansible).

```
Make cobra's Samba converge from the repo — nothing hand-managed. Read
docs/TODO.md item 2. Bring the hand-added [Plex_Storage] block into the
samba role's template (parameterised from inventory), and remove
owner/group/mode/recurse from group_vars/media.yml because /mnt/almacenNTFS
is exFAT and cannot store them — permissions come from mount options.
Verify with --check --diff BEFORE applying: the diff must not touch
/mnt/almacenNTFS and must not chmod anything. Then apply and confirm
changed=0 on a second run, and that Plex still reads the share.
```

**4. cobra's Plex repo was migrated by hand, so `--tags plex` fails on it**
Found 2026-08-18 while deploying the maintenance-window fix. A `--check` run of
`services.yml --limit cobra --tags plex` **fails** at *Set Plex keyring
permissions*: `/etc/apt/keyrings/plexmediaserver.v2.gpg` does not exist. cobra's
live `plex.list` reads `signed-by=/usr/share/keyrings/plexmediaserver.v2.gpg` —
the v1.43 repo migration was done by hand, in the *legacy* keyring directory,
and the role's version of it has never run there.

⚠️ It also still has `/usr/share/keyrings/PlexSign.key`, which the role deletes.
So a real `--tags plex` run would remove the legacy key, rewrite the repo, and
re-run the apt setup on the host that serves the media library.

**Same class as item 2** — hand-built state the role cannot converge onto — and
the same decision applies: nothing is managed by hand. The deploy that surfaced
this was scoped around it with `--skip-tags repository,packages,service`, which
is a workaround, not the fix.

*State:* diagnosed, not fixed. *Effort:* small. *Needs:* a laptop (Ansible).

```
Make cobra's Plex repo converge from the role. Read docs/TODO.md item 4.
Its plex.list points at /usr/share/keyrings/plexmediaserver.v2.gpg (hand-made)
while the role manages /etc/apt/keyrings/plexmediaserver.v2.gpg, so
--tags plex fails on "Set Plex keyring permissions". Verify with --check
--diff first, then apply, then confirm: changed=0 on a second run, `apt-get
update` clean with no NO_PUBKEY, plexmediaserver still active, and the
installed version unchanged (state: present must not upgrade it).
```

**3. The test environment does not yet do the thing it was built for**
✅ Goals are now written down: **[`TESTING_GOALS.md`](TESTING_GOALS.md) — read it
first.** The rig merged on 2026-08-18 (`5d2563c`, 10/10 green) serves **goal 4**,
monitoring-script regression. **Goal 1 — running real playbooks against a host
that is created and destroyed — is ~70% built and is the actual gap.**

📌 The plumbing already exists and is better than it looks: `test_hosts.yml` is a
real inventory connecting as the infra user over sudo, `provision_test_container.sh`
creates *and* destroys, and CT 198 covers Debian 12 for the Pis. **Do not rebuild
any of that.**

*State:* assessed, planned below. *Effort:* 3a small, 3b medium, 3c small.
*Needs:* a laptop, and CT 199 started (`ssh cwwk 'sudo /usr/sbin/pct start 199'`).

**3a. Run `bootstrap.yml` and a full `site.yml` against a container — never done**
The playbook goal 1 most exists for is the one least tested. Highest value here,
and it is pure verification: no new code until it fails.

```
Run the playbooks that have never been tested against a container. Read
docs/TESTING_GOALS.md goal 1 first — the inventory and provisioning already
exist, do not rebuild them.

Start CT 199 (ssh cwwk "sudo /usr/sbin/pct start 199"). Then, against
ansible/inventory/test_hosts.yml ONLY — never the fleet inventory:
(1) bootstrap.yml against a TEST_CT_BARE=1 container with -e ansible_user=root,
which is the only state where its user-creation branch runs at all;
(2) a full site.yml against a normal (non-bare) CT 199.

Expect failures — that is the point, this has never been done. For each one,
record whether it is a real playbook bug or a rig artefact, and fix only the
real ones. Finish with changed=0 on a second run of each, which is the actual
proof. Destroy and recreate the container between the two, and stop it when
done.
```

**3b. One command: create → converge → verify → destroy**
Today it is a manual sequence, which is why it does not get run.

```
Give the test environment a single entry point that creates a container,
converges it with a chosen playbook, verifies, and destroys it — so that
testing a change is one command and therefore actually happens. Read
docs/TESTING_GOALS.md and docs/ARCHITECTURE_DECISIONS.md "Test Environments"
first; the standing rules there (two inventories, infra-user-over-sudo, the
provisioning script taking no dependency on Ansible) are settled, not up for
redesign.

Reuse tests/provision_test_container.sh and ansible/inventory/test_hosts.yml —
this is a driver, not a rewrite. Do 3a first: it tells you what actually breaks.
Must destroy the container even when the converge step fails, and must refuse to
run against anything not named like a test container.
```

**3c. `sandbox.sh --create`, so a fresh box does not need a laptop tap**
Small, and it is the last thing standing between goal 2 and "done".

**Not doing (decided 2026-08-18, option (a)):** agent-lxc gets no
`pct create/destroy/exec` and no Linux-reachable vault. The agent proposes; a
human runs the ephemeral test. **Reassess after 3b exists** — see
[`TESTING_GOALS.md`](TESTING_GOALS.md) goal 3 for why the vault half is the
expensive half.

**Also open, narrower:** `wrapper_state_collision` is the one case that never
drops privilege — it has no `run_uut` call, so it was out of scope for a
mechanical conversion. The wrapper does run as the infrastructure user under cron
on every fleet host.

```
Add `sandbox.sh --create` so a fresh box does not need a laptop tap. Read
docs/TESTING_GOALS.md goal 2 and docs/TODO.md item 3c first — the scope
boundary is already decided and is NOT up for redesign: agent-lxc gets no
pct create/destroy/exec and no Linux-reachable vault (option (a), 18 Aug).
The agent proposes; a human runs the ephemeral test.

Do 3a and 3b first — 3b is the driver this extends, and building 3c against
a driver that does not exist yet means guessing at its interface.

Also open and narrower, fold it in only if it is genuinely one edit:
wrapper_state_collision never drops privilege — it has no run_uut call, so
the mechanical conversion skipped it, yet the wrapper DOES run as the
infrastructure user under cron on every fleet host. Fixing it means the test
exercises the privilege level production actually uses.
```

**43. The rig's dead Slack tokens fail the wrapper's shape gate, so no checked script runs on it**
`test_hosts.yml` sets `logging_token` and `alert_token` to
`TEST/TEST/testcontainernotarealwebhook` on both test hosts — dead, as intended,
but also the wrong *shape*. `enhanced_monitoring_wrapper` validates its first
argument against `T[A-Z0-9]*/B[A-Z0-9]*/[a-zA-Z0-9]*` and exits with a usage
error before it ever invokes the checked script. Forced on 2026-09-26: exit 1,
`Monitor webhook format invalid`, and a script that would have touched a file
never ran. **Nothing downstream of that gate is exercised on the rig at all** —
no check, no state file, no alert path. Every cron job the roles install there
fails identically and silently into its log.

🔴 **The fix is shape-matched fakes, not merely dead ones.** The unit tests
already do this (`wrapper_alert_dedup_test.sh` uses `TTEST0000/BTEST0000/…`),
which is why the regression suite is green while the rig is blind.

*State:* diagnosed, not fixed. *Effort:* small — two lines per host, then prove
it. *Needs:* CT 199 started. Do before 3a, or 3a's `changed=0` proves
convergence of cron jobs that cannot run.

```
Give the test rig Slack tokens that are dead AND shape-valid. Read docs/TODO.md
item 43 first. In ansible/inventory/test_hosts.yml, replace
TEST/TEST/testcontainernotarealwebhook (logging_token and alert_token, both
hosts) with fakes matching the wrapper's T[A-Z0-9]*/B[A-Z0-9]*/[a-zA-Z0-9]*,
following tests/unit/wrapper_alert_dedup_test.sh. Keep them visibly fake and
distinct per role (log vs alert).

Prove it, do not infer it: before the change, run one installed cron line by
hand on CT 199 and capture the usage error; after it, the same line must reach
the checked script (its own output or state file appears in logs_dir). Also
record what the wrapper does when hooks.slack.com rejects the fake — that path
is now exercised on the rig for the first time.
```

**9. Runaway-process detection — the fan removed the only thing that caught the last one**
On 2026-08-07 a single pegged core (a `grep -r` reading a chroot's `/dev/random`
forever on the OPNsense guest) held cwwk at ~95 °C for **ten hours**. The only
alert came from `check_thermal.sh`'s throttle delta — an accidental, downstream,
misattributing detector. **The fan (fitted 2026-08-10) removes it**: fan-OK
idle + one pegged core ≈ 68–71 °C, so the same incident now produces no throttle
delta, no temperature warning, and no alert of any kind. And the load checks
cannot see it by construction — `load ÷ cores` means one pegged core of 8 reads
"16% healthy", and the container branch reads cgroup pressure, which one busy
task never raises. Failure class 4: check exists, works correctly, cannot cover
the mode it appears to cover.

Design already settled in the old write-up: alert on a single process sustaining
~100% of one core across N consecutive samples, reusing `check_thermal.sh`'s
counter-delta idiom (sample process CPU-time, alert on sustained growth), placed
**where the process runs** — a pegged core on the firewall is nearly always
wrong, while `kvm` at 109% on cwwk is sometimes legitimate. Host scope is the
open decision. Two acceptance criteria carried over: (a) peg one core on the
cooled box (`timeout 300 sh -c 'while :; do :; done'`) and watch a real alert
reach `#home-alerts` — a temperature reading cannot satisfy this; (b) record a
fresh idle + pegged-core baseline post-fan so the next thermal comparison has a
true reference.

*State:* designed, not built. *Effort:* medium. *Needs:* a laptop.

```
Build the runaway-process check. Read docs/TODO.md item 9 first — the design
constraints (counter-delta idiom, place it where the process runs, firewall vs
hypervisor scope) are settled there. Any new check must count its faults and
return the total — reporting via print_status alone contributes nothing.
Acceptance is a forced failure: peg one core on cwwk with
`timeout 300 sh -c 'while :; do :; done'` and watch the alert reach
#home-alerts. Then record a fresh idle + pegged-core thermal baseline.
```

**39. The HA plug watchdog cannot fire through a flapping ping**
vinylstreamer was off the network for 2.5 h on 2026-09-13, yet HA recorded it
offline only 08:57–09:00, and the *offline 15 min → power-cycle the plug*
automation never fired. Reasoned, not verified (the full HA history needs the
primary user): item 37's bug reconnected wlan0 for ~8 s every 5 minutes, the ping
sensor caught those windows, and each one reset the *continuous* 15-minute timer.

📌 **Item 37 removes that night's flap source, not the class.** Any fault that
blips reachability inside the window defeats a `for: 15 min` trigger — and this
watchdog is the last resort for a hung Pi.

Proposed shape: trigger on *offline for most of the last 15 minutes*, not
*offline continuously for 15*. ⚠️ `history_stats` counts entries from any state,
including `unavailable` — use a time-weighted ratio, and check what the sensor
does across an HA restart. 🔴 A watchdog that power-cycles a host is a
consequential actuator: prove it fires on a flapping fixture **and** stays silent
through a normal HA restart before deploying.

🔴 **Hold this until item 37 has been through a real lockout.** A flap-tolerant
trigger fires *more* often than today's, and with a 1 h cooldown a persistent
outage could cycle the plug every hour. With 37 fixed, software recovery should
win before the plug is ever needed — measure that first, then decide this and the
cooldown together.

*State:* diagnosed from partial history; **deliberately held behind 37**.
*Effort:* small–medium. *Needs:* laptop.

```
Fix the vinylstreamer plug watchdog so a flapping ping cannot defeat it. Read
docs/TODO.md item 39. FIRST confirm the mechanism from HA's recorder (read-only
sqlite, --become): list binary_sensor.vinylstreamer_online state changes for
2026-09-13 06:30-09:05. If it did NOT flap, stop and report — the design below
rests on it.

If it flapped: change the trigger from "offline continuously 15 min" to
"offline for most of the last 15 min" (time-weighted, not history_stats entry
counts, which include unavailable). Before deploying, show it (a) fires on the
06:30-09:00 flap pattern and (b) does not fire across an HA restart. Deploy with
--tags config AND check which other tags consume the same entities.
```

**38. Spotify refuses Mullvad exits — hifipi now egresses direct; two small follow-ups**
✅ **Resolved 2026-09-13.** raspotify on hifipi died at the weekly 00:00
restart with `403 Forbidden`. A same-client test settled it (laptop curl
tunnelled out through hifipi → 403, through dockassist → 200), and so did
Mullvad's per-relay proxies: Spotify refused the one exit VLAN 40 was on, not
Mullvad as a whole. It landed on that exit because VLAN 40/80's failover group
lost NL1 and NL2 around 10 Sep (item 41).

**Fix, on OPNsense (not managed in this repo):** a floating rule, interface
VLAN 40, `from hifipi to ! USED_LAN_NETS`, gateway WAN. Verified: hifipi egresses
direct and gets 200; cobra (the control, same VLAN) still egresses via Mullvad;
hifipi still reaches Home Assistant, MQTT and DNS; raspotify is active with no 403.

🔴 **Three traps hit on the way — read before touching this rule again:**
- **A *URL Table (IPs)* alias downloads a file of IP addresses.** Pointed at
  `https://*.spotify.com` it yields an empty table and a rule that matches
  nothing. Hostnames need a *Host(s)* alias (re-resolved every 300 s; no
  wildcards). A true wildcard needs dnsmasq's IPset feature, which requires
  dnsmasq in the DNS path — rejected as too invasive for one service.
- **`to any` on a route-to rule sends inter-VLAN traffic to the WAN gateway.** It
  broke hifipi → dockassist (HA, MQTT) and TCP DNS. The destination must be
  `! USED_LAN_NETS`, exactly like the VLAN rule it overrides.
- **Rules covering several interfaces load before single-interface rules,
  whatever their sequence** (observed on 26.7.2: a sequence-126 single-interface
  rule loaded after a sequence-131 VLAN 40+80 rule). Floating rules load before
  both, which is why the override is floating.

**Follow-ups (small, laptop):**
1. `spotify_event.sh` calls `mosquitto_pub` with **no timeout**, from raspotify's
   `ExecStartPre`. With the broker unreachable it hung past systemd's 90 s start
   limit, so raspotify never started — any MQTT outage would do the same. Wrap
   it in `timeout`.
2. `check_raspotify.sh` should recognise the 403 in the journal and report
   *Spotify refuses this egress IP* instead of restarting pointlessly.

*State:* resolved; follow-ups open. *Effort:* small. *Needs:* laptop.

```
Close the item 38 follow-ups. Read docs/TODO.md item 38 — the routing fix is
DONE on OPNsense and verified; do not touch the firewall rule.

(1) In roles/services/audio_playback/files/spotify_event.sh, bound every
mosquitto_pub with `timeout` (a few seconds), so an unreachable broker can never
block raspotify's ExecStartPre. Force it: point the broker at an unroutable
address (a unit-test stub is enough) and show the reset path returns within the
timeout instead of hanging.
(2) Make check_raspotify.sh detect "403 Forbidden" in the unit's recent journal
and report "Spotify refuses this egress IP" without restarting. Force the branch
with a stubbed journal line and watch the message fire.
Deploy with services.yml --limit hifipi --check --diff first, and count the
recap. Then move item 38 to docs/archive/DONE.md.
```

### 🟢 P3 — improvements, no urgency

**5. Tokens out of cron command lines.** healthchecks.io and Slack tokens sit in
literal cron args, visible to `crontab -l` and `ps` — and to `read_agent` via
`journalctl -u cron`, which prints every cron command line and which its sudoers
permits, so a read-only account can read the alerting credentials. Move to an
env file (`0600`) sourced by `enhanced_monitoring_wrapper`; rotate the two
webhooks as part of it. Needs a coordinated fleet redeploy.

```
Move the healthchecks.io and Slack tokens out of cron command lines. Read
docs/TODO.md item 5. Pattern: /etc/monitoring/tokens.env (0600, from vault)
sourced by enhanced_monitoring_wrapper, with a positional-arg fallback so the
rollout does not have to be atomic; then strip the token args from every cron
task across roles and redeploy the fleet. Rotate both webhooks at the end —
they have been exposed in diffs and cron mail for months. Verify: crontab -l
on every host shows no tokens, and one forced failure still reaches
#home-alerts.
```

**6. FreeBSD monitoring code runs on no host.** `deploy_monitoring.yml` excludes
`system_health_check.sh` from FreeBSD and actively removes it, so
`freebsd_default_services()`, `freebsd_service_state()` and `read_load_1min()` are
dormant. Either give them a FreeBSD test target (stock FreeBSD 14.3, not
OPNsense — no official image exists) or delete them.

```
Close the FreeBSD dead-code question. Read docs/TODO.md item 6 and the L-B
entry in docs/archive/DONE.md. deploy_monitoring.yml excludes
system_health_check.sh from FreeBSD, so freebsd_default_services(),
freebsd_service_state() and read_load_1min() run on no host. Recommendation:
delete them (git has them) unless a stock FreeBSD 14.3 test VM is being built
in the same session — dormant "verified" code is not a third option.
```

**7. Flap damping.** A fault that alternates pass/fail defeats repeat
suppression. Deliberately deferred: *"fix forward if annoying."*

```
Add flap damping to enhanced_monitoring_wrapper. Read docs/TODO.md item 7 and
the L-F entry in docs/archive/DONE.md first — repeat suppression (1h→24h
doubling) exists and is deployed; the gap is a fault that alternates
pass/fail, which resets the backoff every cycle. Damp on transitions per
window, not consecutive failures. Then force a flapping fault on CT 199 and
watch the paging rate drop while a steady fault still pages.
```

**10. Coverage audit — enumerate what nothing watches at all**
Raised 2026-08-07: *"I don't know if I'll know I need to do anything on those
hosts until I access them"*, and *"what other similar risks are we just
accepting blindly?"* Every fix of the August sprint was a check that existed and
did not work; this is the other class — **things nothing watches**, which no
amount of fixing existing checks surfaces. Method: per host, enumerate *failure
mode → what tells you → how fast*, starting from failure modes rather than from
the checks that exist. **The blanks are the deliverable.** Known blanks going in:

- **PVE package/kernel updates on cwwk** — `unattended-upgrades` origins are
  Debian-Security only; Proxmox's own mechanism is mail to `root@pam`, and cwwk's
  postfix defers everything to icloud on a blocked :25. Invisible end to end,
  on the host where the reboot was deliberately made a human decision.
- **OPNsense firmware updates** — nothing anywhere. The 26.1.9 upgrade that
  deleted `read_agent` was visible only in the GUI and went unnoticed 3 months.
- **Backup restorability** — freshness is monitored; nothing ever downloads a
  backup, runs `age -d` and validates the tarball. The first blank to close.
- **Role-owned script drift** — `deploy_monitoring.yml` syncs only
  `scripts/common/`; role-owned scripts rot silently (hifipi's did for 4 months).
  A periodic repo-vs-host checksum check is the known fix shape.

*State:* method decided, not started. *Effort:* medium (it is a review — its
value is in being systematic). *Needs:* a laptop for the doc; reading can
happen anywhere.

```
Run the coverage audit. Read docs/TODO.md item 10. Per host, enumerate
failure mode → what tells you → how fast, starting from what the host exists
to do — not from the checks that exist. Output: a table in docs/, linked from
ARCHITECTURE_DECISIONS.md, with the blanks made explicit; the blanks are the
deliverable — do not fix anything mid-audit. Seed it with item 10's four
known blanks (PVE updates, OPNsense firmware, backup restorability,
role-owned script drift).
```

**11. agent-lxc — Phase C (operator mode) and the rebuild-identity decision**
Phases A+B are live; Tier 2 investigates real alerts. Phase C is **designed,
not built**: `~/.claude/plans/phase-c-operator-plan.md` (§0: no operator key, no
operator user — `choco` via the existing per-device Secure-Enclave keys,
forwarded; every command gated by an OpenCode `ask` *and* a biometric tap; §0b:
with the test rig, approval means seeing a diff **and a container test result**,
never a command that has run nowhere). Its old preconditions (agent branch
unmerged, Tier 2 never run clean) are gone.

Before the deferred destroy/rebuild test, decide the key identity:
(1) accept + document the two-command re-key (rebuild mints a new
`agent_lxc_ed25519`, copy the pubkey into `group_vars`, re-run
`agent_access.yml`), or (2) vault the keypair so rebuild is vault-password-only.
**Recommend (1)** — rebuilds are rare and the private key never leaving the box
is the stronger posture. The test itself is ~20 min of disruption to a working
observer; do it under whichever option is chosen, not blind.

*State:* planned (plan file is the source — do not delete it). *Effort:* large
(Phase C), small (the decision). *Needs:* a laptop and Ignacio's sign-off on
the plan.

```
Start Phase C (operator mode). Read ~/.claude/plans/phase-c-operator-plan.md
end to end first — §0's decisions (no operator key, no operator user, choco
via forwarded Secure-Enclave keys, ask + biometric double gate) are settled,
and §0b makes a container dry-run part of every approval. Decide the rebuild
identity before the destroy/recreate test: recommended option (1), accept +
document the two-command re-key. Operator reference: docs/AGENT_LXC.md.
```

**12. Small-fix batch — none worth its own slot, all real**
One branch, tick them off. Phone-taggable lines marked 📱.

- `ansible.builtin.apt_repository` is deprecated and goes away in ansible-core
  2.25 (we run 2.21.3). **Three call sites left**: `services/docker`,
  `services/audio_playback`, `services/plex`.
  ✅ `playbooks/tasks/speedtest_cli.yml` was migrated to `deb822_repository` on
  2026-09-05 and **is the worked example** — it also documents the two traps:
  the old `.list` must be explicitly removed or apt sees the repo twice, and
  `python3-debian` must be installed or `--check` fails on the task.
  📌 There is a second, better reason than the deprecation: `apt_repository`
  requires a `gpg` binary on the target and **fails outright without one**, which
  is what it did on agent-lxc. Any minimal host added to the fleet hits this.

- `AGENTS.md` still says `deploy_monitoring.yml` deploys "monitoring scripts to
  all hosts" — it syncs only `scripts/common/`. That wording is what hid the
  hifipi drift; fix it.
- 📱 dockassist: `rm ~/.log/check_container.sh.json*` (orphaned state) and
  `~/crontab.bak.20260802`. hifipi: `rm ~/*.bak.20260802` (2 files).
- `heartbeat_backup.sh:30` — `|| true` + discarded stderr means a failed ping is
  invisible; log the curl exit status. If the nightly backup DOWN/UP pattern
  (seen 2026-08-09 and 08-11, all three hosts recovering in the same minute)
  recurs, read the healthchecks.io ping log first — it discriminates "cron
  didn't fire" from "path broke".
- `read_agent`'s `from=` pin is `10.30.0.0/16`, but `ARCHITECTURE_DECISIONS.md`
  claims single-IP pinning. Tighten the vault value or fix the doc (check the
  laptop's DHCP reservation before tightening).
- Recovery notifications go to `#home-logging` while the failure they clear sat
  in `#home-alerts` — a self-healed check looks permanently broken. One-line
  wrapper change; decide how loud recoveries should be.
- 📱 Rotate the UniFi read-only password (transmitted in plaintext at setup;
  Settings → Admins, then `ansible-vault edit`).
- `templates/debian/sshd_config.j2` drops Debian's
  `Include /etc/ssh/sshd_config.d/*.conf` — add it (template wins by ordering)
  or state that drop-ins are unsupported.
- Delete the never-deployed `docker-compose.yml.j2` + its dead handler in the
  homeassistant role.
- 📱 Delete the 5 stale `unavailable` Tado automations in HA's UI (`.storage`,
  not repo-managed).
- 📱 opnsense `/usr/local/bin` cruft (`monit-slack.sh{,.old}`,
  `switch-vpn-country.sh`, `import_gpg_github.sh`) — verify each is genuinely
  uncalled before deleting anything on the firewall.
- cwwk postfix defers all mail to icloud on blocked :25 (~41h queue ages) —
  route via an authenticated :587 smarthost or stop generating mail.
- unifi-lxc is the last host with drift the SSH pass didn't cover — run
  `site.yml --limit unifi-lxc --check --diff` and align per-item.
- `INJECT_FACTS_AS_VARS` goes away in ansible-core 2.24; the repo uses bare
  fact names everywhere. Mechanical repo-wide sweep, own branch.
- cobra and dockassist still carry malformed `dt_overlay="disable-bt"` /
  `dt_overlay="disable-wifi"` lines in `/boot/firmware/config.txt`, left by an
  old `rpi-provisioner`. The directive is `dtoverlay=`, unquoted, so they are
  inert — but they read as active config and are exactly the trap that cost
  five days. Delete them; the correct `dtoverlay=disable-bt` is already there.

*State:* all diagnosed, none started. *Effort:* small each. *Needs:* mixed —
📱 lines work from a phone, the rest want a laptop.

```
Work through the small-fix batch. Read docs/TODO.md item 12 — fourteen
diagnosed one-liners; do them on one branch and tick each off in the file as
it lands. Start with the AGENTS.md deploy_monitoring wording (it hid a
4-month drift). For each fix verify the behaviour, not the absence of the
error — the heartbeat curl fix must log a forced failure, the
recovery-routing change must deliver a real recovery to the chosen channel.
```

**19. `ha_state`'s error message sends you to the wrong place**
Run without `sudo`, the helper reports:

```
ha_state: monitor token not found in /home/choco/homeassistant/secrets.yaml
```

The token is present and the helper works fine — `sudo ha_state <entity>`
returns JSON, and the sudoers rule for it has existed all along. The message is
simply wrong about *why* it failed: the helper runs as `read_agent`,
`/home/choco` is `0700`, so the `sed` cannot open the file and an unreadable
file is reported as a missing value.

⚠️ **This is small, and it is here because it cost real time.** On 2026-08-24 a
session read that message, concluded the helper had never worked, wrote it up as
a third instance of "capability the unattended tier cannot use", and had to
retract all of it once `sudo` was tried. **An error that misidentifies its own
cause is worse than a vague one**, because it is confidently actionable in the
wrong direction.

*State:* **deployed and mostly verified 2026-09-05.**

⚠️ **This entry said "Deployed to dockassist" and that was wrong.** The fix was
merged on 2026-08-24 and sat **undeployed for 12 days**; a `--check` run of
`agent_access.yml` on 2026-09-05 reported the helper as `changed`, with the
sudo-branch block showing as an *addition*. It only surfaced because an
unrelated run happened to touch that role. 📌 **"On `main`" is not a state this
fleet has** — `changed=0` against the host is; see the standing note at the top
of this file.

Now genuinely deployed, and two of three branches forced on dockassist as
`read_agent`: without `sudo` it names the unreadable file and says to use sudo;
with `sudo` it returns JSON.

🔴 **The third branch is still unforced** — "key absent from `secrets.yaml`".
Its wording changed too ("monitor token not found" → "key ha_monitor_token is
absent"), so that text has never been executed. Forcing it means mutating the
live HA secrets file, which is why it was skipped rather than faked.

```
Verify the ha_state error-message fix on dockassist. Read docs/TODO.md item 19
first — the helper is NOT broken, it needs sudo, and the old message hid that.
Force BOTH branches as read_agent over SSH, not as choco:
  ssh dockassist-agent 'ha_state binary_sensor.vinylstreamer_online'
    -> must now say it cannot read the file and to use sudo
  ssh dockassist-agent 'sudo ha_state binary_sensor.vinylstreamer_online'
    -> must return JSON
🔴 The sudo/no-sudo branches were forced on 2026-09-05 and both behave. What
is LEFT is only the "key absent" branch: point the helper at a COPY of
secrets.yaml with ha_monitor_token removed — do NOT edit the live file on the
HA host. If the helper has no path override, add one for the test rather than
mutating production. A message that is merely reworded but never executed has
not been tested.
```


**34. The docker role reports `changed` on every run, so `changed=0` cannot be trusted for it**
`Download Docker GPG key` uses `force: true`, so `get_url` re-fetches and
reports `changed` every single run, which then drags `Add Docker repository`
along with it. A `--tags docker` run on a fully-converged dockassist shows
`changed=2` before any real change is made.

🐛 **Why this is more than cosmetic:** `changed=0` on a second run is the only
convergence signal this fleet has — "merged" is not a state it possesses. A
role that can never report it removes that signal exactly where Docker config
now lives (`docker_daemon_options`, added 2026-09-04). Any future session
verifying a Docker change has to eyeball task names instead of trusting the
recap.

*State:* observed 2026-09-04 while shipping the daemon.json change; not
investigated further. *Effort:* small. *Needs:* a laptop (Ansible deploy).

```
Make the docker role idempotent so `changed=0` means something. Read
docs/TODO.md item 34 — the two offending tasks are named there, do not
re-derive them.

In roles/services/docker/tasks/main.yml, `Download Docker GPG key` has
force: true. Establish FIRST whether it is load-bearing (git log / blame the
line — it may have been added to recover from a corrupted key) before removing
it. If it can go, prefer a checksum or a creates-style guard over deleting the
force outright, so a genuinely changed upstream key is still picked up.

🔴 Verify the way this repo verifies idempotency, not by reading the diff:
run the role twice back-to-back and require changed=0 on the SECOND run —
and note that fact caching freezes ansible_date_time for an hour, so
back-to-back runs are NOT proof on their own for tasks that template a
timestamp. These two tasks do not, so they are a fair test.

Do not touch the daemon.json task while here; it is verified working and
its `when` guard is deliberate.
```

### 🧊 Blocked on Ignacio, not on work

**26. The CI failure email now duplicates the #home-alerts message**
A red `main` announces itself twice: the Slack alert added 2026-08-30, and
GitHub's own failure email. Ignacio does not want both.

🔴 **There is no CLI path — this one really is a UI toggle.** Probed
2026-08-30: `/user/notification_settings`, `/settings/notifications` and
`/user/preferences/notifications` all return 404. No REST endpoint exposes the
preference.

⚠️ **And it is global, not per-repo.** Ten repos have workflows —
`touchid-agent` (4), `ignaciojimenezpi.github.io` (6), `pastebin-worker` (4),
`.allstar` (3), `cobra` (2), `dotfiles`, `liquidsoap-daemon`,
`recordsdelmundo-site`, `vulnalerts`, `infrastructure-automation`. Turning the
email off blinds **nine repos that have no Slack alerting**, including a public
one distributed through a brew tap and the Allstar security policy repo.

📌 **The duplicate is nominal, not real.** The email costs no attention today —
22 of them were scrolled past in 11 days. This is *one ignored email plus one
alert he will see*, not two competing notifications.

*State:* decision only, nothing to build. *Effort:* one toggle, or a small
rollout. *Needs:* him. *Phone — it is a browser setting.*

```
Decide the CI failure email. Read docs/TODO.md item 26 — the probe is DONE, do
not repeat it: there is no API for this preference (three endpoints, all 404),
it is a UI toggle at https://github.com/settings/notifications, and it is
GLOBAL across the 10 repos that have workflows.

Two coherent options, and it is Ignacio's call, not the agent's:
(a) Leave it. The email is already ignored, so the duplicate costs nothing and
    nine other repos keep their only failure notification.
(b) Turn it off AND roll the #home-alerts step out to the repos where a red CI
    actually matters — touchid-agent and .allstar first. Do NOT turn it off
    without that rollout; that trades a duplicate for a blind spot.

If (b): reuse the step from .github/workflows/ansible-lint.yml verbatim,
including the failure()+push+main gating and the env-not-${{ }} handling of the
commit subject. Each repo needs its own SLACK_ALERT_WEBHOOK secret. Force a
real failure in each and watch #home-alerts before calling any of them done.
```

**32. Decide whether to rewrite git history for the pre-2026-08-30 disclosures**
Needs a decision, not work. Item 24 redacted `HEAD`. The wireless
SSID→VLAN→isolation→PMF table, the console list and the HomePod MAC are still in
this repo's git history, and GitHub serves those blobs at their commit SHAs to
anyone who knows them.

**What a rewrite would buy:** `git filter-repo` can drop the affected blobs, and
GitHub garbage-collects unreferenced objects after a support request. Someone
starting from a fresh clone tomorrow would find nothing.

**What it costs, and cannot buy:**
- It force-pushes a public repo. Every existing clone and every worktree breaks.
- **It cannot recall what has already been read or cloned.**
- Search-engine and archive caches are outside anyone's reach.

📊 **Measured 2026-08-30, and it settles the question** (`gh api
repos/:owner/:repo/traffic/{clones,views}`, GitHub's 14-day window):

| Metric, 14 days | Count | Uniques |
|---|---:|---:|
| **Clones** | **222** | **85** |
| Views | 4 | **1** |

Read that pair carefully. **Nobody is browsing this repo** — one unique viewer in
two weeks, almost certainly Ignacio. But **85 unique cloners pulled it 222
times**, and a clone takes the *entire history*, not `HEAD`. That is automated
traffic: crawlers, mirrors, dataset scrapers, package/CI bots. Fork count is 0,
which would have made a rewrite technically effective — but 85 cloners in a
fortnight, extrapolated over however long the table has existed, means the
content is already out at scale in places no force-push reaches.

🎯 **The honest framing:** a rewrite is a *tidiness* decision about what a future
reader finds by default. It is **not** containment, and the traffic numbers make
that concrete rather than theoretical.

🔴 **And there is no longer a "real fix" to weigh it against.** This item used to
say: prefer item 31, because enabling PMF removes the weakness rather than its
description. **Item 31 was tested and refused on 2026-09-02** — the IoT devices
cannot associate with PMF. So redaction is now the *entire* available mitigation,
and a history rewrite is still not one: it recovers nothing from 85 unique cloners
a fortnight.

📌 **Default is no**, and the measurement argues for it. Do not rewrite history
without Ignacio saying so explicitly.

⚠️ **The same numbers are the strongest argument for the redaction going
forward.** Whatever is committed to this repo tomorrow gets pulled by ~85 unique
cloners within two weeks. That is the cost of every future line — which is why
`docs/local/` exists and why the tiering rule is worth following.

*State:* decision only. *Effort:* an hour if yes, zero if no. *Needs:* Ignacio.

```
Ignacio has decided on the git-history question for TODO item 32. Fill in:

  DECISION: [rewrite history / leave it]

If "leave it": delete item 32 from docs/TODO.md, record the decision and its
reasoning in docs/archive/DONE.md, and add a one-liner to
docs/ARCHITECTURE_DECISIONS.md so it is not re-litigated. Nothing else.

If "rewrite history": this is destructive and irreversible on a public repo.
Confirm the blob list with him BEFORE touching anything, take a full mirror
clone as a backup first, and use `git filter-repo` (not filter-branch). Every
other clone and worktree of this repo must be re-cloned afterwards — enumerate
them with him first. Then open a GitHub support request for GC; a rewrite
without it leaves the objects reachable by SHA. State plainly, in the write-up,
that forks and anything already read are unaffected.

Do NOT start a rewrite on your own judgment. And do NOT resurrect PMF (the old
item 31) as an alternative — it was TESTED and REFUSED on 2026-09-02 because the
IoT devices cannot associate with it; see ARCHITECTURE_DECISIONS.md.
```

**8. Cabinet vent sizing.** Needs three physical measurements only he can take:
power draw of cwwk + the Zyxel switch (**the biggest unknown — every heat figure
to date rests on a 55–110 W assumption**), usable panel dimensions, and
hole-count limits. Handover artifact: *"cwwk Cabinet Fan — Vent Sizing Handover."*
Context worth keeping: the fan is fitted (2026-08-10) and **door position
dominates everything** — same nightly load peaked 94 °C fully closed vs 81 °C
resting; the vents exist so the closed door can match the resting-door baseline
(pkg 52–57 °C, zero throttling). Airflow is a ceiling, not a lever — running
the fan harder is ruled out on acoustics.

```
I measured the cabinet: cwwk+switch power draw = __ W, usable panel =
__ × __ cm, hole-count/aesthetic limit = __. Read docs/TODO.md item 8 and the
"cwwk Cabinet Fan — Vent Sizing Handover" artifact. Compute the intake area
needed for the fully closed door to match the resting-door baseline (the
proven intake is the measured 5 mm × 49 cm ≈ 24.5 cm² resting-door gap; target
pkg 52–57 °C, zero throttling) and give me a drill plan: hole count, diameter,
spacing, placement. Show the thermal margin math.
```

**13. Cabinet ambient sensor.** Needs a hardware purchase decision: a Shelly H&T
(or Shelly Add-On + DS18B20) reporting into HA via the existing Mosquitto broker
on dockassist. It would be the first direct "the cabinet lost cooling" signal —
both fan incidents surfaced as CPU throttle alerts after the fact. The Zyxel
switch offers **no telemetry of any kind** (verified 2026-08-01: no SNMP, no
temperature readout; its user guide's 40 °C ambient limit is the citable
threshold). 📌 The software half — extending `save_temps.sh` to the Pis so they
get the thermal history cwwk has — is *not* blocked and can ride any monitoring
deploy.

```
Help me add the cabinet ambient sensor. Read docs/TODO.md item 13. Compare a
Shelly H&T vs Shelly Add-On + DS18B20 for this cabinet (MQTT into the
authenticated Mosquitto broker on dockassist, battery vs powered, placement),
recommend ONE. Once I confirm the purchase: integrate it into HA, alert to
#home-alerts at the Zyxel guide's 40 °C ambient limit, and extend
save_temps.sh to the Pis in the same pass so the history exists before the
first incident.
```

**14. UPS topology.** Confirm which devices actually share the Pis' power
protection. The 2026-06-30 split (cwwk down, Pis up) suggests cwwk is
unprotected, and the 2026-07-30 whole-house outage took the fleet down for ~24h.
Physical check only he can do.

```
UPS findings: __ (which devices are on the UPS, its model, what happened at
the last outage). Read docs/TODO.md item 14. Record the topology in
docs/NETWORK.md, then decide: does cwwk need UPS protection and/or NUT
monitoring, given it is the internet SPOF and came back on its own on
2026-07-30? Recommend one option.
```
