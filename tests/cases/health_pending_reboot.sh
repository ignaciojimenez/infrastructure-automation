#!/bin/sh
# A pending reboot must be visible, and must become a failure once it is old.
#
# This check exists to make `auto_reboot: false` on cwwk a safe trade. Turning
# off the unattended 04:00 restart stops the hypervisor — and with it the
# OPNsense VM and the house's internet — rebooting itself unannounced. But a
# kernel security update only takes effect on reboot, so without a check the
# trade is an unannounced restart swapped for an *unnoticed unpatched kernel*,
# which is worse.
#
# ⚠️ Warning-only would have been the same mistake in a new costume, and this
# case exists mostly to pin that. A warning exits 0, the wrapper records
# SUCCESS, and the message goes to #home-logging — an unwatched firehose. It
# would be indistinguishable from having written no check at all. So the
# assertion that matters is not "it printed something", it is **the exit
# status**, in both directions:
#
#   fresh flag → visible in the output, still exit 0 (a to-do, not a page)
#   old flag   → exit non-zero (a fault)
#
# The age is faked by backdating the flag's mtime rather than by waiting seven
# days. The flag lives on tmpfs and is created by a package postinst, so its
# mtime is genuinely when the update landed — backdating it is the same input
# the real thing produces, not a test-only code path.

. "$(dirname "$0")/../lib/harness.sh"

FLAG=/run/reboot-required
PKGS=/run/reboot-required.pkgs

describe "a pending reboot is reported, and fails once it is stale"

cleanup() {
    rm -f "$FLAG" "$PKGS"
}

# A pre-existing flag would make the "no reboot pending" leg meaningless.
assert_precondition "no reboot is already pending on the rig" \
    sh -c "[ ! -f $FLAG ] && [ ! -f /var/run/reboot-required ]"

# ------------------------------------------------------------------
# Baseline: no flag at all
# ------------------------------------------------------------------
run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_output_contains "No reboot pending"

# ------------------------------------------------------------------
# A reboot pending right now — reported, but not yet a fault
# ------------------------------------------------------------------
: > "$FLAG"
printf 'linux-image-amd64\nlibc6\n' > "$PKGS"

run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_output_contains "Reboot pending"
# The package list is the difference between "reboot sometime" and "you are
# running an unpatched kernel". If it is dropped the check still passes its
# other assertions, so it needs its own.
assert_output_contains "linux-image-amd64"
assert_exit_zero

# ------------------------------------------------------------------
# The same flag, eight days old — now a failure
# ------------------------------------------------------------------
# 8 days back, against the script's 7-day threshold. `touch -d` is GNU; the
# rig is Debian, and this file never runs on FreeBSD.
touch -d '8 days ago' "$FLAG"

assert_precondition "the flag really is backdated past the threshold" \
    sh -c "[ $(( ( $(date +%s) - $(stat -c %Y $FLAG) ) / 86400 )) -ge 7 ]"

run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_output_contains "Reboot pending for 8 days"
assert_output_contains "ACTION REQUIRED"
assert_exit_nonzero

finish
