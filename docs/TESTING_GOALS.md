# What the test environment is for

**Four goals. Three were the reason the disposable container was built; the
fourth is what actually got built first.** Written 2026-08-18, after a green,
well-tested rig turned out not to be the thing that had been asked for.

📌 **Why this file exists.** None of these goals were written down. So nothing
ever contradicted anything, drift was invisible, and the gap only surfaced when
Ignacio blocked a merge and asked. **A goal that is not written down cannot be
missed — it can only be forgotten.** Add to this file before building, not after.

> Companion docs: [TEST_CONTAINER.md](TEST_CONTAINER.md) is *how* to create and
> destroy the containers. [`tests/README.md`](../tests/README.md) is *how* to run
> the suite. This file is *why any of it exists*, and is the one to read first.

---

## Goal 1 — Run real playbooks against a host that is created and destroyed

**So that** any agent or human asked to change something for a Debian host can
prove the change converges before it reaches a fleet host, and **so that**
`bootstrap.yml` — the one playbook that by definition cannot be tested on an
already-bootstrapped host — is testable at all.

**Status: ~70% built.** What exists is good and was nearly lost to a
documentation error (see TEST_CONTAINER.md).

| Built | |
|---|---|
| Create **and destroy** | `tests/provision_test_container.sh` (`--destroy`), idempotent; refuses to destroy anything not named like a test container |
| A real test inventory | `ansible/inventory/test_hosts.yml` — connects **as the infrastructure user over sudo**, not root, so every `become` path is genuinely exercised; `is_test_environment: true`; dead Slack tokens so a rig can never page a real channel; overrides at host level with the precedence reasoning recorded |
| Two OS targets | CT 199 (Debian 13 — twin of the LXCs) and CT 198 (Debian 12 — proxy for the four Pis). Chosen on **OS release, not CPU**: that is where a POSIX shell script actually trips |
| The bootstrap path | `TEST_CT_BARE=1` leaves the container with root and nothing else, the only state in which bootstrap's user-creation branch runs |

| Missing | |
|---|---|
| **`bootstrap.yml` and a full `site.yml` have never been run against a container** | Only `deploy_monitoring.yml` and `services.yml --tags ssh` have converged. The playbook this goal most exists for is the one least tested. |
| No one-command loop | create → converge → verify → destroy is a manual sequence today |
| Not in CI | `.github/workflows/` runs `ansible-lint` only |
| No `--create` in the sandbox | a fresh container still needs `ssh cwwk` and a Touch ID tap |

## Goal 2 — A quick throwaway host to try something on

**So that** "I want to poke at this" never means poking at `dockassist`.

**Status: done.** `tests/sandbox.sh` — `--shell`, `--root`, `--deb12`, `--push`
(working tree, uncommitted included, no Ansible and no vault), `--run`,
`--reset`, `--status`. Only gap is the shared one: creating a fresh container
still needs the Proxmox host.

## Goal 3 — agent-lxc tests its own proposed fixes end to end

**So that** the fleet observer can go from *"here is a plan"* to *"here is a
change I ran against an ephemeral copy and watched work"*.

**Status: 0%, and blocked on four independent axes — every one of them a
deliberate safety decision, not an oversight.**

| Blocker | Where |
|---|---|
| `read_agent` may run `pct list`/`status`/`config` and **nothing else** — no `create`, `destroy` or `exec` | `roles/agent_access/templates/sudoers_debian.j2` |
| OpenCode denies `edit`/`write`; `bash` is restricted to `ssh *-agent *` | agent role config; `docs/AGENT_LXC.md` — *"The agent never writes to any host; that is structural."* |
| **The vault password is macOS Keychain.** `bin/vault_pass.sh` is `security find-generic-password`, a command that does not exist on Linux — so no vault-touching playbook can run on agent-lxc at all | `bin/vault_pass.sh` |
| No repo clone on the container | — |

### ✅ DECIDED 2026-08-18 — option (a): the agent proposes, a human runs

**The agent writes the change and the test; a human triggers the ephemeral run.**
No new grants: no `pct create/destroy/exec`, no Linux-reachable vault.

**Because** the two halves of full autonomy have very different prices. Scoped
`pct` on the 198/199 range is a narrow, arguably reasonable grant. **A
Linux-reachable vault path is not** — it moves the fleet's secrets from "behind
a Touch ID prompt on one laptop" to "readable by a long-running network service
that executes model output". That is the exposure, and it buys only the removal
of a human tap.

**Reassess when** goal 1's one-command loop exists and has been used enough to
know whether the tap is actually the bottleneck. Until then the tap is cheap and
the blast radius is the point.

🛑 **Do not quietly widen this.** Adding `pct exec` "just to check something", or
committing a vault password to make a playbook run on the container, re-opens
this decision without anyone deciding it. If the tap becomes the bottleneck, say
so and re-decide in this file.

## Goal 4 — Regression-test the monitoring scripts (the unplanned one)

**So that** a check cannot silently lose the ability to fail. This is what
`tests/run_tests.sh` and `tests/cases/` are, and it is the only goal with a
finished, green implementation.

It was not on the original list, and it earned its place: it exists because
`system_health_check.sh` printed a red ❌ and exited `0` on all seven hosts for
its entire life. **Printing an error and reporting one are different things**,
and only forcing the condition tells them apart.

**Status: done and green** — 10/10 on CT 199, cases arrange as root and exercise
as the unprivileged user. See [`tests/README.md`](../tests/README.md).

---

## The rule this file encodes

**A test rig is only as good as the question it answers, and the question has to
be written down.** Goal 4 was built well and reviewed carefully; nobody noticed
it was answering a different question from the one that motivated the container,
because the motivating questions lived only in Ignacio's head.

So: **before building test infrastructure, add the goal here.** If the work in
front of you does not map to a goal in this file, that is the finding — say so
before writing the code.
