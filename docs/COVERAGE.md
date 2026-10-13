# Monitoring coverage — what tells you, and how fast

Audit of **2026-10-12** (PER-18, `docs/TODO.md` item 10). Every fix of the August
sprint was a check that existed and did not work. This audit looks for the other
class: **failure modes nothing watches**. It starts from what each host exists to
do, never from the checks that exist, and its deliverable is the blanks. Nothing
was fixed while writing it.

**Scope.** Reliability: things breaking, stopping or decaying. Gaps in *security*
detection (who changed what, intrusion signals) are out of scope here. A public
list of those is a target list, so it would belong in `docs/local/`
(ARCHITECTURE_DECISIONS.md § Disclosure tiering).

**Reading the verdicts.**
- ✅ an alert reaches `#home-alerts` (the watched channel) within the stated time.
- ⚠️ something notices, but slowly, indirectly, or only in an unwatched place:
  `#home-logging`, email, or a log nobody reads.
- ❌ nothing notices.

## Before the tables: the delivery path itself

Every ✅ below assumes the alert is *delivered and seen*. Three facts qualify that.

| Path | Status |
|---|---|
| Wrapper → Slack webhooks | ✅ failures to `#home-alerts`. A failed send is retried on the next run (PER-60). Successes and recoveries go to `#home-logging`, which nobody watches (see TODO 12, "recovery routing") |
| healthchecks.io → you | ✅ DOWN and UP notifications post to `#home-alerts` through its Slack integration, for both projects: **Core** (WAN, DNS, "OPNsense monitoring alive", HA, `proxmox-critical-health`, the Tier 1 sweep) and **Backups**. Checked 2026-10-13 against the channel's history (real DOWN posts for WAN, DNS, HA and backups in August) and the Core check list read over the API |
| Tier 1 sweep → Linear → builder | ✅ for failed units, disk and stale monitoring on the 8 swept hosts, hourly, and it also posts to Slack |

