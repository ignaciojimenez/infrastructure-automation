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
