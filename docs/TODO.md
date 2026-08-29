# Infrastructure TODO — open work

**Improvements and fixes waiting to be worked on.** Start at *What to work on
next*; the first item you can act on is the right one.

Updated: 2026-08-29

| Where a thing lives | |
|---|---|
| **Open work** | this file |
| **Finished work + why** | [`archive/DONE.md`](archive/DONE.md) |
| **How the system is built** | [`ARCHITECTURE_DECISIONS.md`](ARCHITECTURE_DECISIONS.md) |
| **What the test environment is for** | [`TESTING_GOALS.md`](TESTING_GOALS.md) — read before any test work |
| **Full narrative of past sessions** | git history |
| **Phone-first router, with copy-paste prompts** | the *Infra — What to work on* artifact — link is printed at session start by `.claude/session-start-dashboard.sh` (kept out of this public repo) |

> 📌 **The dashboard is a render of this file's *What to work on next* section**, and
> exists for two things only: starting work from the phone without a session, and
> handing over ready prompts so a session does not spend tokens rediscovering
> context. **If you change the items below, update the dashboard** — nothing in the
> repo surfaces it, so it goes stale silently.

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

> **№1** 24 *(public repo, security)* → **№2** 18 *(active fault, and it gates
> 1d)* → **№3** 1c → **№4** 1d *(only after 18)* → **№5** 2 →
> **№6** 4 (plex) → **№7** 9 → **№8** 3a/3b → **№9** W1 *(also an active fault — it
> fired 29 Aug; layered recovery is deployed and now produces a trustworthy
> layer verdict on the next outage)* → **№10** 5 → **№11** 19 →
> **№12** 12 → **№13** 22 → **№14** 10 → **№15** 11 → **№16** 6 → **№17** 7 →
> **№18** 25 →
> **№19–22** 8/13/14/16
> *(decision-gated — 16 needs a purchase call, the rest need him at the
> cabinet; not ranked)*

**Re-ranked 2026-08-29 on the question "is 1c really the most important?"** —
it was not. **24 enters at №1**: it is a live disclosure in a public repo, and
redacting a document is cheap. **18 takes №2** because it is the only thing
actively recurring — nine NIC stalls since 11 Aug — and because it inverts the
obvious order: **1d doubles the saturation runs, so doing it before 18 would
knowingly make the active fault worse.** 1c is independent and stays ahead of
1d. Nothing else was time-sensitive enough to move.




**19 and 18 enter at №10 and №11** because both are small and both are about
*seeing* — 19 restores a read path the agent tier was supposed to have, and 18
adds the only tripwire for a fault that was invisible until 2026-08-24. The
journal fix landed the same week and paid for itself within hours; these are
the same trade.

📌 **Every item carries a paste-ready prompt** — including blocked ones, which
carry *fill-in* prompts that take the physical measurement or decision as
input. An item without a prompt is an item that has not been triaged properly.

### 🔴 P1 — actively producing false alerts

**Nothing here right now.**

📌 **Numbering is deliberately not compacted.** Several prompts below and in
git history say "read docs/TODO.md item 2" or "item 3a"; renumbering on every
close would silently repoint them. Numbers are addresses, not ranks — the
headings say what is urgent.

### 🟠 P2 — known risk, not currently biting

**1c. The speedtest dependency is hand-installed, and two hosts run different tools under the same name**
`internet_speed_monitor` needs Ookla's `speedtest`, and **nothing in this repo
installs it.** It was put on dockassist by hand. Rebuild that host and the monitor
exits 2 with "Speedtest command failed or not available" — the check goes quiet
without ever alerting.

🐛 **Worse than missing: it is ambiguous.** `speedtest` resolves to a *different
program* on each host — Ookla 1.2.0.84 on dockassist, Debian's Python
`speedtest-cli` 2.1.3 on agent-lxc (the `speedtest-cli` package ships
`/usr/bin/speedtest` too). Both print plausible Mbps. Any script calling
`speedtest` gets a different methodology depending where it lands.

*State:* diagnosed 2026-08-19, nothing changed yet. *Effort:* small.
*Needs:* a laptop (Ansible deploy). Worth doing whether or not item 1d happens.

```
Fix the speedtest dependency without building the VPN monitor yet. Read
docs/TODO.md item 1c — the verified facts are there, do not re-derive them.

🔴 Also read item 18: the existing speedtest is intermittently wedging
dockassist's NIC (nine stalls since 11 Aug, all inside its run window). That
does not block this task — installing the right binary is correct either way —
but do NOT increase test count or frequency while here, and if you touch
agent-lxc's speedtest, note that host has no such measurement yet.

Write the Ansible task installing Ookla's speedtest (repo
packagecloud.io/ookla/speedtest-cli/debian/ <codename> main, keyring
/etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.gpg, package
`speedtest`), gated on enable_internet_speed_check; purge Debian's
`speedtest-cli` first — both ship /usr/bin/speedtest. --check --diff against
dockassist must come back clean (it already has the right binary). Then apply
to agent-lxc and verify `speedtest --version` reports Ookla there.
```


