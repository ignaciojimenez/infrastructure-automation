# Reading opnsense over its API

The Tier 1 fleet sweep checks every host over SSH as `read_agent`. It checks
**opnsense over HTTPS instead**, and this document is why, plus how to recreate
the credential when it is lost.

Operator reference for `agent-lxc`; see [AGENT_LXC.md](AGENT_LXC.md) for the
sweep as a whole.

---

## Why not SSH, given every other host uses it

Twice, `read_agent` on opnsense stopped having a usable shell. Not because
anything broke — because OPNsense rewrites every non-admin account's shell to
`/usr/sbin/nologin` whenever it regenerates users from `config.xml`. That is
one line of intentional policy:

```php
/* src/etc/inc/auth.inc:351 */
$user_shell = $is_admin && !empty($user['shell']) ? $user['shell'] : '/usr/sbin/nologin';
```

So a shell for a read-only account on this box is not a thing that can be
granted once. It is on loan, and the firmware decides when to call it in.

Two responses were considered and **both are refused**:

1. **`pw usermod read_agent -s /bin/sh`** — withdrawn 2026-08-14. It writes
   only to `/etc/passwd`, outside the model OPNsense regenerates from, so it
   un-fixes itself at an unpredictable time; and it overrides an intentional
   control on the internet SPOF, reachable with a passphrase-free key.
2. **Dropping opnsense from the sweep** — rejected 2026-08-14, on the grounds
   that "opnsense already reports its own disk and routes". It does, from crons
   that only run while opnsense is well. **"Host X already checks this" is not
   redundancy when X checking it depends on X being well.**

The API needs no login shell at all, so there is nothing left for an account
regeneration to take away. It also retires a risk class rather than backing off
from it: the 2026-08-03 outage happened because failed SSH auth against the
gateway reads to CrowdSec as a brute-force, and the gateway then banned the
container off its own network. Nothing in the opnsense check authenticates over
SSH.

---

## What is checked, and which privilege carries it

| Check | Endpoint | Privilege that grants it |
|---|---|---|
| Root filesystem usage | `GET /api/diagnostics/system/system_disk` | `page-system-login-logout` — *Lobby: Dashboard* |
| Default route present | `GET /api/diagnostics/interface/get_routes` | `page-diagnostics-routingtables` — *Diagnostics: Routing tables* |
| 🔴 Its own monitoring still runs — **NOT LIVE, see below** | `POST /api/diagnostics/log/core/system` | `page-diagnostics-logs-system` — *Diagnostics: Logs: System* |

Those mappings are read out of OPNsense's own ACL definitions, not inferred:
`src/opnsense/mvc/app/models/OPNsense/Core/ACL/ACL.xml` and
`.../Diagnostics/ACL/ACL.xml` in `opnsense/core`.

### Why the third row exists, and why it needed a change on the firewall too

`check_wrapper_freshness` reads the systemd journal, so it ran for the `linux`
and `proxmox` kinds only. Nothing in this fleet noticed if the **firewall's**
own monitoring stopped running — the exact failure the sweep exists to catch,
unwatched on the host least eligible for a blind spot.

🐛 **The obvious implementation does not work, and only measurement showed it.**
On Linux the evidence is cron's own syslog record of every `CMD` it runs.
**FreeBSD's cron does not log job executions at all.** Searched the firewall's
entire system log for `cron` on 2026-08-17: five hits, all of them the *service*
starting at boot, months apart. Nothing about jobs.

The intended fix is for the wrapper to announce itself instead of relying on
cron — `logger -p daemon.notice -t infra_wrapper "…"`, guarded to FreeBSD in
`scripts/common/enhanced_monitoring_wrapper` so it is a no-op on every Linux
host. That marker would be **stronger evidence than the Linux side has**: it
proves the wrapper reached that line, not merely that cron tried to start
something.

