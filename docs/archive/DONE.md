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

## Smaller closed items

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