**1d. Monitor the VPN path's speed, not just the direct one**
Today only the **non-VPN** path is measured (dockassist, VLAN 100). VLAN 40 egresses
through Mullvad and is unmeasured, so a degrading tunnel would be invisible.

**Baseline measured 2026-08-19:** VPN **886/906 Mbps** vs direct **943/940** — the
tunnel delivers **94% of line rate**, so nothing is wrong today. That 94% is the
number to alert against.

📌 **Alert on the RATIO, not an absolute.** An absolute floor fires every time the
ISP has a bad evening and says nothing about the VPN; the ratio isolates
VPN-specific degradation.

⚠️ **Three things that will silently invalidate this if missed:**
1. **Pin `--server-id` on both paths.** `internet_speed_monitor` does not pass it
   today. Ookla picks the server nearest the *egress*, so the VPN path would choose
   relative to the Mullvad exit and the direct path relative to Odido — comparing
   two different tests and calling the difference "VPN slowness".
2. **Run the two tests sequentially, never concurrently.** Concurrent tests through
   one gateway measure each other. This is not theoretical: on 2026-08-19 an agent's
   parallel downloads produced the 250 Mbps reading that started the whole
   investigation.
3. **Prove the VPN-side host can saturate before building on it.** Still **unproven**
   for agent-lxc — the validation run failed on the wrong binary (see 1c). A host
   that cannot reach ~900 measures its own NIC, not the tunnel.

**Not opnsense**, for three independent reasons: it performs the WireGuard crypto so
the test competes with what it measures; it is the internet SPOF; and its own traffic
does not follow the per-VLAN policy routes clients use, so it would measure a path
nobody takes.

**Cost to weigh:** ~1.25 GB and a fully saturated line per test, deployed as
`--tests=5` every 6h (~25 GB/day, ~26 min/day saturated). A second path doubles it —
prefer `--tests=3` twice daily across both.

🔗 **Read item 18 before sizing this. The current test already has a measured
cost, not just a theoretical one.** dockassist's NIC has logged **nine
`bcmgenet` transmit-queue stalls since 11 Aug, every one 1–6 minutes into the
`0 */6` speedtest window** — the saturation run intermittently wedges the
Home Assistant host's link. That was invisible until 2026-08-24 and is exactly
the "prove the host can saturate" concern in point 3, arriving from the other
direction: dockassist *can* saturate, but not reliably without cost.

**So doubling the number of saturation runs is not a neutral change.** Decide
the volume question (18) and the coverage question (1d) together, or 1d
silently doubles a fault nobody had measured yet.

```
Build VPN-vs-direct speed monitoring. Read TODO items 1c, 1d AND 18 first — they
carry every verified fact, do not re-derive them.

Order, each step gating the next:
1. Ansible task installing Ookla's speedtest, gated on enable_internet_speed_check.
   Repo: packagecloud.io/ookla/speedtest-cli/debian/ <codename> main, keyring
   /etc/apt/keyrings/ookla_speedtest-cli-archive-keyring.gpg, package `speedtest`.
   A trixie suite EXISTS (queried directly) — do not pin bookworm. Purge Debian's
   `speedtest-cli` first; both claim /usr/bin/speedtest. Run --check --diff against
   dockassist first: it already has the right binary, so it must come back clean.
2. Add --server-id to internet_speed_monitor. Pin 52365 (Odido Amsterdam) — that is
   what it already auto-selects, so history stays comparable.
3. THEN validate agent-lxc can saturate: speedtest --server-id=52365. Want ~880-900.
   If it cannot, pick another VLAN 40 host — do not ship a monitor that measures a
   container's NIC.
4. THEN the ratio check: both paths sequentially, alert when VPN/direct drops below
   ~75% for two consecutive runs, plus a loose absolute floor.

🔴 Item 18 constrains this one. dockassist's NIC has logged nine bcmgenet
transmit-queue stalls since 11 Aug, EVERY one 1-6 min into the existing
`0 */6` speedtest window — the saturation run intermittently wedges the Home
Assistant host's link. Adding a second measured path DOUBLES the number of
saturation runs, so decide the volume question (18) before or alongside the
coverage question. Do not simply add a second `--tests=5` job.
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
*Needs:* a laptop, and CT 199 started (`ssh cwwk 'sudo pct start 199'`).

**3a. Run `bootstrap.yml` and a full `site.yml` against a container — never done**
The playbook goal 1 most exists for is the one least tested. Highest value here,
and it is pure verification: no new code until it fails.

```
Run the playbooks that have never been tested against a container. Read
docs/TESTING_GOALS.md goal 1 first — the inventory and provisioning already
exist, do not rebuild them.

Start CT 199 (ssh cwwk "sudo pct start 199"). Then, against
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

**4. `W1` — vinylstreamer's wifi lockout root cause**
The plug (W2) is remediation; the fault is untouched. Investigation exists at
`~/.claude/plans/vinylstreamer-wifi-lockout-plan.md`.

🔴 **Two reasons not to start yet.** (a) The 7-day cycle counter is contaminated
by W2's own forced acceptance tests — exclude 2026-08-16. (b) The standing model
says NetworkManager gives up and stays down **for days**, but the one clean
sample is an **18-minute unassisted recovery**. That contradiction must be
resolved before configuring anything.

