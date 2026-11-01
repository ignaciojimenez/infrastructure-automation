#!/bin/sh
# Unit test for scripts/ci/check_tool_versions.sh — the guard that keeps CI,
# the builder and the laptop on one lint toolchain (PER-159).
#
#   tests/unit/lint_tool_versions_test.sh
#
# Stubs shellcheck and ansible-lint with their real --version formats
# (ansible-lint's is ANSI-coloured even when piped) and checks that the pinned
# versions pass and that each kind of drift fails, naming the tool. Pinned
# values come from the real tool-versions.conf, so a bump does not break this.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
CHECK="$REPO_ROOT/scripts/ci/check_tool_versions.sh"
PINS="$REPO_ROOT/scripts/ci/tool-versions.conf"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/bin"

SC=$(sed -n 's/^SHELLCHECK_VERSION=//p' "$PINS")
AL=$(sed -n 's/^ANSIBLE_LINT_VERSION=//p' "$PINS")

# stubs <shellcheck version or "none"> <ansible-lint version>
stubs() {
    rm -f "$WORK/bin/shellcheck" "$WORK/bin/ansible-lint"
    if [ "$1" != none ]; then
        printf '#!/bin/sh\nprintf "ShellCheck - shell script analysis tool\\nversion: %s\\nlicense: GNU General Public License, version 3\\n"\n' "$1" > "$WORK/bin/shellcheck"
        chmod +x "$WORK/bin/shellcheck"
    fi
    printf '#!/bin/sh\nprintf "\\033[1;36mansible-lint\\033[0m \\033[1;36m%s\\033[0m using ansible-core:2.21.5\\n"\n' "$2" > "$WORK/bin/ansible-lint"
    chmod +x "$WORK/bin/ansible-lint"
}

# run_check: PATH holds only the stubs and the basics the script needs.
run_check() {
    PATH="$WORK/bin:/usr/bin:/bin" sh "$CHECK" "$PINS" > "$WORK/out" 2>&1
}

printf '\n── Lint tool version guard\n'

if [ -n "$SC" ] && [ -n "$AL" ]; then
    pass "tool-versions.conf pins shellcheck $SC and ansible-lint $AL"
else
    fail "tool-versions.conf is missing a pin"
fi

stubs "$SC" "$AL"
if run_check; then pass "pinned versions pass"; else fail "pinned versions failed: $(cat "$WORK/out")"; fi

stubs 0.10.0 "$AL"
if ! run_check && grep -q "shellcheck: 0.10.0 on PATH" "$WORK/out"; then
    pass "an older shellcheck fails and is named"
else
    fail "shellcheck drift not caught: $(cat "$WORK/out")"
fi

stubs "$SC" 26.9.0
if ! run_check && grep -q "ansible-lint: 26.9.0 on PATH" "$WORK/out"; then
    pass "a different ansible-lint fails and is named"
else
    fail "ansible-lint drift not caught: $(cat "$WORK/out")"
fi

stubs none "$AL"
if ! run_check && grep -q "shellcheck: not found" "$WORK/out"; then
    pass "a missing shellcheck fails"
else
    fail "missing shellcheck not caught: $(cat "$WORK/out")"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '   FAIL (%d)\n' "$failures"
exit 1
