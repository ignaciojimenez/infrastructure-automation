# Infrastructure TODO — open work

**Improvements and fixes waiting to be worked on.** Start at *What to work on
next*; the first item you can act on is the right one.

Updated: 2026-08-30

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

> **№1** 18 *(active fault, and it gates 1d)* → **№2** 30 *(the reported AirPlay
> fault)* → **№3** 31 *(PMF — the real fix behind the closed item 24)* →
> **№4** 1c → **№5** 1d *(only after 18)* → **№6** 2 → **№7** 4 (plex) →
> **№8** 9 → **№9** 3a/3b/3c → **№10** 5 → **№11** 19 → **№12** 12 →
> **№13** 22 → **№14** 10 → **№15** 11 → **№16** 6 → **№17** 7 →
> **№18–21** 8/13/14/16 · **№22** 32 *(git-history rewrite — decision only,
> default is no)* · **№23** 26 *(one UI toggle, global — his call)* ·
> **№24** 27 *(watch only — needs a fifth drop before it is work at all)* ·
> **№25** 29 *(latent — measured NOT to be the cause of the 30 Aug fault)*
> *(decision-gated — 16 needs a purchase call, 32 needs his call on a public
> force-push, the rest need him at the cabinet; not ranked)*

**24 closed 2026-08-30 and everything above it moves up one** — the redaction
shipped and the disclosure policy behind it is now
[a standing rule](ARCHITECTURE_DECISIONS.md#disclosure-tiering--what-goes-in-a-public-repo).
It left two successors, deliberately unequal: **31 enters at №3** — enabling PMF
is the change that actually removes the weakness, and it ranks below the two
active faults because nothing is currently exploiting it — while **32 sits at
№23**, a decision about git history whose default is *no*. Ranking them apart is
the point: the fix is work, the rewrite is tidiness.

**30 enters at №2 (2026-08-30)** — the reported fault, and the only one with a stated "rock solid for guests" bar. Item 28 closed the same day (`archive/DONE.md`). 29 drops to last: measured not to be the cause of anything.

**Re-ranked 2026-08-29 on the question "is 1c really the most important?"** —
it was not. **18 takes the top slot** because it is the only thing actively
recurring — nine NIC stalls since 11 Aug — and because it inverts the obvious
order: **1d doubles the saturation runs, so doing it before 18 would knowingly
make the active fault worse.** 1c is independent and stays ahead of 1d. Nothing
else was time-sensitive enough to move.




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

**31. PMF is disabled on the IoT SSID — the redaction moved the note, not the weakness**
Item 24 closed on 2026-08-30 by moving the SSID→VLAN→isolation→PMF correlation
out of `docs/NETWORK.md` and into `docs/local/WIRELESS.md` (see
[`archive/DONE.md`](archive/DONE.md)). That narrowed *remote* recon. It did
nothing to the underlying setting.

One SSID runs `pmf_mode=disabled`; the other four are `optional`. Without
802.11w, management frames are unauthenticated and clients can be
deauthenticated by anyone in range — the precondition for forced reassociation
and handshake capture. That SSID fronts the segment carrying the Shelly plugs,
the BroadLink blasters and the Tado bridge: **heating and mains power**.

📌 `pmf_mode` is advertised in the beacon's RSN capabilities. Anyone in RF range
reads it off the air whether or not it is written in a public repo — which is
exactly why redaction is not remediation here.

⚠️ **`disabled` is very likely deliberate**, not a slip. Cheap ESP32-class
devices often cannot associate with PMF enabled, which is the obvious reason
this one SSID differs. Treat it as a trade-off to re-confirm.

*State:* diagnosed, untouched. *Effort:* one controller toggle plus a watch
period. *Needs:* the UniFi controller, and a willingness to have IoT devices
drop off while testing. Which SSID it is: `docs/local/WIRELESS.md`.

```
Raise PMF from disabled to optional on the IoT SSID, and find out what breaks.
Read docs/TODO.md item 31 first, and docs/local/WIRELESS.md for which SSID it is
(it is gitignored and not in the repo). Do NOT re-derive the disclosure analysis
— item 24 is closed, the redaction is done, and redacting more is not the fix.

`optional` (not `required`) is the setting to try: PMF-incapable clients still
associate, capable ones get 802.11w. If even `optional` breaks associations,
that is the answer and the finding stands as an accepted trade-off — record it
and stop.

Before touching it, enumerate what is on that segment from Home Assistant so
there is a before-list to compare against: Shelly plugs and bulbs, the two
BroadLink RM4 blasters, the Tado bridge. After the change, watch for at least
24 h — ESP32 devices can associate once and drop later. A device that never
comes back is a rollback, not a puzzle.

This segment controls heating and mains power. Do it when someone is home and
can power-cycle a device, not remotely and not overnight.
```

**29. The mDNS repeater re-advertises IPv6 addresses that are unroutable from the VLAN it repeats into**
The repeater runs on all five VLANs and forwards records verbatim, so Baño's
record reaches VLAN 80 advertising a link-local `fe80::` and two ULAs that
VLAN 80 cannot reach — OPNsense carries no IPv6 routing. A *forced* connect to
the link-local **hangs 75 s** (the client treats `fe80::` as on-link and sends
neighbour solicitations into the void); the ULA fails instantly.

🔴 **Measured NOT to be the cause of anything observed.** Every real phone→Baño
flow on 30 Aug was IPv4 — Happy Eyeballs falls back. Latent defect only.

*State:* mechanism proven, no real client seen taking that path. *Needs:* a
reason to care. Do not act unless a capture shows a client actually stalling on
it — narrowing the repeater's interface list is the fix if one ever does.

```
Decide whether reflected unroutable IPv6 is worth acting on. Read docs/TODO.md
item 29 — the measurement is DONE and so is the follow-up question it used to
ask: a forced connect to Bano's reflected fe80:: hangs 75 s, BUT every real
phone->Bano flow on 30 Aug was IPv4, so Happy Eyeballs masks it. Do not re-run
either check.

This is latent, not an active fault. Act ONLY if a capture shows a real client
stalling on the link-local. If one ever does, the fix is to narrow the mDNS
repeater's interface list so Bano's records are not pushed onto VLANs that cannot
route to it. Do NOT add IPv6 routing to OPNsense for this.
```

**30. 🔴 AirPlay to Baño from the VPN SSID is unreliable — a setup race, not a blocked path**
The family normally uses the default (VPN) SSID on VLAN 80; Baño is on VLAN 20. Bar is
**rock solid for guests**. Audio is UDP, so the firewall log tells a session that
reached audio from one that died in setup:

| Window | Attempts | Reached audio |
|---|---|---|
| 29 Aug 18:24 → 30 Aug 16:52 | 8 | **1** |
| after rebooting Baño, 30 Aug 17:00 → 17:50 | 2 | **2** |

**Mechanism, from two packet captures:** Baño sends PTP before the phone has
bound its PTP socket; the phone answers `ICMP port 319/320 unreachable`, the
control connection is RST, the client retries. Sometimes a retry lands in the
right order.

🔴 **The reboot cleared state but did not remove the race** — the same ICMP
sequence fired again at 17:41:03, right after Baño booted. ⚠️ **2-in-2 over
50 minutes is not a baseline**; the prior rate was 1-in-8 over 24 h.

**Eliminated by measurement — do not re-test:** firewall rules (0 blocked
packets, ever), IPv6 (item 29), PTP-multicast (PTP runs *unicast* and crosses
fine), VPN policy routing (`USED_LAN_NETS` = `10.30.0.0/16`), low TTL (the only
TTL-1 packets are IGMP reports, correctly so).

*State:* five causes eliminated, race still present. *Needs:* a **counted
baseline over days of real use** — impressions cannot settle this.

```
Continue TODO item 30. Two captures and a session count are DONE — do not
re-derive them, and do NOT add firewall rules, igmpproxy or UDP relays: nothing
is blocked and unicast UDP crosses fine. Five causes are already eliminated.

Bano sends PTP before the phone's PTP socket is up; the phone answers ICMP
port 319/320 unreachable and the control connection is RST. Rebooting Bano took
it from 1-of-8 to 2-of-2, but the same sequence still fired post-reboot.

Get a counted baseline: classify phone <-> Music_Players flows in the OPNsense
filter log into sessions and report "N of M reached audio (UDP)". Cover hifipi
(10.30.40.100) as well as Bano. Report the rate over days, not impressions.

If it degrades again, capture (vlan0.20, host 10.30.20.52) and check whether the
ICMP-then-RST sequence repeats. If it does, routed AirPlay to this HomePod is
inherently racy and the fix is topological, not a rule — say so plainly.
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

**27. The new floor lamp drops off Wi-Fi — watch only, do not act on a hunch**
`light.floor_lamp_new` — Shelly Duo Bulb G3 `48f6eebd40d4`, `10.30.100.238` on
VLAN 100 — loses its RPC session and takes its five entities `unavailable` with
it. Four occurrences in the retained HA log: 2026-08-17 01:53 and 02:34,
2026-08-18 10:53, 2026-08-29 23:07. Every one self-recovered; only the last
outran the 15-minute grace and paged #home-alerts (23:30, exit 5). Signature is
always the same pair — `aioshelly.rpc_device.wsrpc: Invalid Message from host
10.30.100.238:80` then `Error fetching … while reconnecting`.

📌 **Do not touch `ha_entity_health_grace_seconds` for this.** The 29 Aug outage
lasted ~30 minutes; 15 minutes is the correct window and it worked. This is a
device fault, not a threshold problem, and nothing else in HA logged a single
line in the same 90 minutes — the network was fine.

🔴 **This item is a threshold for acting, not a task.** Four self-healing drops
in 13 days do not justify changing anything, and the failure mode to avoid here
is fixing a bulb that is not broken. See *&ldquo;the floor lamp that switched
itself on&rdquo;* in [`archive/DONE.md`](archive/DONE.md) for what was already
settled — including that `sys.reset_reason` is undocumented and must not be
reasoned from.

*State:* diagnosed 2026-08-30, nothing broken, nothing to build.
*Effort:* none until it recurs. *Needs:* a fifth drop, or a longer one.

```
Investigate the floor-lamp Shelly drops — ONLY if a fifth has happened. Read
docs/TODO.md item 27 and the DONE.md entry "2026-08-30 — the floor lamp that
switched itself on, and an alert that was simply true" first (three entries
share that date, so match the title, not the date);
the 29 Aug alert was TRUE, the check behaved correctly, and initial_state is
already fixed. Do not re-derive any of that, and do not "fix" this by widening
any grace window.