**✅ Gate passed 2026-08-23 — here is the week of traffic it was waiting for.**
Excluding 2026-08-16 as the item instructs, **17–21 Aug contains zero
vinylstreamer outage events** (verified by Slack search of `#home-alerts`; the
only hit is an agent-key notice). The week produced exactly **one** genuine
incident, the night of 22/23 Aug:

| Time (CEST) | Event |
|---|---|
| 01:29 | drops off wifi — repeated `assoc-reject` on `estonoesmazagon_iot` |
| 01:44:06 → 01:44:21 | plug cycled, exactly 15 s |
| 01:45 | back online — **recovered only after the cycle** |
| 01:58:06 | drops again |
| 02:13:06 | watchdog fires, refused by cooldown |
| 10:50+ | **still down, ~9 h, no self-recovery** |

**(b) is resolved in favour of the standing model.** A 9-hour outage with no
unassisted recovery is the "gives up and stays down" behaviour; the 18-minute
sample sits inside the excluded 2026-08-16 window and should not be weighed.

**✅ 2026-08-24 — the fault is now positively identified: the Pi stays RUNNING.**
This was the one thing power draw could not settle, and the 16:10 outage settled
it by accident. `vinylstreamer_monitor.sh` ran at **16:10:02–16:10:04** and
reported every service active, CPU 3.8%, temp 41 °C — while HA had considered
the host offline since ~15:55. `uptime -s` puts the boot at **16:10:27**, so
that health check ran **25 s before the reboot**, i.e. on the locked-out
session. The host was alive, healthy and executing cron the whole time it was
unreachable.

**So this is a Wi-Fi lockout at the network layer, not a crash, halt, or power
fault.** Every remaining hypothesis about dead PSUs, SD corruption or brownouts
is now excluded by direct measurement.

Supporting conditions, measured the same day:

| What | Value | Why it matters |
|---|---|---|
| Signal | **-70 dBm**, link quality 40 | Weak enough to drop, strong enough to look fine |
| `NetworkManager` | active, **`conf.d/` is empty** | So `autoconnect-retries` is the default **4** — exactly the "gives up after 4" model |
| wifi powersave | unset → NM default (**enabled**) | The `brcmfmac` powersave path W1 already suspects |
| Recurrence | 2 outages in 16 h (23:45, 16:10) | It is getting worse, not settling |

The remediation now works — both outages self-recovered via the re-armed
watchdog — **which makes this less urgent and more maskable.** The plug is now
genuinely a crutch; `vinylstreamer_cycles_7d_escalate: 3` is the tripwire.

**✅ 2026-08-24 — the full failure chain, read from `journalctl -b -1`.**
The 15:55 lockout is captured end to end. It is **not** an auth/PSK problem and
**not** a signal dropout in the usual sense — it is an association *timeout*
that NetworkManager then misfiles as a *credentials* problem:

```
15:55:34 wpa_supplicant: wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
15:55:34 wpa_supplicant: CTRL-EVENT-SSID-TEMP-DISABLED auth_failures=2 duration=20 reason=CONN_FAILED
15:55:48 NetworkManager: device (wlan0): Activation: (wifi) association took too long
15:55:48 NetworkManager: device (wlan0): state change: config -> need-auth (reason 'none')
15:55:48 NetworkManager: device (wlan0): Activation: (wifi) asking for new secrets
15:55:48 NetworkManager: connection 'preconfigured' has security, and secrets exist. No new secrets needed.
   … retry, ASSOC-REJECT again, SSID-TEMP-DISABLED backoff 10 s → 20 s …
15:56:13 NetworkManager: device (wlan0): Activation: (wifi) association took too long
15:56:13 NetworkManager: device (wlan0): state change: config -> failed (reason 'no-secrets')
15:56:13 NetworkManager: device (wlan0): Activation: failed for connection 'preconfigured'
15:56:14 NetworkManager: device (wlan0): supplicant interface state: scanning -> disconnected
```

**Then nothing. Not one further wlan0 line for the remaining ~14 minutes of
that boot**, until the plug cycle at 16:10. That silence is the whole bug — it
is what "NetworkManager gives up and goes quiet" looks like from the inside.

Two distinct faults, and they need different fixes:

1. **Why it drops** — `status_code=16` with an **all-zero BSSID** means no AP
   ever answered the authentication sequence; wpa_supplicant generated the
   reject itself on timeout. At **-70 dBm** with wifi powersave at NM's
   default, the radio is asleep for parts of the handshake. This is the
   `802-11-wireless.powersave` knob.
2. **Why it stays down** — NM misattributes the timeout to missing
   credentials, having just logged that *secrets exist*. It exhausts its
   retries and lands on `failed (reason 'no-secrets')`, a reason that means
   "a human must intervene" — so autoconnect stops. `nmcli` confirms
   `connection.autoconnect-retries: -1`, and `man 5 NetworkManager.conf` on
   the host states that -1 means the global default, *"connections will be
   tried 4 times"*. This is the `autoconnect-retries` knob.

