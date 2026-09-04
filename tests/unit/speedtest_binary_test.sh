#!/bin/sh
# Regression test: internet_speed_monitor must refuse a `speedtest` that is not
# Ookla's, and must pin the server it was told to pin.
#
# Runs on the laptop — no network, no real speedtest. `speedtest` is stubbed on
# PATH in two shapes, and the stub records the argv it was handed so the
# assertions can check what the script actually PASSED rather than what it
# parsed.
#
#   tests/unit/speedtest_binary_test.sh
#
# The harness is POSIX sh (run_unit_tests.sh invokes every case with `sh`,
# regardless of shebang, and CI's sh is dash). The script UNDER test is bash,
# and so are the stubs — they carry their own bash shebang and are executed,
# not sourced, so nothing bash-only leaks into this file. Verified under dash.
#
# The bug this pins (docs/TODO.md item 1c): `speedtest` resolves to a DIFFERENT
# PROGRAM depending on the host. Debian's `speedtest-cli` package ships
# /usr/bin/speedtest too — a separate Python project that prints plausible Mbps
# and takes none of the same flags. The old guard was
# `command -v speedtest >/dev/null` — presence only. On a host with the wrong
# one that guard passes, and the script then produces numbers that are not
# comparable with anything else recorded. Case 1 is the one that matters:
# if it ever goes green, the guard has gone back to proving nothing.
#
# Case 3 exists because item 1d's whole design rests on it. Ookla picks a server
# relative to the EGRESS, so once the VPN path is measured too, an unpinned test
# would choose relative to the Mullvad exit and the direct one relative to
# Odido — then report the difference as "VPN slowness". Asserting that the flag
# was PARSED would not catch a script that parsed it and never passed it on,
# which is why this checks the recorded argv.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/internet_speed_monitor"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── internet_speed_monitor: binary identity and server pinning\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"
ARGV_LOG="$WORK/argv.log"

# ------------------------------------------------------------------
# Stubs. Version strings are copied from the real binaries:
#   dockassist  → Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Linux/aarch64-...
#   speedtest-cli 2.1.3 is Debian's, whose --version prints just the number.
# ------------------------------------------------------------------
make_ookla_stub() {
    cat > "$WORK/bin/speedtest" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
if [[ "\$*" == *--version* ]]; then
    echo "Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Linux/aarch64-linux-musl"
    exit 0
fi
# One log line then the result line, which is the real CLI's shape — the script
# greps for type="result" precisely because the log lines are there too.
echo '{"type":"log","message":"starting"}'
echo '{"type":"result","download":{"bandwidth":117000000},"upload":{"bandwidth":117000000},"ping":{"latency":4.1},"server":{"name":"Odido","location":"Amsterdam"},"isp":"Odido"}'
STUB
    chmod +x "$WORK/bin/speedtest"
}

make_debian_stub() {
    cat > "$WORK/bin/speedtest" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
if [[ "\$*" == *--version* ]]; then
    echo "speedtest-cli 2.1.3"
    exit 0
fi
echo "ERROR: unrecognized arguments" >&2
exit 2
STUB
    chmod +x "$WORK/bin/speedtest"
}

# ==================================================================
# CASE 1 — the wrong speedtest must be REFUSED (the case that matters)
# ==================================================================
: > "$ARGV_LOG"
make_debian_stub

out=$("$SCRIPT" --tests=1 --delay=0 2>&1); rc=$?

if [ "$rc" -eq 2 ]; then
    pass "Debian speedtest-cli on PATH → exit 2"
else
    fail "Debian speedtest-cli on PATH → expected exit 2, got $rc"
fi

if printf '%s' "$out" | grep -q "is not Ookla's CLI"; then
    pass "names the actual problem (wrong binary, not 'not installed')"
else
    fail "error message does not identify the wrong binary; got: $(printf '%s' "$out" | head -2)"
fi

# The point of failing early is not running the test at all. If it went ahead
# and invoked the impostor, the guard bought nothing.
if ! grep -q -- '--format=json' "$ARGV_LOG"; then
    pass "aborted before invoking the wrong binary for a measurement"
else
    fail "ran a measurement against the wrong binary anyway"
fi

# ==================================================================
# CASE 2 — Ookla's speedtest is accepted and measures
# ==================================================================
: > "$ARGV_LOG"
make_ookla_stub

out=$("$SCRIPT" --tests=2 --delay=0 --min-download=100 --min-upload=100 --max-ping=50 2>&1); rc=$?

if [ "$rc" -eq 0 ]; then
    pass "Ookla speedtest on PATH → exit 0"
