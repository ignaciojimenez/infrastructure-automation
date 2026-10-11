#!/bin/sh
# check_builder_isolation.sh — the hourly re-proof of the builder's boundary
# (PER-85 part 2).
#
# Runs on the laptop. The real template is rendered with paths in a temp dir;
# "becoming the unattended account" is a stub that either can or cannot read,
# because a laptop cannot setuid.
#
#   tests/unit/builder_isolation_test.sh
#   SH=dash tests/unit/builder_isolation_test.sh

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/workbench/check_builder_isolation.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/etc" "$WORK/state" "$WORK/lib" "$WORK/home/.claude" "$WORK/bin"
# The stub account: `denyall` refuses every read, as the real boundary does.
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/denyall"
chmod +x "$WORK/bin/denyall"

render() {
    # render <run_as>
    python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/check.sh" \
        builder_run_as="$1" \
        builder_run_user=autobuilder \
        builder_linear_auth_file="$WORK/etc/linear.header" \
        builder_claude_env_file="$WORK/etc/claude.env" \
        builder_state_dir="$WORK/state" \
        builder_lib_dir="$WORK/lib" \
        builder_interactive_home="$WORK/home" || exit 1
}
# Every path the template protects, created — whatever names it uses.
create_protected() {
    sed -n '/^PROTECTED="/,/"$/p' "$WORK/check.sh" | sed 's/^PROTECTED="//; s/"$//' |
        while IFS= read -r p; do mkdir -p "$(dirname "$p")"; echo secret > "$p"; done
}
run() { "$SH" "$WORK/check.sh" > "$WORK/out" 2>&1; RC=$?; }

printf '\n── The boundary holds: every protected path exists and is refused\n'
render "$WORK/bin/denyall"
create_protected
run
if [ "$RC" -eq 0 ] && grep -q "7 denied, 0 readable, 0 missing" "$WORK/out"; then
    pass "all seven refused: exit 0"
else
    fail "healthy boundary: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── The boundary is broken: a protected path is readable\n'
render ""
run
if [ "$RC" -ne 0 ] && grep -q "READABLE: autobuilder can read $WORK/etc/linear.header" "$WORK/out"; then
    pass "a readable credential fails the check and is named"
else
    fail "readable path not caught: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── A protected path that does not exist fails, never passes\n'
render "$WORK/bin/denyall"
rm -f "$WORK/etc/claude.env"
run
if [ "$RC" -ne 0 ] && grep -q "MISSING: $WORK/etc/claude.env" "$WORK/out"; then
    pass "a missing path is a failure, not a trivially-true 'cannot read'"
else
    fail "missing path passed: rc=$RC $(cat "$WORK/out")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ builder_isolation: all checks passed\n'
    exit 0
fi
printf '❌ builder_isolation: %s check(s) failed\n' "$failures"
exit 1