🔴 **It does not work yet, and this row of the table is not live.** Three probes
were sent from a shell on the firewall — two tags, one with an explicit
priority — and **none arrived in `core/system`**, while `sudo`, `dhclient`,
`kernel` and `opnsense` messages arrive there continuously. `core/cron` and
`core/monit` both return 403 (no ACL entry covers them).

Two source-derived theories were formed and both were killed by measurement:
that the catch-all destination would take an unclaimed tag, and that the tag
`monitoring` was being swallowed by `filter f_local_monit { program("monit"); }`
via syslog-ng's unanchored `program()` matching. Both mechanisms are real; a
provably non-colliding tag still did not arrive.

**Unverified lead:** the source is `unix-dgram("/var/run/log" flags(syslog-protocol))`
— syslog-ng expecting RFC5424 while FreeBSD's `logger(1)` emits RFC3164. It does
not obviously explain why `sudo` arrives, so it is a lead, not an answer.
See `docs/TODO.md` §L-H for the command that settles it.

📌 **The lesson, earned three times in one session: source explains mechanisms,
it does not report state.**

### The snake_case trap

opnsense/core **#9093** and **#8918** both report privilege-restricted API users
getting 403 on diagnostics endpoints. The cause is not privilege depth, it is
naming. ACL patterns are matched with `fnmatch`-style globbing
(`models/OPNsense/Core/ACL.php`, `urlMatch`), and the patterns were converted to
snake_case in core commit `128094e1` (2025-07-08, shipped in 25.7) while the
old camelCase URLs kept working. So:

- `api/diagnostics/interface/get_routes*` matches `get_routes`, **not** `getRoutes`
- a trailing `/*` also matches the flat URL — `urlMatch` rewrites
  `([/&?])\.\*$` into `($1.*)?` — which is why
  `api/diagnostics/log/core/system/*` grants the flat `POST .../system`

**Use the snake_case URL.** The camelCase alias needs `page-all` and there is
no reason to reach for it.

---

## Creating the credential

⚠️ **This is the one step with no CLI.** OPNsense core ships no command to
create a user or mint an API key — verified against the source tree, not
assumed. The MVC `OPNsense\Auth\User` model could be driven from a PHP script
on the box, but writing `config.xml` from a hand-rolled script on the internet
SPOF is a worse trade than four clicks, once.

**System → Access → Users → +**

| Field | Value | Why |
|---|---|---|
| Username | `sweep_api` | |
| Password | leave empty, tick *Generate a scrambled password…* | no local database login |
| Login shell | leave default | `auth.inc:351` gives it `nologin` anyway |
| **Authorized keys** | **leave empty** | the whole point: this account has no SSH path |
| Group memberships | none | never `admins` |
| Effective Privileges | the three above, plus *System: Deny config write* | |

*System: Deny config write* (`user-config-readonly`) is belt-and-braces:
`write_config()` refuses and logs for a user holding it (`src/etc/inc/config.inc:206`).
⚠️ That check keys off `$_SESSION['Username']`; **it is not verified here that
it applies on the API-key path**, so treat it as defence in depth, not as the
control that makes this account safe. The control that does that is the
privilege list — none of the three grants a write endpoint.

Then reopen the user, **API keys → +**. A `apikey.txt` downloads **once**; the
secret is stored `crypt($secret, '$6$')` and cannot be read back
(`Auth/FieldTypes/ApiKeyField.php`).

Put the two values into the vault:

```sh
ansible-vault edit ansible/inventory/group_vars/all/vault.yml
#   vault_opnsense_api_key: "<key>"
#   vault_opnsense_api_secret: "<secret>"

ansible-playbook ansible/playbooks/services.yml --limit agent-lxc --tags opnsense
```

### ✅ The privilege gate, measured on OPNsense 26.1.9 (2026-08-17)

**Scoped privileges are sufficient. `page-all` is not needed.** All three
endpoints return 200 for a user holding only the four privileges above, and a
control endpoint outside them (`api/diagnostics/firewall/pf_statistics/…`)
returns 403 — so the 200s are the privileges working, not the check being
toothless.

