#!/bin/sh
# Minimal POSIX test harness for the monitoring scripts.
#
# Sourced by each case in tests/cases/. Runs *on the target container*, not on
# the laptop — these tests exist to observe real behaviour (a real full disk, a
# really stopped service), so there is nothing to stub.
#
# A case looks like:
#
#   . "$(dirname "$0")/../lib/harness.sh"
#   describe "disk above threshold is reported as a failure"
#   cleanup() { rm -f /var/tmp/ballast; }
#   arrange  ... make the condition true ...
#   run_uut scripts/common/system_health_check.sh
#   assert_exit_nonzero
#   assert_output_contains "Disk /"
#   finish

set -u

# UUT_ROOT is where the repo's scripts were staged on the target.
UUT_ROOT="${UUT_ROOT:-/opt/uut}"

_case_name=""
_failures=0
_assertions=0
_uut_status=""
_uut_output=""

# Cases override this to undo whatever they broke. Always runs, even on abort.
cleanup() { :; }

_on_exit() {
    _rc=$?
    cleanup
    exit "$_rc"
}
trap _on_exit EXIT
trap 'exit 130' INT TERM

describe() {
    _case_name="$1"
    printf '\n── %s\n' "$_case_name"
}

# Print a line only in verbose mode — keeps a passing run to one line per case.
note() {
    [ "${VERBOSE:-0}" = "1" ] && printf '   · %s\n' "$1"
    return 0
}

_pass() {
    _assertions=$((_assertions + 1))
    [ "${VERBOSE:-0}" = "1" ] && printf '   ✓ %s\n' "$1"
    return 0
}

_fail() {
    _assertions=$((_assertions + 1))
    _failures=$((_failures + 1))
    printf '   ✗ %s\n' "$1"
    return 0
}

# Run the script under test, capturing stdout+stderr and the exit status.
# The status is the entire point of this suite, so it is captured explicitly
# rather than inherited — `set -e` style propagation would hide it.
run_uut() {
    _uut_rel="$1"
    shift
    _uut_path="$UUT_ROOT/$_uut_rel"

    if [ ! -f "$_uut_path" ]; then
        _fail "script under test not found: $_uut_path"
        return 1
    fi

    _uut_output=$(sh "$_uut_path" "$@" 2>&1)
    _uut_status=$?

    note "exit status: $_uut_status"
    if [ "${VERBOSE:-0}" = "1" ]; then
        printf '%s\n' "$_uut_output" | sed 's/^/     | /'
    fi
    return 0
}

# Run the script under test as another user. The suite connects as root, which
# makes it structurally blind to every permission-dependent fault — and two of
# the four false failures found on 2026-08-05 were exactly that: a check that
# is green as root and red as the user whose cron actually runs it. A case that
# only ever runs as root cannot fail on those, however carefully it is written.
run_uut_as() {
    _as_user="$1"
    shift
    _uut_rel="$1"
    shift
    _uut_path="$UUT_ROOT/$_uut_rel"

    if [ ! -f "$_uut_path" ]; then
        _fail "script under test not found: $_uut_path"
        return 1
    fi

    if ! id "$_as_user" >/dev/null 2>&1; then
        _fail "cannot run as '$_as_user': no such user on this target"
        return 1
    fi

    # The staged tree is root-owned; without this the unprivileged user cannot
    # traverse to the script and the case fails for the wrong reason.
    chmod -R a+rX "$UUT_ROOT"

    _uut_output=$(su -s /bin/sh "$_as_user" -c "sh $_uut_path $*" 2>&1)
    _uut_status=$?

    note "ran as $_as_user, exit status: $_uut_status"
    if [ "${VERBOSE:-0}" = "1" ]; then
        printf '%s\n' "$_uut_output" | sed 's/^/     | /'
    fi
    return 0
}

assert_exit_zero() {
    if [ "$_uut_status" = "0" ]; then
        _pass "exited 0"
    else
        _fail "expected exit 0, got $_uut_status"
        _dump_output
    fi
}

assert_exit_nonzero() {
    if [ "$_uut_status" != "0" ]; then
        _pass "exited non-zero ($_uut_status)"
    else
        _fail "expected non-zero exit, got 0 — the check did not report the failure"
        _dump_output
    fi
}

assert_output_contains() {
    if printf '%s' "$_uut_output" | grep -qF -- "$1"; then
        _pass "output contains: $1"
    else
        _fail "output missing: $1"
        _dump_output
    fi
}

assert_output_not_contains() {
    if printf '%s' "$_uut_output" | grep -qF -- "$1"; then
        _fail "output unexpectedly contains: $1"
        _dump_output
    else
        _pass "output does not contain: $1"
    fi
}

# Guard against a case that "passes" because its precondition never took hold —
# a full-disk test on a disk that is not full proves nothing.
assert_precondition() {
    _desc="$1"
    shift
    if "$@"; then
        note "precondition holds: $_desc"
    else
        _fail "PRECONDITION FAILED: $_desc — the test could not arrange the fault it claims to test"
        exit 1
    fi
}

_dump_output() {
    [ "${VERBOSE:-0}" = "1" ] && return 0
    printf '     ─ captured output ─\n'
    printf '%s\n' "$_uut_output" | sed 's/^/     | /'
    printf '     ───────────────────\n'
}

finish() {
    if [ "$_failures" -eq 0 ]; then
        printf '   PASS (%s assertions)\n' "$_assertions"
        exit 0
    fi
    printf '   FAIL (%s of %s assertions)\n' "$_failures" "$_assertions"
    exit 1
}
