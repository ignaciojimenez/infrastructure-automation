# The workbench container

**What it is:** an always-on box on `cwwk` (CT 104, `10.30.40.207`) running an
interactive Claude Code session under `tmux`, reachable from the phone over
Remote Control. It is where code gets written when the laptop is shut.

**What it is not:** anything that can touch the fleet. See
[Deliberate absences](#deliberate-absences).

Built by [PER-66](https://linear.app/lacopadeeuropa/issue/PER-66). Operator
reference for `agent-lxc` is [AGENT_LXC.md](AGENT_LXC.md); this is its
counterpart for the box that writes rather than the one that watches.

---

## Two accounts, and why

| Account | Owns | Has |
|---|---|---|
| `choco` | this repo's convergence — monitoring in `~/.scripts`, `~/.logs` | full sudo, as on every fleet host |
| `builder` | dotfiles' home — shell, agent context, Claude Code, `~/Workspaces` | **no general sudo**; may control its own unit only |

They are split because **two systems converge this box's `$HOME` from git** and
their surfaces overlap: `~/.scripts` (monitoring vs dotfiles' user-bin dir),
`~/.config/opencode/AGENTS.md` (a templated file vs a symlink) and
`~/.local/bin`. Renaming any one of them fixes that one and leaves the next to
be discovered on a host, after deploy. Separate accounts remove the shared
namespace instead.

⚠️ **You will land as `choco` when you `ssh workbench`.** The agent runs as
`builder`, so anything about the session — auth, its config, its repos — needs
`sudo -u builder -H` or a direct `ssh builder@10.30.40.207`. This trips people
up once; it is the single most common source of confusion on this box.

---

## First-time setup: the one step Ansible cannot do

Everything else converges from `services.yml`. **Remote Control login does
not**, and cannot be made to.

The vaulted `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) authenticates
**API calls** — `claude -p 'hello'` works with it and nothing else, which is
what unattended builds need. It is **not** an account login. With it set and
working, `claude auth status` still reports `loggedIn: false`, and the session
shows *"Remote Control disconnected — /login"*. The account login requests
scope `user:sessions:claude_code`, which a setup-token credential does not
carry.

So Remote Control needs one browser round trip, **once per box** — not per
session, and it survives restarts and reboots:

```sh
ssh builder@workbench            # NOT choco — the session belongs to builder
claude auth login                # prints a URL, waits for a code
# open the URL in any browser, approve, paste the code back
sudo systemctl restart claude-remote-control
```

That last line works because `builder` is granted exactly four sudo commands,
all against its own unit. Before that grant existed this needed a second SSH
session as `choco`, which is precisely the friction it removes.

Confirm it took:

```sh
claude auth status               # expect loggedIn: true, authMethod: claude.ai
```

Then check the session is actually connected — **not just running**:

```sh
tmux capture-pane -p -t workbench | tail -5
```

A healthy pane shows the prompt. A pane showing `/rc failed` or *"Remote
Control disconnected"* means the login did not take.

---

## Why "running" is not "working" here

Three separate times this box looked healthy and was not:

1. **The theme picker.** Claude Code runs a first-launch TUI until
   `hasCompletedOnboarding` is set in `~/.claude.json`. Under systemd nobody
   answers it. The unit was `active`, the process was running, the health check
   said OK — and the session sat on a menu. The theme in `settings.json` does
   not suppress it; that flag is separate.
2. **The trust prompt.** Past the picker, the next launch stops on *"Is this a
   project you trust?"* — per-directory state under `projects`.
3. **No login.** Both gates passed, prompt reached, and Remote Control still
   refused because the account was not signed in.

Both config gates are now pre-answered by the role. The third cannot be.

📌 **The health check proves the process exists, not that the session is
usable.** `check_remote_control.sh` looks for a `claude` process owned by
`builder` and a tmux server hosting the session. All three failures above would
have passed it. Treat a green heartbeat as "the box is up", not "the phone can
reach it".

---

## Login noise you can ignore

Two cosmetic things on `ssh builder@workbench`, both stock Debian rather than
anything this repo does — checked against `cobra`, which behaves identically:

- **The Debian banner prints twice.** `/etc/pam.d/sshd` has two `pam_motd`
  lines: one for `/run/motd.dynamic` (the kernel line) and one for
  `/etc/motd` (the warranty text). Unrelated to the agent, which runs under
  systemd and never starts a login shell.
- **`tput: unknown terminal "xterm-ghostty"`.** Ghostty's terminfo is not in
  Debian 13's `ncurses-term`, which is already installed and does not carry
  it, so `.bashrc`'s colour probe fails. Harmless, and the session itself is
  unaffected.

  Zero-risk fix, laptop-side, in `~/.ssh/config`:

  ```
  Host workbench workbench-lxc 10.30.40.207
      SetEnv TERM=xterm-256color
  ```

  The alternative is shipping the entry to the fleet
  (`infocmp -x xterm-ghostty` exports ~4 KB), which would fix every host but is
  a change to every host — worth doing deliberately, not as a side effect of
  this container.

---

## Everyday operations

```sh
# health, as the check itself sees it
ssh workbench '~/.scripts/check_remote_control.sh'

# what the session is doing
ssh workbench 'sudo -u builder -H env HOME=/home/builder tmux capture-pane -p -t workbench | tail -20'

# attach to the very session the phone drives (as builder)
ssh builder@workbench -t 'tmux attach -t workbench'

# restart it
ssh builder@workbench 'sudo systemctl restart claude-remote-control'
```

Repos live in `/home/builder/Workspaces`, which is also the session's working
directory. Clone over **HTTPS** — the stored git credentials apply and this box
has no SSH key to GitHub by design.

---

## Deliberate absences

None of these are toggles to flip. They are the reason the box exists as a
separate thing:

- **No `read_agent` private key.** `primary_function: workbench` keeps it out
  of `group_vars/agent.yml`, the only place fleet access lives. Verified: SSH
  to `cwwk` is refused on an **open** port — the path exists, the credential
  does not.
- **No Ansible vault password.** It never leaves the laptop's Keychain.
- **No `pct` or hypervisor right.** It is a guest, not an operator.
- **No Secure-Enclave signing key.** Signed merges stay on the laptop, so
  nothing this box produces carries a human attestation.

`system/agent_access.yml` *does* run here — it runs on `hosts: all`. That is
intended and is not a hole: it templates an `authorized_keys` file and ships no
private key, so it gives `agent-lxc` a way **in** rather than giving this box a
way **out**.

🔴 The one change that would quietly undo all of it is giving this host
`primary_function: agent`, or adding it to a group that loads `agent.yml`.
Do not.