⚠️ **Read the 403s carefully if you re-run this.** A first pass showed
`get_routes` 403 while the other two returned 200, which looks exactly like the
per-endpoint ACL defect #9093 describes. It was not. The firewall's own log
carries the disambiguating evidence:

```
2026-08-17T01:28:12 [opnsense] pluginctl: plugins_configure user_changed (1,sweep_api)
```

The privilege had not been saved yet at the time of the first measurement. Both
`get_routes` **and** the legacy `getRoutes` were 403 in that pass, which was the
tell — a naming defect would have let the snake_case form through.

📌 **Worth keeping: on this box a 403 means the privilege is absent, full stop.**
It is not evidence of #9093, and adding `page-all` to "work around" it would
have quietly granted broad rights to fix a missing tickbox.

### If broad privilege turns out to be the only option

Not the case here, but if a future firmware regresses: the answer is still to
build
this, as **a separate API-only user with no SSH key**. That is not the decision
refused for the shell: that refusal was about `read_agent`, which *holds* an SSH
key, so granting it `page-all` would hand it a real interactive shell via
`auth.inc:351`. An API-only user cannot use the shell that privilege implies —
the path is HTTPS-only and the credential is independently revocable.

---

## TLS is verified, not waved through

The firewall serves a self-signed certificate. The sweep pins it rather than
passing `-k`:

```sh
curl --cacert <pinned cert> --resolve OPNsense.internal:443:10.30.40.254 \
     https://OPNsense.internal/api/...
```

`--resolve` supplies the name the certificate actually carries — its only SAN is
`DNS:OPNsense.internal` — while the connection still goes to the IP. That has a
second payoff: **the check that watches the firewall does not depend on the
firewall's resolver.** When Unbound is down the rest of the sweep is skipped
(names would all fail), and opnsense is still checked.

`-k` was rejected: it accepts any certificate from anything that can ARP-spoof
VLAN 40, on the one host holding a firewall credential.

🔴 **The pinned certificate expires 2026-11-04.** When OPNsense replaces it,
every API call fails `curl` exit 60 and the sweep reports a TLS finding that
names the file to re-pin. Re-pin with:

```sh
openssl s_client -connect 10.30.40.254:443 -servername OPNsense.internal </dev/null 2>/dev/null \
  | openssl x509 > ansible/roles/services/agent/files/opnsense-web.crt
```

---

## Reading a failure

Every distinction below was measured against this firewall on 2026-08-17, not
taken from a manual.

| Symptom | Means |
|---|---|
| `HTTP 302` | The call carried **no usable credential at all**. OPNsense answers unauthenticated API calls with a redirect to the login page, not a 401. |
| `HTTP 401` | Key/secret **rejected** — revoked, regenerated, or the account is disabled. Body is `{"status":401,"message":"Authentication Failed"}`. |
| `HTTP 403` | Authenticated, **not authorised**. A privilege is missing, or a camelCase URL crept in. Reported per endpoint, never collapsed — "disk reads but routes are forbidden" is a real distinction. |
| `curl exit 60` | TLS verification failed: the served certificate no longer matches the pinned one. |
| `curl exit 77` | The pinned certificate file is missing or unreadable on the container. |
| `curl exit 6/7/28` | No answer. Treated as **host down**, so it joins the fleet-wide silence collapse rather than reading as a firewall fault. |

⚠️ **Two traps encoded in the client, both load-bearing:**

- **No `--location`.** With `-L` the 302 is followed and returns `200` plus an
  HTML login form, so a revoked credential would read as healthy.
- **`200` alone is not enough, and neither is "the body is JSON".** The 401 body
  *is* valid JSON. Only requiring **`200` and a JSON body** catches both cases.

Credentials go to `curl` as a config file on **stdin** (`curl -K -`), never in
argv — every process on the container can read `/proc/*/cmdline`.