⚠️ **Fixing only (1) leaves a host that still dies permanently on the next
unlucky handshake; fixing only (2) leaves it flapping.** The proposed change is
both, on vinylstreamer alone: `802-11-wireless.powersave=2` (disable) and
`connection.autoconnect-retries=0` (retry forever).

📌 **Verify by forcing a disassociation, not by watching it stay up.** The
whole point is behaviour *after* a failed association, so a config that never
gets tested against one proves nothing.

*Unverified:* the precise IEEE 802.11 meaning of `status_code=16` (read as
"authentication timeout waiting for the next frame in sequence") is from
knowledge, not from a source on the host. The diagnosis does not depend on it —
the all-zero BSSID and NM's own "association took too long" establish the
timeout independently.

**⚠️ 2026-08-24 — deployed, and only HALF of it is verified. Read this before
declaring W1 closed.**

* ✅ **`powersave=2` is confirmed live.** `iw dev wlan0 get power_save` read
  `on` immediately after the drop-in was written — NM only applies powersave at
  association time — and `off` after the next association. (`iw` lives in
  `/usr/sbin`, which is not on `read_agent`'s PATH; an earlier "iw: not found"
  was that, not a missing package.)
* ❌ **`autoconnect-retries=0` is NOT confirmed, and cannot be synthetically.**
  The acceptance test used `nmcli con down` + `con up`, which was the wrong
  instrument: `con down` marks the connection deactivated *by user request* and
  blocks autoconnect, defeating the mechanism under test. The host stayed down
  16 min and was rescued by the plug (21:39), not by NM.
  **A raw `iw dev wlan0 disconnect` would not settle it either** — retry-forever
  only engages once association has failed repeatedly, so proving it needs the
  real fault, not a clean disassociation.

📌 **The next natural lockout IS the test, and it is self-reporting.** The
recovery message already distinguishes *"Recovered after a power cycle"* from
*"Recovered on its own, with NO power cycle"*. If the retries fix works, the
next lockout ends with the second sentence and no plug cut. **Do not force
another outage to chase this** — it costs a power cycle and proves nothing.

📌 Note the plug counter hit **4 cycles in 7 days** on 2026-08-24 and the
anti-masking escalation fired correctly. Read that as designed behaviour, not
as a new fault — three of those four were the same night's diagnosis and this
test.

**🔴 2026-08-24 22:16 — THE RETRIES HALF IS DISPROVEN. Do not re-deploy it as a fix.**

The natural lockout arrived 35 min after the previous recovery and was caught
end to end. `autoconnect-retries-default=0` was **verifiably in effect** —
`NetworkManager --print-config` on the host returns both
`autoconnect-retries-default=0` and `wifi.powersave=2` — and the host gave up
anyway, in the identical place:

```
22:17:17 Activation: (wifi) association took too long
22:17:17 state change: config -> failed (reason 'no-secrets')
22:17:18 supplicant interface state: scanning -> disconnected
```

**Then ZERO wlan0 or supplicant lines for 28 minutes**, until the plug cycled at
22:45. Counted, not eyeballed. Powersave was off for this outage too (verified
before and after), so **neither knob prevents the lockout**.

*Hypothesis, NOT verified:* a `no-secrets` failure sets an autoconnect **block**,
which is a different mechanism from the retry **counter** — a block disables
autoconnect regardless of how many retries remain, so the knob cannot reach it.
NM logs nothing explicit at info level; confirming this needs debug logging.

📌 **What this changes.** The mechanism in the diagnosis above is still correct;
what was wrong was assuming the retry counter could override the give-up. **The
next fix must stop depending on NM's own autoconnect** — e.g. a systemd timer or
NM dispatcher that runs `nmcli con up preconfigured` when `wlan0` has been down
for N minutes. That also converts a 15–45 min plug-cycle outage into a ~30 s
software recovery, and leaves the plug as the backstop it was meant to be.

