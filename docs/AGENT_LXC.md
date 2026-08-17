# Agent LXC — Fleet Observer & Investigator

An always-on, read-only container (`agent-lxc`, CT 103, `10.30.40.203`) that watches the
whole fleet, and — when something breaks — investigates it and writes a remediation plan a
human reviews. It is a **diagnostic layer on top of** the existing per-host
`enhanced_monitoring_wrapper` + healthchecks.io alerting, not a replacement.

Design rationale for every choice below is in [ARCHITECTURE_DECISIONS.md](ARCHITECTURE_DECISIONS.md)
(§ Agent LXC). This doc is the operator's reference: what runs, what you get, and how to run it.

---

## The three-tier model

Capability is split across three modes, each with its **own credential** so the blast radius
of the always-on box stays at read-only:

| Tier | What | Credential | Cost |
|---|---|---|---|
| **1 — Monitor** | Hourly shell sweep of all 7 hosts | container key → `read_agent` (read-only) | free |
| **2 — Investigate** | On anomaly / Slack alert / weekly: correlate, explain, write a plan | same read-only key + a spend-capped `ANTHROPIC_API_KEY` | ~$2/mo (see Cost) |
| **3 — Operate** | Execute a reviewed plan, step-by-step, with per-command approval | *separate* passphrase-protected admin key, only while a human is present | — |

**Tier 3 is not built** (Phase C). Tiers 1 and 2 are live. The agent never writes to any host;
that is structural (its account is read-only and OpenCode denies `edit`/`write`).

---

## What runs, when

All on `agent-lxc`, via cron:

| When | Job | Spends? | Output |
|---|---|---|---|
| Hourly **:37** | `fleet_health_check.sh` (Tier 1 sweep) | never | On a finding: `#home-alerts` + writes `~/.agent/last_anomaly.json` |
| Hourly **:47** | `investigate.sh` (anomaly) | only if the sweep flagged something *new* | `#home-alerts`: summary + plan file |
| Hourly **:07** | `investigate.sh --slack` | only on a *new* distinct `#home-alerts` failure | `#home-alerts`: summary + plan file |
| Sundays **09:17** | `investigate.sh --digest` | weekly | `#home-logging`: fleet-health summary + plan file |

The three Tier-2 jobs share a **`flock`**, so they never run concurrently (which would saturate
the 1-CPU/2GB box). Each exits immediately and free when there is nothing new to do.

**Tier 1 checks**, per host: reachable, disk under threshold, no failed systemd units, its own
monitoring ran recently (via the cron journal). Plus on `cwwk`: zpool health and onboot-aware
VM/CT state. On `opnsense`: disk and default route. It **DNS-pre-checks** first — if the
gateway resolver is down it reports *that*, rather than blaming all 7 hosts.

**Slack watch** exists because Tier 1 only sees what `read_agent` sees; per-service wrapper
failures and Home Assistant alerts (heating offline, Shelly, etc.) appear only in `#home-alerts`.
The watcher reads that channel, filters to genuine failure alerts (excluding its own posts and
noise), and investigates **new** ones — content-deduped so a nightly-recurring failure produces
one plan a week, not one a night.

---

## What you get, and how to act on it

Every investigation produces two things:

1. A **plan file** at `~/.agent/plans/<date>-<slug>.md` on the box, with a fixed structure:
   *What is wrong · Evidence (real commands + output) · Cause (with confidence) · **Preconditions**
   · Proposed fix · Risk · Rollback.*
2. A **Slack summary** to `#home-alerts` (or `#home-logging` for the digest) — severity-first,
   a few sentences, with the plan path and the run's cost.

**To act on a plan:**
- Read the summary in Slack; open the full plan on the box if you want the evidence.
- **Re-check the Preconditions first** — a plan may be hours old and the condition may have
  cleared or changed. The block lists runnable checks; if they no longer hold, don't run the fix.
- The Proposed fix is a numbered list of individually-runnable commands, least-invasive first.
  You run them (this is Tier 2 — the agent never does). Severity `non-issue` / "None — monitor
  only" means there is nothing to do; that is a valid, useful outcome.

**Expected quality** (from real runs): actionable bugs with the exact fix (e.g. a check that
hardcodes `amixer 'Master'` on a card whose control is `DAC`); real fixes proposed (a backup
that tars a live SQLite DB → snapshot it first); and — importantly — an honest *"I can't confirm
this"* when the agent lacks access, with specific next steps, instead of a guess.

---

## Cost

- **Healthy fleet ≈ the weekly digest only, ~$2/month.** Tier 1 and the anomaly/Slack triggers
  are free when nothing is wrong.
- **Each genuinely-new problem: ~$0.30–0.55, once** (Sonnet 5), then content-deduped for 7 days.
  Fix the recurring cause and its cost goes to zero.