else
    fail "Ookla speedtest on PATH → expected exit 0, got $rc; output: $(printf '%s' "$out" | tail -3)"
fi

# 117000000 bytes/s * 8 / 1e6 = 936.00 Mbps. Assert the VALUE the parse yields,
# not merely that the script was happy: a parse that silently produced 0 would
# also "pass" a threshold check written the other way round.
if printf '%s' "$out" | grep -q '936.00'; then
    pass "parsed bandwidth to the expected 936.00 Mbps"
else
    fail "expected 936.00 Mbps from the fixture; got: $(printf '%s' "$out" | grep -i mbps | head -1)"
fi

# ==================================================================
# CASE 3 — --server-id must reach the binary, not just be parsed
# ==================================================================
: > "$ARGV_LOG"
make_ookla_stub

"$SCRIPT" --tests=2 --delay=0 --min-download=100 --min-upload=100 --max-ping=50 \
    --server-id=52365 >/dev/null 2>&1

if grep -v -- '--version' "$ARGV_LOG" | grep -q -- '--server-id=52365'; then
    pass "--server-id=52365 is passed through to the binary"
else
    fail "--server-id never reached the binary; argv was: $(grep -v -- '--version' "$ARGV_LOG" | head -1)"
fi

# ==================================================================
# CASE 4 — unset --server-id must pass NO such argument
# ==================================================================
# An empty `--server-id=` is not the same as omitting it: Ookla's CLI rejects
# the empty form, so a naive string-concatenation build of the command line
# would break every host that does not pin a server. That is the majority of
# them, and the default.
: > "$ARGV_LOG"
make_ookla_stub

"$SCRIPT" --tests=2 --delay=0 --min-download=100 --min-upload=100 --max-ping=50 \
    >/dev/null 2>&1

if grep -v -- '--version' "$ARGV_LOG" | grep -q -- '--server-id'; then
    fail "passed a --server-id argument when none was configured: $(grep -v -- '--version' "$ARGV_LOG" | head -1)"
else
    pass "no --server-id argument when unset"
fi

# ==================================================================
# CASE 5 — the configured test count must survive one flaky test
# ==================================================================
# This is the case that caught the sizing bug on 2026-09-05. The script exits 2
# unless at least TWO tests succeed — a hardcoded floor, because it reports a
# median and a median of one sample rejects nothing. So the configured count is
# not just a cost dial: it sets how many transient failures the run tolerates.
#
# At the 5 this check used to run, three could fail. The first cut proposed 2,
# which tolerates NONE — one flaky test and the whole run exits 2 and pages
# #home-alerts. That is a check that manufactures its own false alerts, which
# is the specific failure this repo keeps paying for.
#
# So: assert the PRODUCTION value from group_vars survives one failure, and
# read that value from the file rather than hardcoding it here — a test that
# pins 3 while production quietly moves to 2 guards nothing.
GROUP_VARS="$REPO_ROOT/ansible/inventory/group_vars/homeassistant.yml"
configured=$(grep -E '^internet_speed_tests:' "$GROUP_VARS" | awk '{print $2}')

if [ -z "$configured" ]; then
    fail "could not read internet_speed_tests from $GROUP_VARS"
else
    : > "$ARGV_LOG"
    # A stub that fails its FIRST measurement and succeeds afterwards.
    cat > "$WORK/bin/speedtest" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
if [[ "\$*" == *--version* ]]; then
    echo "Speedtest by Ookla 1.2.0.84 (ea6b6773cf) Linux/aarch64-linux-musl"
    exit 0
fi
runs=\$(grep -c -- '--format=json' "$ARGV_LOG")
if [ "\$runs" -le 1 ]; then
    echo "Cannot connect to server" >&2
    exit 1
fi
echo '{"type":"result","download":{"bandwidth":117000000},"upload":{"bandwidth":117000000},"ping":{"latency":4.1},"server":{"name":"Odido","location":"Amsterdam"},"isp":"Odido"}'
STUB
    chmod +x "$WORK/bin/speedtest"

    out=$("$SCRIPT" --tests="$configured" --delay=0 --min-download=100 \
        --min-upload=100 --max-ping=50 2>&1); rc=$?

    if [ "$rc" -eq 0 ]; then
        pass "configured --tests=$configured survives one failed test"
    else
        fail "configured --tests=$configured cannot absorb a single transient failure (exit $rc) — raise internet_speed_tests; the script needs 2 SUCCESSES"
    fi
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   ALL PASS\n\n'
    exit 0
fi
printf '   %d FAILED\n\n' "$failures"
exit 1
