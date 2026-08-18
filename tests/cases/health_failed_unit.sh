#!/bin/sh
# A failed systemd unit must produce a non-zero exit.
#
# Nothing in the fleet checked `systemctl --failed` before 2026-08. CT 103 sat
# with 19 failed units — journald among them, which is why a 12-day outage went
# unrecorded — and passed every check it had.

. "$(dirname "$0")/../lib/harness.sh"

UNIT=test-failing-unit.service
UNIT_PATH="/etc/systemd/system/$UNIT"

describe "failed systemd unit fails the check"

cleanup() {
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

cat > "$UNIT_PATH" <<'EOF'
[Unit]
Description=Deliberately failing unit (infrastructure-automation test suite)

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'exit 1'
EOF

systemctl daemon-reload
systemctl start "$UNIT" >/dev/null 2>&1

assert_precondition "the unit is in a failed state" \
    sh -c "systemctl list-units --failed --no-legend | grep -q $UNIT"

run_uut_as "$INFRA_USER" scripts/common/system_health_check.sh

assert_exit_nonzero
assert_output_contains "failed unit"

finish
