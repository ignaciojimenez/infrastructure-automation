#!/bin/sh
# An announced maintenance window suppresses the alert for the service it
# names — and nothing else, and not past its deadline.
#
# The laptop unit test (tests/unit/maintenance_window_test.sh) stubs systemctl
# and covers the boundaries exhaustively. This case exists for what a stub
# cannot show: a really stopped unit, on a real Debian host, read by the real
# `dash` — where `${line%% *}` and `[ "$now" -le "$deadline" ]` either work or
# do not. macOS /bin/sh is bash in POSIX mode and forgives things dash does not.
#
# The fault being reproduced: cobra, 2026-08-15 04:00. backup_plex_config stops
# plexmediaserver for ~22 s and the health check sampled the gap.
#
# 🔴 The load-bearing step is step 2 — the same stopped service with NO window
# must still fail. Everything else here is only safe because that one holds.

. "$(dirname "$0")/../lib/harness.sh"

describe "an announced maintenance window suppresses only what it names"

MW_DIR=/var/tmp/uut-maintenance

cleanup() {
    systemctl start cron >/dev/null 2>&1 || true
    rm -rf "$MW_DIR"
}

# cron rather than plexmediaserver: the container has no Plex, and the check is
# service-agnostic — the unit name is a variable in both the marker path and
# CRITICAL_SERVICES. Testing the mechanism on a unit the host actually has is
# what keeps this case from being a fiction about a service that isn't there.
export CRITICAL_SERVICES="cron"
export MAINTENANCE_DIR="$MW_DIR"
export SERVICE_RECHECK_ATTEMPTS=2 SERVICE_RECHECK_DELAY=1
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=2 NETWORK_PROBE_RETRY_DELAY=0

# World-readable: written here as root, read by the unprivileged account that
# cron actually runs the check as. On the fleet both are the same user and the
# directory is 0700 in their home; here they differ, and a case that failed on
# permissions would look exactly like a case that failed on logic.
rm -rf "$MW_DIR"
mkdir -p "$MW_DIR"
chmod 755 "$MW_DIR"

# ---------------------------------------------------------------------------
# 1. Baseline, with cron running. Whatever else this host reports, it reports
#    it in every step below too — so this status, not 0, is what "unchanged"
#    means here.
# ---------------------------------------------------------------------------
assert_precondition "cron is running" systemctl is-active --quiet cron
run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
baseline_status="$_uut_status"
note "baseline exit status with everything healthy: $baseline_status"

# ---------------------------------------------------------------------------
# 2. 🔴 THE REAL FAILURE, FORCED. cron genuinely stopped, no window anywhere.
#    This must fail exactly as it did before maintenance windows existed. If
#    this step ever passes quietly, the check has been lobotomised and every
#    other assertion in this file is worthless.
# ---------------------------------------------------------------------------
systemctl stop cron >/dev/null 2>&1
assert_precondition "cron is stopped" sh -c '! systemctl is-active --quiet cron'

run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_exit_nonzero
assert_output_contains "Service cron: not running"
assert_output_not_contains "announced maintenance window"

# ---------------------------------------------------------------------------
# 3. Same stopped service, window open → warned, not charged. The line is still
#    printed: suppression is not silence.
# ---------------------------------------------------------------------------
printf '%s backup_plex_config pid=%s\n' "$(( $(date +%s) + 300 ))" "$$" > "$MW_DIR/cron"
run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_exit_equals "$baseline_status"
assert_output_contains "announced maintenance window"
assert_output_contains "Service cron: not running"

# ---------------------------------------------------------------------------
# 4. A window for a different unit must not cover this one.
# ---------------------------------------------------------------------------
rm -f "$MW_DIR/cron"
printf '%s some other job\n' "$(( $(date +%s) + 300 ))" > "$MW_DIR/plexmediaserver"
run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_exit_nonzero
assert_output_not_contains "announced maintenance window"

# ---------------------------------------------------------------------------
# 5. 🔴 An expired window must not suppress — and must be reported as the
#    worse fault it is: a job that stopped a service and never restarted it.
# ---------------------------------------------------------------------------
rm -f "$MW_DIR/plexmediaserver"
printf '%s backup_plex_config pid=%s\n' "$(( $(date +%s) - 60 ))" "$$" > "$MW_DIR/cron"
run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh
assert_exit_nonzero
assert_output_contains "EXPIRED maintenance window"

finish