- Per-run cost is logged (`run cost: $…`) and posted in each Slack summary.
- The `ANTHROPIC_API_KEY` lives in its own Console workspace with a **spend limit** — this box
  can never consume the main budget and is revocable in one click.

Tuning levers if you want it cheaper: raise `agent_slack_dedup_days`, lower the model, or drop
effort. The model is a per-agent variable (`agent_monitor_model` in `group_vars/agent.yml`).

---

## Security model

- **Read-only by construction.** The agent's account (`read_agent`) has only read-only sudo, and
  OpenCode denies `edit`/`write`/`webfetch` and restricts `bash` to `ssh *-agent *` plus a few
  local reads. The bash glob is a coarse filter, not the boundary — the real constraint is the
  **key**: `from=10.30.40.203` pinned, read-only account, revocable fleet-wide in one Ansible run.
- **Permissions fail closed.** Headless, a denied action auto-rejects (there is no `--auto`);
  verified live.
- **The agent never handles secrets.** The Slack read token and HA monitor token stay in trusted
  scripts / host-side helpers; the agent only ever gets handed alert text and reads state through
  a GET-only `ha_state` helper.
- **Scoped-read helpers** (`agent_read`, `ha_state`) are root-owned, name-validated (traversal-
  proof), and give the agent read access to monitoring logs/scripts and HA entity state without
  exposing the rest of the 0700 home or any credential.
- **Compensating control:** every use of the container key is recorded in each host's sshd
  journal (source IP + key fingerprint, persistently). The key is intentionally *not* Slack-
  alerted (it sweeps hourly; alerting would flood the channel and mask the laptop key's alerts).
- **opnsense is the exception, and holds a second credential.** The firewall is read over its
  HTTPS API with a scoped, API-only key/secret — no SSH key, no shell, independently revocable,
  TLS pinned to the firewall's own certificate. Nothing here SSHes into the gateway, which is
  what retires the CrowdSec self-ban that caused the 2026-08-03 outage. Full reference:
  [`OPNSENSE_API.md`](OPNSENSE_API.md).

**Retirement is one line:** remove the container's entry from `agent_access_keys`
(`roles/agent_access/defaults/main.yml`), re-run `agent_access.yml`, and the key is dead
fleet-wide. Destroy the container with `pct destroy 103` on `cwwk`.

---

## Operating it

**Deploy / update:**
```bash
# Provision the container (idempotent; only cwwk)
ansible-playbook ansible/playbooks/provision_agent_lxc.yml
# Onboard through the standard pipeline
ansible-playbook ansible/playbooks/bootstrap.yml --limit agent-lxc
ansible-playbook ansible/playbooks/site.yml     --limit agent-lxc
# Deploy the container key fleet-wide (Tier 1 access)
ansible-playbook ansible/playbooks/system/agent_access.yml
# Update just the agent role (config, scripts, models)
ansible-playbook ansible/playbooks/services.yml --limit agent-lxc --tags agent
```

**Tune** (in `ansible/inventory/group_vars/agent.yml`, redeploy with the `--tags agent` line):
`agent_monitor_model` / `agent_digest_model` (the LLM), `agent_slack_dedup_days`,
`agent_slack_max_per_run`, the cron minutes, `agent_disk_threshold`.

**Enable/disable Tier 2:** `enable_agent_investigate` (needs `vault_anthropic_api_key`). Slack
watch additionally needs `vault_slack_read_token`; without it the cron isn't even created.

**Trigger on demand** (e.g. from your phone over the VPN): `ssh agent-lxc "~/.scripts/investigate.sh --digest"`.

**Troubleshoot:** logs are in `~/.logs/fleet_health_check.log` and `~/.logs/investigate.log` on
the box. `~/.agent/` holds `last_anomaly.json`, `plans/`, the dedup markers, and the Slack
watermark.

---

## Known limits & gotchas

- **The 0700 home is only partly open.** `agent_read` exposes `.logs`/`.scripts`; everything else
  under `/home/choco` (secrets, `.ssh`, tokens) stays invisible by design.
- **`read_agent` on OPNsense is fragile** — firmware upgrades wipe the account; recovery is
  `agent_access.yml --limit opnsense`. See ARCHITECTURE_DECISIONS § Agent Access.
- **OpenCode occasionally doesn't exit** after finishing; the `timeout` wrapper handles it, but a
  hung run shows as a `timeout` failure alert.
- **Do not run investigations concurrently by hand** — the box is 1-CPU/2GB and will thrash; the
  `flock` protects the crons, but a manual parallel run bypasses nothing if you launch two.
- **Rebuild-from-scratch is not yet "vault-password-only"** — a rebuild regenerates the agent's
  SSH key, whose pubkey must be re-committed and pushed. Tracked in TODO.md with two options
  (accept-and-document vs. vault the keypair); decide before testing a real rebuild.