First confirm there IS a new event rather than assuming:
  ssh dockassist-agent "sudo docker logs --since <date> home-assistant 2>&1 \
    | grep -E '48f6eebd40d4|10\.30\.100\.238'"
No new pair of lines means nothing to do — say so and stop.

If there is one: RSSI was -58 on ch 1 with roam rssi_thr -80 (healthy) on
30 Aug, so re-measure it and suspect the AP or DHCP before the bulb. Firmware
is 2.0.0 and the only thing on offer is 2.0.1-beta1 — do not put a beta on it
to chase log lines. Do not reason about reset_reason: the field is real (it
read 1) but Shelly does not document the value mapping.
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

**16. The Thread mesh has exactly one border router, and it is a roaming HomePod**
Needs a purchase decision. Every Matter-over-Thread device in the house reaches
HA through **one** device: the HomePod "Bano" (MAC in `docs/local/WIRELESS.md`),
on Wi-Fi.
It is the only `_meshcop._udp` responder on the entire network.

On 2026-08-17 it was moved from the IoT SSID to the no-VPN SSID (VLAN 20) to fix
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
that concrete rather than theoretical. Weigh it against item 31 — the only action
here that removes the weakness rather than the description of it.

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

Do NOT start a rewrite on your own judgment, and do NOT treat it as a
prerequisite for item 31 — they are independent.
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
