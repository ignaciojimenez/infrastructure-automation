#!/bin/sh
# Workbench Remote Control names a lapsed claude.ai login (PER-160).
#
#   tests/unit/remote_control_login_test.sh
#
# Renders the check and runs it against a stubbed pgrep and a temporary marker.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TPL="$REPO_ROOT/ansible/roles/services/workbench/templates"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin"
python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TPL/check_remote_control.sh.j2" "$WORK/check.sh" \
    workbench_tmux_session=workbench workbench_agent_user=builder || exit 1

# pgrep that finds everything, so only the marker can make the check fail.
printf '#!/bin/sh\necho 4242\n' > "$WORK/bin/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/pgrep" "$WORK/bin/tmux"

printf '\n── Marker present: the login is named, even with tmux and claude running\n'
: > "$WORK/marker"
out=$(PATH="$WORK/bin:$PATH" CLAUDE_RC_LOGIN_MARKER="$WORK/marker" sh "$WORK/check.sh")
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'claude.ai login missing for builder'; then
    pass "exit 1 with the login message"
else
    fail "marker: rc=$rc out=$out"
fi

printf '\n── Marker absent: unchanged behaviour\n'
out=$(PATH="$WORK/bin:$PATH" CLAUDE_RC_LOGIN_MARKER="$WORK/none" sh "$WORK/check.sh")
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^OK: Remote Control up'; then
    pass "healthy session still reports OK"
else
    fail "no marker: rc=$rc out=$out"
fi

printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/pgrep"
out=$(PATH="$WORK/bin:$PATH" CLAUDE_RC_LOGIN_MARKER="$WORK/none" sh "$WORK/check.sh")
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'no tmux server'; then
    pass "no marker and no tmux still reports the tmux symptom"
else
    fail "no tmux: rc=$rc out=$out"
fi

printf '\n── The unit gates start on the login and carries no credential\n'
UNIT="$TPL/claude-remote-control.service.j2"
if grep -q '^ExecStartPre=.*' "$UNIT" && grep -Fq 'loggedIn\": true' "$UNIT"; then
    pass "ExecStartPre greps \"loggedIn\": true"
else
    fail "ExecStartPre does not check loggedIn"
fi
if grep -q '^RuntimeDirectory=claude-remote-control$' "$UNIT" \
    && grep -q '^RuntimeDirectoryPreserve=yes$' "$UNIT"; then
    pass "RuntimeDirectory lines present"
else
    fail "RuntimeDirectory lines missing"
fi
if grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$UNIT"; then
    # The existing explanatory comment names it; only a setting is forbidden.
    if grep -v '^[[:space:]]*#' "$UNIT" | grep -q 'CLAUDE_CODE_OAUTH_TOKEN'; then
        fail "CLAUDE_CODE_OAUTH_TOKEN is set in the unit"
    else
        pass "token only mentioned in comments, never set"
    fi
else
    pass "no CLAUDE_CODE_OAUTH_TOKEN in the unit"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ remote control login: all checks passed\n'
    exit 0
fi
printf '❌ remote control login: %s check(s) failed\n' "$failures"
exit 1
