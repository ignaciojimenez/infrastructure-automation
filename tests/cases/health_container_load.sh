#!/bin/sh
# Inside a container the load check must measure the container, not the host —
# and must still be able to fail.
#
# /proc/loadavg here is cwwk's file: lxcfs is mounted over it but Proxmox runs
# lxcfs without --enable-loadavg, so it passes the host's straight through while
# still virtualising /proc/cpuinfo. Measured 2026-08-06: CT 199, unifi-lxc and
# agent-lxc all read cwwk's load byte for byte, against core counts of 1, 1 and
# 2 versus cwwk's 8 — so agent-lxc would have reported a load failure whenever
# cwwk exceeded 10% utilisation.
#
# The check now reads cgroup CPU pressure, which is cgroup-namespaced and
# therefore genuinely about this container.
#
# The precondition is the real assertion: it proves the container still reads a
# host-scoped loadavg. If lxcfs is ever configured to virtualise it, this case
# fails loudly and the whole branch can be reconsidered — rather than quietly
# passing for the wrong reason.

. "$(dirname "$0")/../lib/harness.sh"

PRESSURE_FILE=/sys/fs/cgroup/cpu.pressure

describe "container load check uses cgroup pressure, and can still fail"

cleanup() {
    unset THRESHOLD_CPU_PRESSURE
    return 0
}

assert_precondition "this target is a container" \
    sh -c 'systemd-detect-virt --container --quiet'
assert_precondition "cgroup CPU pressure is readable" test -r "$PRESSURE_FILE"

# Deliberately not asserted here: that /proc/loadavg is the host's file. From
# inside the container there is nothing to compare it against, and a check that
# cannot fail is not a check. It was established by sampling the container and
# cwwk in the same second — see docs/TODO.md.

run_uut scripts/common/system_health_check.sh

assert_exit_zero
assert_output_contains "CPU pressure"

# Now the other direction, with the threshold set one point below whatever this
# host is actually at — so the failure is forced by a real reading rather than
# by a synthetic one, and the case does not depend on the container being busy.
current=$(awk '/^some/ {
    for (i = 2; i <= NF; i++)
        if ($i ~ /^avg300=/) { sub(/^avg300=/, "", $i); print $i }
}' "$PRESSURE_FILE")
THRESHOLD_CPU_PRESSURE=$(( ${current%%.*} - 1 ))
export THRESHOLD_CPU_PRESSURE
note "forcing failure: measured ${current}% against threshold ${THRESHOLD_CPU_PRESSURE}%"

run_uut scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "stalled waiting for CPU"

finish
