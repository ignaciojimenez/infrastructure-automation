# Tests

Behavioural tests for the monitoring scripts, run against a **disposable Debian
LXC** — never against a fleet host.

```sh
tests/run_tests.sh --target 10.30.40.205            # all cases
tests/run_tests.sh --target 10.30.40.205 --case disk --verbose
```

Create the target with:

```sh
ssh cwwk 'sh -s' < tests/provision_test_container.sh
```

and destroy it with the same script and `-- --destroy`. See
[docs/TEST_CONTAINER.md](../docs/TEST_CONTAINER.md) for what each setting is
for. The runner refuses to run against a host that is not named `testlxc`.

## ⚠️ What this suite cannot see

It connects as **root**, because the cases fill disks and stop services. The
fleet's checks run as the infrastructure user under cron. So any fault that only
appears to an unprivileged user is invisible to every case here.

That is not hypothetical. On 2026-08-04, on CT 199, the same script in the same
minute:

```
as choco : ❌ Upgrade log not found - unattended-upgrades may not be configured
as root  : ✅ Last upgrade: 2026-08-04
```

`/var/log/unattended-upgrades/` is `root:adm 0750` and the infrastructure user is
not in `adm` on three of seven fleet hosts. A real bug, and this suite reports
green on it.

When a check reads a file it does not own, verify with
`tests/sandbox.sh --run <script>`, which connects as the infrastructure user.

## Trying something by hand

The suite above is batch. When you are part-way through a change and just want
to poke at it on something that behaves like a fleet host, use the sandbox:

```sh
tests/sandbox.sh                       # shell in, as the infrastructure user
tests/sandbox.sh --push                # copy the working tree's scripts over
tests/sandbox.sh --run system_health_check.sh
tests/sandbox.sh --status
tests/sandbox.sh --reset               # back to baseline when you've made a mess
tests/sandbox.sh --deb12               # any of the above against CT 198
tests/sandbox.sh --root                # as root, for the bootstrap path
```

`--push` copies what is in your working tree *right now*, uncommitted included,
without going through Ansible. That is deliberate: no playbook, no vault, no
commit — the file is on the box in a second so you can run it. Use the playbooks
when you want to test the deploy; use this when you want to test the script.

`--reset` is a soft reset — scripts, logs, crontab, `/etc/monitoring`, the
package set. A true rebuild needs `pct` on the Proxmox host, so it stays a
`provision_test_container.sh` job.

## Running playbooks against them

`ansible/inventory/test_hosts.yml` describes both containers, connecting as the
infrastructure user over sudo exactly as the fleet is reached:

```sh
ansible-playbook -i ansible/inventory/test_hosts.yml \
    ansible/playbooks/deploy_monitoring.yml
```

`deploy_monitoring.yml`, `services.yml --tags monitoring` and
`services.yml --tags ssh` all converge. `bootstrap.yml` and a full `site.yml`
have not been run against a container yet. See "Running playbooks against it" in
[docs/TEST_CONTAINER.md](../docs/TEST_CONTAINER.md) for how hardening is
prevented from locking the rig out of itself.

Host-independent checks live in `tests/unit/` and need no container at all:

```sh
tests/unit/slack_watermark_test.sh
```

## What this suite is for

One thing only: **proving a check reports the fault it detects.**

The 2026-08-03 incident was not caused by a check failing to notice a problem.
`system_health_check.sh` noticed everything it was asked to — it printed a red
❌ for each one — and then exited `0`, so `enhanced_monitoring_wrapper` recorded
SUCCESS and no alert was ever sent. On seven hosts. Since the script was
written.

The lesson generalises: *detecting* and *reporting* are separate, and only
reporting is observable from outside. A check that prints an error and returns
success is indistinguishable, to everything downstream, from a healthy host.

So every case here follows the same shape:

1. **Force the real fault** — fill a real disk, stop a real service, break real
   DNS. No stubs, no mocks, no `--test` flag.
2. **Assert the exit status**, not just the output. Output assertions are
   secondary; they only confirm the right fault was found.
3. **Assert the precondition first.** A full-disk test on a disk that never
   filled proves nothing, so `assert_precondition` aborts the case rather than
   letting it pass vacuously.
4. **Include the healthy baseline.** A script rewritten to `exit 1`
   unconditionally would pass every failure case in this suite. `health_baseline`
   is what makes the others mean something.

## Why a container and not stubs

A stubbed `df` proves the parser handles the string you handed it. It cannot
prove the script behaves on the dash-and-Debian environment it actually runs
in, and it cannot catch the class of bug where a `df | grep | while` pipeline
silently discards its counters in a subshell. That bug is invisible to every
form of testing except a genuinely full disk.

Forcing these conditions on `dockassist` or `cobra` is not an option — filling
a production disk to test a disk check causes a worse outage than the one being
guarded against. Hence a container that gets destroyed afterwards.

## Writing a case

```sh
#!/bin/sh
. "$(dirname "$0")/../lib/harness.sh"

describe "what must be true"

cleanup() { : ; }          # always runs, even if the case aborts

# ... arrange the fault ...
assert_precondition "the fault is real" some-command

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "expected message"

finish
```

Drop it in `tests/cases/`. The runner picks it up by glob.

Available assertions: `assert_exit_zero`, `assert_exit_nonzero`,
`assert_output_contains`, `assert_output_not_contains`, `assert_precondition`.

**Restore what you break.** `cleanup` runs on every exit path. Never break
anything that would sever the SSH session the case is running over — the
connectivity case breaks DNS rather than removing the default route for exactly
this reason.
