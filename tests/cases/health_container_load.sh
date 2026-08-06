#!/bin/sh
# Inside a container the load average is the HOST's, so it must be reported and
# never failed on.
#
# lxcfs is mounted over /proc/loadavg but Proxmox runs it without
# --enable-loadavg, so it passes cwwk's file straight through — while still
# virtualising /proc/cpuinfo. Measured 2026-08-06: CT 199, unifi-lxc and
# agent-lxc all read cwwk's load byte for byte, against core counts of 1, 1
# and 2 versus cwwk's 8. agent-lxc would therefore have reported a load failure
# whenever cwwk exceeded 10% utilisation.
#
# The precondition below is the real assertion: it proves the container still
# reads a host-scoped file. If lxcfs is ever configured to virtualise loadavg,
# this case fails loudly and the guard can be reconsidered — rather than
# quietly passing for the wrong reason.

. "$(dirname "$0")/../lib/harness.sh"

describe "container load is reported, not failed on"

assert_precondition "this target is a container" \
    sh -c 'systemd-detect-virt --container --quiet'
assert_precondition "/proc/loadavg is readable" test -r /proc/loadavg

run_uut scripts/common/system_health_check.sh

assert_exit_zero
assert_output_contains "host-wide"
assert_output_not_contains "❌ Load"

finish