✅ **Two things that DID work and should not be re-litigated:** the watchdog
re-arm behaved perfectly in production — it deferred at 22:30 ("inside the 1h
cooldown … Retrying automatically the moment the cooldown expires") and then
**cycled at 22:45 the moment the cooldown expired**. Before that fix, the 22:30
refusal would have been permanent. And `powersave=2` survives reboots.

**✅ 2026-08-24 23:30 — layered recovery DEPLOYED and running.**
`scripts/services/network/wifi_reconnect.sh`, cron `*/2`, vinylstreamer only.
Three layers, and **which one succeeds is the diagnostic**: `nmcli con up` =
NM merely gave up · interface bounce = the link layer needed resetting ·
`brcmfmac` reload = the driver itself wedged, which would reframe W1 entirely.
Every recovery posts to **#home-logging**, deliberately: a ~2 min self-heal
never reaches HA's 15-minute threshold, so without reporting the fault would
simply become invisible — item 15's failure mode. The plug watchdog stays as
the backstop for all-layers-failed.

🔴 **READ THIS BEFORE TOUCHING THAT SCRIPT — it took the host down on the day
it was written.** The first version judged health by pinging the default
gateway `10.30.100.254`. **That gateway deliberately answers no ICMP from
inside VLAN 100** — firewall policy, the IoT VLAN is kept restricted — while
answering normally from every other VLAN (measured: 0/3 from dockassist on
VLAN 100, 3/3 from cobra and hifipi on VLAN 40). The asymmetry is the trap:
probed from a laptop that gateway looks perfectly healthy — so the check could never pass, and cron
ran the full ladder *including a driver reload* every 2 minutes against a
perfectly healthy radio until the host fell over. Every branch had been tested
exhaustively with stubs; **the healthy path had never been run against the real
host.**

Three guards exist because of that, and none is decorative:
1. **Health comes from local facts whose healthy value was OBSERVED** — `nmcli`
   reporting `wlan0:connected`, and a default route on the interface. The peer
   IP is retained but is **diagnostic only and must never gate an action**.
2. **Two consecutive bad observations before acting.** A single bad sample must
   never reload a driver: acting wrongly costs an outage worse than the fault.
3. **No state, no action.** `/var/log/monitoring-state` is created by the
   *proxmox* role and is absent on a Pi, so the counter was unwritable on first
   deploy and guard 2 would have silently degraded to "act immediately". The
   script now refuses to run rather than run ungated.

**🔴 2026-08-29 — the streak ended at 4.52 days, and the ladder's verdict was
wrong. Read this before trusting any layer conclusion.**

The fault returned at ~11:10 with the identical signature (`ASSOC-REJECT
status_code=16`, all-zero BSSID). The 2-observation gate worked, the ladder
fired, and it reported **"all three recovery layers failed after 264s"**. The
plug cycled at 11:25:55 (**6 cycles in 7 days**) and the host was back at
11:26:53 after 16 min.

**It is vinylstreamer-specific, not an AP event.** HA successfully commanded the
Shelly plug — Wi-Fi, same VLAN, same AP — at 11:25:55 while vinylstreamer had
been off-network 15 min. dockassist (wired, same VLAN) has been up since 10 Aug
with no events in that window.

⚠️ **But layer 3 never ran, so "all three failed" was false.** `brcmfmac` is
held by `brcmfmac_wcc` (`lsmod` → "Used by: 1"), so `modprobe -r brcmfmac` fails
with *module in use* — and the script swallowed that error and fell through to
the failure message. The journal for that window contains **no brcmfmac lines at
all**, which is how it was caught. Corrected state of the diagnostic:

| Layer | Verdict |
|---|---|
| 1 — `nmcli con up` | genuinely tried, **failed** (association rejected 3×) |
| 2 — interface bounce | genuinely tried, **failed** |
| 3 — `brcmfmac` reload | **NEVER RAN** — untested, verdict void |

So NM-level and link-level recovery are ruled out. **Whether a driver reload
works is still open**, and it is now the question that decides whether W1 lives
above or below the driver. Fixed 2026-08-29 (`6c52b02`): the dependent is
removed first and every step reports, so "could not run" can never again read as
"ran and did not help".

⚠️ **Second defect from the same event:** the ladder took **264 s**, not the
"~30 s" this repo claimed — each `nmcli con up` burned its 90 s default. It
finished **88 s** before the plug fired. A plug cycle landing mid-ladder would
destroy the very diagnostic the ladder exists to produce. `nmcli -w 20` now
bounds it to ~60–90 s.

📌 **What the streak means for powersave.** 4.52 days of uptime versus roughly
one lockout every 4 h before it — `powersave=2` clearly *helped* and did not
*fix*. Keep it; stop treating 7 quiet days as the bar for "solved", because the
fault has now proven it can hide for 4.5.

**📊 2026-08-28 — `powersave=2` is now the prime suspect, and it is measurably
free.** 3.6 days with **zero** lockouts, zero ladder starts and zero plug
cycles, against **2 lockouts in 4 hours** the night before it went live. The
layered ladder has never fired on a real fault, so it has produced no layer
diagnostic — there has been nothing to diagnose.

Cost of keeping it, measured rather than assumed (Shelly counters, before vs
since):

| | Before | Since | Delta |
|---|---|---|---|
| Average draw | 1.489 W | 1.538 W | **+0.049 W (+3.3%)**, ≈0.43 kWh/year |
| Pi CPU temp | 41 °C | 45 °C | throttles at ~80 °C |
| Signal | -70 dBm / q40 | -67 dBm / q43 | improved |
| Icecast source | — | **unbroken since 24 Aug 23:13:45** | no stream drops |

⚠️ The "before" average includes hours when the host was *down* and drawing
nothing, so the real delta is if anything smaller.

**No functional downside found, and plausibly an improvement**: a sleeping radio
buffers frames between beacons, adding latency and jitter — the wrong behaviour
for a host whose job is streaming audio. The one reason to want powersave
(battery) does not apply; vinylstreamer is mains-fed through the Shelly.

🔴 **NOT proven yet — do not start removing the safety nets.** This item's own
history contains a **~5-day quiet stretch (17–21 Aug)** that ended with the
fault returning. 3.6 days has not beaten that. Revisit at **7+ quiet days**;
until then `wifi_reconnect.sh`, the plug watchdog and `autoconnect-retries=0`
all stay.

**What was reconsidered on 2026-08-28 and deliberately LEFT ALONE:**
* `autoconnect-retries=0` — disproven as a fix and now dormant, but harmless
  ("retry forever" is right for an unattended host when the AP genuinely goes
  away). Removing it would be churn. **It is not doing work; do not cite it as
  the fix.**
* Plug watchdog cooldown (6 h → 1 h) — the ordering still holds: software
  recovery acts first, the plug is third-line and rarely reached.
* Nothing to roll out elsewhere — vinylstreamer is the fleet's only Wi-Fi host.

**Changed:** `wifi_reconnect.sh` cron `*/2` → `*/5`. Polling hard for a fault
that has stopped is cost without information, and this script is the one
component here that has itself taken the host down. Detection now costs up to
~11 min (two observations + the ladder) against the plug's 15 — software
recovery must keep landing first, so **`*/10` would break that ordering** and
needs the plug threshold raised before it could be considered.

*State:* **root cause known; both NM knobs disproven; layered recovery live and
being measured.** Next evidence is which layer the alerts name.
*Needs:* nothing — read `#home-logging` for a few days.

```
Judge the W1 layered recovery from the evidence it is producing. Read
docs/TODO.md item 4 first — the diagnosis is DONE and the fix is DEPLOYED,
do not redo either and do not re-test the NM knobs (both disproven).

Read #home-logging for "vinylstreamer wifi recovered at layer N":
  layer 1 only  -> it was purely a NetworkManager give-up; consider retiring
                   the plug watchdog to a much longer threshold.
  layer 2 needed -> the link layer wedges, NM alone is not enough.
  layer 3 needed -> the DRIVER wedges. That reframes W1: the fault is below
                   NetworkManager and the brcmfmac/firmware angle becomes
                   primary.
  all layers fail -> the plug is still doing the work; escalate to hardware
                   (aerial, placement, or a USB wifi adapter).

🔴 DO NOT "improve" wifi_reconnect.sh by giving it a reachability-based
health check. The first version did exactly that, pinging a gateway that
answers no ICMP from inside VLAN 100 (firewall policy — it DOES answer from
other VLANs, so it looks fine when you test from a laptop), and reloaded the
driver every 2 min against a healthy
radio until the host fell over. If you change the health signal at all,
run the HEALTHY path on vinylstreamer itself and confirm it takes no
action, BEFORE any cron exists.

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

**18. dockassist's NIC stalls under the speedtest, nine times so far**
`bcmgenet` logs a transmit-queue hang whenever the link is driven flat out:

```
bcmgenet fd580000.ethernet eth0: NETDEV WATCHDOG: CPU: 1: transmit queue 0 timed out 2024 ms
```

⚠️ **Not one event — nine, and they are not random.** Every single one lands
1–6 minutes past an hour divisible by six:

```
Aug 11 00:03 · Aug 12 06:03 · Aug 12 18:04 · Aug 13 12:03 · Aug 14 00:06
Aug 16 06:01 · Aug 22 12:04 · Aug 22 18:06 · Aug 23 18:03
```

dockassist has exactly one 6-hourly cron: `0 */6 * * *`
`internet_speed_monitor --min-download=850 --min-upload=850 --tests=5
--delay=75` — five back-to-back saturation tests that hold the NIC at ~850+
Mbps for several minutes. **The stalls are load-induced by our own monitoring.**

📌 It is intermittent, not deterministic: the 2026-08-24 18:06 run produced no
stall. So this is "sustained line-rate sometimes wedges the queue", not "the
speedtest always breaks the NIC".

⚠️ **This was invisible until `read_agent` gained `systemd-journal` on
2026-08-24**, and it had been happening since at least 11 Aug. The detection
now exists (`check_nic_stalls.sh`, hourly, alerts on the delta), so the count
is no longer a thing nobody is watching.

🔗 **Related to items 1c/1d**, which are already about this speedtest's
dependency and what it measures. Worth deciding together: a bandwidth test that
wedges the NIC of the Home Assistant host is paying a real cost for its
measurement, and `--tests=5` may simply be more than is needed.

🔴 **Do not reach for `ethtool -K eth0 tso off` or similar.** The queue resets
itself and the link recovers, so the observed impact so far is a brief stall,
not an outage — a driver workaround would be a change with no way to tell
afterwards whether it helped.

*State:* cause identified 2026-08-24, detection deployed, **no fix applied and
possibly none needed** — the open question is whether to soften the speedtest.
*Effort:* small. *Needs:* a decision, then a laptop.

```
Decide what to do about dockassist's NIC stalls. Read docs/TODO.md item 18
first — the diagnosis is DONE, do not re-derive it. Nine bcmgenet NETDEV
WATCHDOG events since 11 Aug, every one 1-6 min into the `0 */6 * * *`
internet_speed_monitor run (5 saturation tests, ~850+ Mbps), intermittent
rather than every run. Detection already ships as check_nic_stalls.sh.

The question is NOT how to silence the driver. It is whether a bandwidth test
that occasionally wedges the Home Assistant host's NIC is worth its current
cost — consider fewer --tests, or folding this into the item 1c/1d decision
about what that speedtest is even measuring. Do NOT apply offload/driver
workarounds: the queue self-recovers, so there is no established harm to fix
and no way to prove a workaround helped.
```

**24. The public repo maps your wireless topology, including where PMF is off**
`docs/NETWORK.md` carries a full `SSID → Network → VLAN → L2 isolation → PMF`
table, plus a section headed *"The IoT SSID has protected management frames
disabled"* naming `estonoesmazagon_iot` explicitly. The repo is **PUBLIC**
(confirmed via `gh repo view` 2026-08-29).

📌 **Be precise about what is actually leaked**, because it decides how much of a
hurry this is:
- **SSID names** — broadcast in beacons. Discoverable by anyone in range, not a
  secret, and not worth pretending otherwise.
- **PMF disabled** — also advertised in RSN capabilities, so likewise
  discoverable on site.
- **VLAN mapping and L2 isolation posture** — **not** remotely discoverable.
  This is genuine internal topology disclosure.

So the cost is twofold: real disclosure of which VLAN holds what and where
isolation is absent, plus dropping reconnaissance from *"be in RF range and
analyse beacons"* to *"read GitHub"*. For a public portfolio repo belonging to
someone whose profession is platform security, it is the wrong artefact to carry.

⚠️ **Redacting HEAD does not unpublish it.** The table is in git history and in
any clone or fork. A history rewrite is possible but is its own decision with
its own costs, and it cannot recall what has already been read. That trade
should be made deliberately rather than assumed.

🔧 **Enabling PMF on the IoT SSID is the better fix and a separate one** — it
removes the weakness rather than hiding the note about it. Check what breaks
first; older IoT kit often cannot associate with PMF required.

*State:* diagnosed 2026-08-29 (promoted out of item 12, where it was one bullet
of fifteen). *Effort:* small to redact, larger to decide on history.
*Needs:* a laptop, and a decision from Ignacio on the history question.

```
Reduce what docs/NETWORK.md discloses. Read docs/TODO.md item 24 first — the
repo is public and the analysis of what is genuinely leaked versus merely
broadcast is already there, do not re-derive it.

Redact the VLAN/isolation columns and the PMF section from the tracked file;
SSID names alone are broadcast anyway, so the value is in the correlation and
the topology, not the names. Keep the operational detail somewhere Ignacio can
still read it — a vault-rendered doc or an untracked local file — because
NETWORK.md exists for a reason and blanking it helps nobody.

Then TELL HIM PLAINLY what redacting HEAD does and does not achieve: the table
remains in git history, in every clone and in any fork, so this narrows future
exposure only. Do not rewrite history without an explicit decision.

Do NOT change wireless config as part of this. Enabling PMF on the IoT SSID is
the better fix and belongs in its own change, after checking what fails.
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

- `CLAUDE.md` still says `deploy_monitoring.yml` deploys "monitoring scripts to
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
it lands. Start with the CLAUDE.md deploy_monitoring wording (it hid a
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

*State:* **fix is on `main`** (merged `d650d1d`, 2026-08-24) — the helper now
distinguishes "cannot read the file, run with sudo" from "key absent". Deployed
to dockassist. Open only because both branches have not been force-verified.

```
Verify the ha_state error-message fix on dockassist. Read docs/TODO.md item 19
first — the helper is NOT broken, it needs sudo, and the old message hid that.
Force BOTH branches as read_agent over SSH, not as choco:
  ssh dockassist-agent 'ha_state binary_sensor.vinylstreamer_online'
    -> must now say it cannot read the file and to use sudo
  ssh dockassist-agent 'sudo ha_state binary_sensor.vinylstreamer_online'
    -> must return JSON
Then point it at a real file with the key removed to confirm the "key absent"
branch still fires. A message that is merely reworded but never forced down
both paths has not been tested.
```


**22. `agent_read` returns gzip bytes for rotated logs instead of saying it cannot help**
Reading a rotated log through the agent helper returns the raw compressed file:

```
$ sudo agent_read log wifi_reconnect.log.2.gz
<binary gzip>
```

🐛 **The danger is that grep still "works".** A search over those bytes matches
nothing and returns `0` — which reads exactly like *"the event never happened"*
rather than *"this file is unreadable"*. Measured 2026-08-27 while answering
"has the W1 ladder ever fired?": the current log covered only ~15 h of a ~57 h
uptime because it rotates often, and the rotated `.gz` reported **0 ladder
starts**. Piping it through `gunzip` locally recovered the missing 25 hours —
which contained **8**. (They turned out to be a known self-inflicted burst, but
the tool had no way to tell me that; it just said zero.)

📌 **Same failure family as item 19**, and the third instance this month: a
tool built for the unattended tier that returns something *useless* rather than
refusing. The pattern is now explicit in `AGENT_INSTRUCTIONS.md` — the fix here
is one line of `zcat`, but the value is closing a silent blind spot in every
future investigation that reads history.

⚠️ **Any past investigation that read a rotated log through `agent_read` may
have concluded "nothing found" from unreadable bytes.** Worth remembering before
trusting an old negative result about anything older than a rotation.

*State:* diagnosed 2026-08-27, not fixed. *Effort:* small.
*Needs:* a laptop (edit `agent_read.sh.j2`, redeploy `agent_access.yml`).

```
Make agent_read handle rotated logs. Read docs/TODO.md item 22 first — this is
NOT "add a feature", it is closing a silent blind spot: today it cats .gz files
raw, so grep over them returns 0 matches and an investigation reads that as
"the event never happened".

In roles/agent_access/templates/agent_read.sh.j2, detect a .gz suffix and use
zcat/gunzip -c; leave plain files alone. Keep it read-only and keep the
existing path confinement — do not widen what it can open.

Verify by FORCING both branches as read_agent over SSH, not as choco:
  ssh vinylstreamer-agent 'sudo agent_read log wifi_reconnect.log.2.gz | head -3'
    -> must print readable timestamped lines, not binary
  ssh vinylstreamer-agent 'sudo agent_read log wifi_reconnect.log | head -3'
    -> must still work unchanged
Then grep the .gz for a string you KNOW is in it and confirm a non-zero count —
a reworded helper that was never grepped has not been tested.
```

**25. Nothing runs the CI lint locally, so a red pipeline stays red unnoticed**
`ansible-lint.yml` was red on **every push from 2026-08-18 to 2026-08-29** — 22
consecutive runs, always failing on the same step (`ShellCheck the test
harness`) and never on any other. Three findings, all introduced with test
files added over that window.

🐛 **The findings are not the problem — the eleven days are.** There is no
git hook, no `make lint`, no script that runs what CI runs. The only way to
learn the pipeline is broken is to open the Actions tab, and nothing prompts
that. This is the same shape as the `tests/unit/` suites that were red for
eleven days (see the header comment in `run_unit_tests.sh`): **a gate nobody
executes is not a gate.** Two instances of one bug class now.

⚠️ Note what did *not* happen: no alert, no digest, no failing-push warning.
The fleet's own monitoring pages Slack within minutes; the repo that manages
the fleet was silently broken for a week and a half.

*State:* **the three findings are fixed** (branch
`fix/ci-shellcheck-green-2026-08-29`) — shellcheck exits 0 on the exact CI
invocation and 11/11 unit suites pass. Open only for the recurrence gap.
*Laptop.*

```
Close the gap that let CI stay red for 11 days. Read docs/TODO.md item 25.
Add ONE local entrypoint — tests/lint.sh — that runs exactly what
.github/workflows/ansible-lint.yml runs for shellcheck, and change the
workflow to call that script instead of duplicating the invocation, so the
two cannot drift. Do NOT widen the file set: scripts/ is not clean yet and
the workflow comment says why.

Then decide whether it gets a pre-push hook or a GitHub notification setting
— pick one, do not build both. Verify by breaking a test file on purpose and
confirming the local entrypoint exits non-zero BEFORE the push, then fixing
it. A lint script that was never run against a known-bad file has not been
tested.
```

### 🧊 Blocked on Ignacio, not on work

**16. The Thread mesh has exactly one border router, and it is a roaming HomePod**
Needs a purchase decision. Every Matter-over-Thread device in the house reaches
HA through **one** device: the HomePod "Bano" (`40:ed:cf:4e:8e:03`), on Wi-Fi.
It is the only `_meshcop._udp` responder on the entire network.

On 2026-08-17 it was moved from the IoT SSID to `estonoesmazagon_novpn` to fix
AirPlay, and every Thread device dropped off HA for five days. dockassist now
holds a second IPv6-only Wi-Fi leg onto that VLAN, which **restores the path
but does not remove the dependency** — unplug the HomePod, move it again, or
change that SSID's key, and everything Thread goes dark exactly as before.

**Option (a): USB 802.15.4 dongle + OpenThread Border Router on dockassist**
(~€25). The mesh becomes local to the host that needs it: no Wi-Fi hop, no
VLAN, no HomePod, and it is Ansible-managed like everything else. It also makes
the mesh survive losing either router.

**Option (b): accept it**, and rely on item 15 to notice within minutes rather
than days. Cheaper, and honestly reasonable once 15 exists.

⚠️ **Verify before buying:** a second border router has to join the *existing*
Thread network, or the Eve sensors need re-commissioning. HA is understood to
be able to import Thread credentials from the Apple ecosystem via the companion
app — **this is unverified** and it is the whole basis of option (a) being
cheap. Check it first.

*State:* diagnosed 2026-08-22/23, mitigated not fixed. *Needs:* a decision from
Ignacio, then a laptop.

```
Decide the Thread border-router SPOF. Read docs/TODO.md item 16. FIRST verify
the claim the decision rests on: can Home Assistant import the Apple
ecosystem's Thread network credentials (companion app → HA Thread panel) so a
second OTBR joins the SAME mesh without re-commissioning the Eve sensors?
Answer that from Home Assistant's own documentation, and say plainly if it
cannot be confirmed. Only then price a USB 802.15.4 dongle that works with
OTBR on a Pi 4 and report both options back — do not buy anything.
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