Blank 0 (where healthchecks.io's alerts go) was answered on 2026-10-13: `#home-alerts`.
Every "healthchecks.io" in the tables means "you are told".

## The blanks, ranked

| # | Blank | Why it matters | Seeded? |
|---|---|---|---|
| ~~0~~ | ~~Where healthchecks.io alerts go~~ | Answered 2026-10-13: `#home-alerts`, both projects | closed |
| 1 | **Backup restorability.** Freshness is watched. Nothing ever decrypts and opens a real `do_backup` tarball (HA, UniFi, opnsense, Plex), and the quarterly vzdump restore test last ran 2026-03-30, so Q3 is overdue | A backup that cannot be restored is found out on the worst day | seeded |
| 2 | **OPNsense firmware / plugin updates** | Nothing anywhere. The 26.1.9 upgrade that deleted `read_agent` went unnoticed for 3 months | seeded |
| 3 | **cwwk's own mail** (PVE update and job notices to `root@pam`) | Postfix defers to iCloud on a blocked :25 for ~41 h, then drops. Invisible end to end | seeded |
| 4 | **Role-owned script drift** | `deploy_monitoring.yml` syncs only `scripts/common/`. A role's own checks change only when that role is deployed; hifipi's rotted for 4 months. Nothing compares deployed and repo | seeded |
| 5 | **cloudflared** (remote access to Home Assistant) | A stopped container is now checked (deployed 2026-10-13). A tunnel that runs and does not connect is still invisible. Away from home, the app reaches HA through it, so presence decays too, slowly and attributed elsewhere | new |
| 6 | **Network gear: APs, switch, links between them** | The UniFi controller is not read by anything (its API is unreadable to this repo). An AP down shows only as the hosts behind it going quiet. A backbone port that renegotiates to 10M-half is caught only for links a host terminates (link-speed check) | new |
| 7 | **Updates not arriving** | Pending reboots fail after 7 days ✅. But nothing says whether unattended-upgrades *ran*, or whether a source still updates. Example: unifi-lxc's Ubiquiti source failed Debian 13's key policy for a month (fixed 2026-10-13, PER-105), and only a `site.yml` run noticed. | new |
| 8 | **Raw template copies shipped as live scripts** | `deploy_monitoring.yml` copies `scripts/common/heartbeat_backup.sh` unrendered (literal `{{ … }}`) to every host's `~/.scripts`. It's never scheduled, so harmless today, but the drift check in #4 would have to know it's dead | new (found while auditing) |

## Per host

### opnsense — the internet, DNS and the VPN exits

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| WAN down | healthchecks.io WAN heartbeat (*/5) stops; gateway check | ~5–15 min | ✅ |
| DNS resolution broken | `check_dns_health` */5, DNS failover monitor every minute, healthchecks.io DNS heartbeat | 1–5 min | ✅ |
| A Mullvad exit dies / Spotify-class refusal | `check_wg`, `check_vpn_gateway` */10–15; agent-lxc Mullvad relay signal on change | 10–60 min | ✅ |
| Box hung or VM stopped | cwwk `check_vm_status` */15; WAN heartbeat stops | ~15 min | ✅ |
| One process pegs a core (the 2026-08-07 class) | `check_runaway.sh` (PER-10; forced on cwwk 2026-10-13, alert reached `#home-alerts`) | 30 min | ✅ |
| Disk / memory | `check_system_health.sh` */30; Tier 1 over the API | 30–60 min | ✅ |
| Its own cron stops | healthchecks.io "monitoring alive" */5 | ~5 min | ✅ |
| Config backup stops or rots | backup freshness heartbeat; restorability never tested | hours / never | ⚠️ / ❌ (blank 1) |
| Firmware, plugin updates | nothing | — | ❌ (blank 2) |

### cwwk — hypervisor for everything else

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| A guest stops | `check_vm_status` */15, Tier 1 CT/VM state | 15 min | ✅ |
| ZFS degraded | `check_zfs_health` hourly, Tier 1 zpool | ≤1 h | ✅ |
| Disk failing (SMART) | `check_smart_health` daily | ≤1 day | ✅ |
| Overheating | `check_thermal` */5 | 5 min | ✅ |
| Runaway process | `check_runaway.sh` (`kvm` is ignored by design, so a runaway *inside* a guest is caught by that guest's own check) | 30 min | ✅ |
| Kernel errors, crash dumps | checks */30 and hourly | ≤1 h | ✅ |
| Nightly vzdump fails | Proxmox job status goes to `root@pam` mail, which never arrives | never | ❌ (blank 3) |
| USB recovery sync stops | sync wrapper + freshness heartbeat | ≤1 day | ✅ / ⚠️ |
| Host dead | everything stops: healthchecks.io for the opnsense WAN/DNS heartbeats (the firewall is a guest) | ~5 min | ✅ |
| PVE updates pending | mail to `root@pam` | never | ❌ (blank 3) |

### dockassist — Home Assistant: heating, presence, HomeKit

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| HA container down | container check */10, healthchecks.io HA heartbeat | 10 min | ✅ |
| HA up but integrations dead | entity health */10 (unavailable vs off) | 10–30 min | ✅ |
| HomeKit bridge stops advertising (the 2-day Apple Home outage) | advertisement check */15 | 15 min | ✅ |
| A phone's presence freezes | presence health */30, probes the phone first | 30 min+ | ✅ |
| MQTT broker / Matter server down | container checks */10 | 10 min | ✅ |
| Remote access tunnel container stopped | container check */10 (deployed 2026-10-13) | 10 min | ✅ |
| Tunnel running but not connected | nothing | — | ❌ (blank 5) |
| NIC stalls | hourly stall check | ≤1 h | ✅ |
| HA backup stops / is unrestorable | freshness heartbeat / never tested | hours / never | ⚠️ / ❌ (blank 1) |

### cobra — Plex, downloads, the media share

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| Plex / Samba / Transmission down | service checks hourly, critical services */15 | ≤1 h | ✅ |
| Share browsable by IP but not by name (`nmbd`, the 4-day outage) | `nmbd` is a critical service */15 | 15 min | ✅ |
| Transmission leaks outside the VPN | VPN connection check hourly | ≤1 h | ✅ |
| External drive unmounted or full | mount and quota checks hourly | ≤1 h | ✅ |
| Disk failing (SMART) | daily SMART | ≤1 day | ✅ |
| Plex config backup unrestorable | never tested | never | ❌ (blank 1) |

### hifipi — music playback (MPD, AirPlay, Spotify)

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| A player service down | service checks hourly, with restart | ≤1 h | ✅ |
| Spotify refuses the egress IP | raspotify check names the 403 (PER-62, **pending deploy**) | ≤1 h | ✅ once deployed |
| MQTT outage blocks raspotify starting | fixed at the source (PER-62, pending deploy) | — | — |
| No audio output device | daily audio output check | ≤1 day | ✅ |
| SD card wear → read-only root | indirect: monitoring goes stale, Tier 1 flags it | ~1–2 h | ⚠️ |

### vinylstreamer — the record player's stream

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| Stream down | streaming monitor */10 | 10 min | ✅ |
| Wifi lockout | `wifi_reconnect.sh` recovers */2; HA plug watchdog power-cycles after 15 min **continuous** offline, which a flapping link defeats (PER-61, held) | minutes / ⚠️ | ⚠️ |
| Root disk full | quota check hourly | ≤1 h | ✅ |

### unifi-lxc — the network controller

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| Controller service / web UI down | checks */13, */15 with restart | 15 min | ✅ |
| An apt source starts failing (as Ubiquiti's key did until PER-105, 2026-10-13) | nothing, until a `site.yml` run stops at the cache task | — | ❌ (blank 7) |
| Backup unrestorable | vzdump restore tested 2026-03-30; the `.unf` backup never | quarterly / never | ⚠️ (blank 1) |
| An AP or switch down | nothing reads the controller | — | ❌ (blank 6) |

### agent-lxc — the monitoring brain

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| The sweep stops | its own healthchecks.io heartbeat | ~1 h | ✅ |
| Tier 2 / filer fails | wrapper alerts on failure | next run | ✅ |
| Container down | cwwk `check_vm_status` | 15 min | ✅ |

### workbench-lxc — phone sessions and the builder

| Failure mode | What tells you | How fast | |
|---|---|---|---|
| Remote Control session gone | liveness check | ≤1 h | ✅ |
| Builder breaks / isolation regresses | failed unit → Tier 1 → Linear and Slack | ≤1 h | ✅ |

## Next

Blank 1 next (the item said so, and Q3's restore test is overdue). Each blank becomes a
Linear issue only when it has an action.
