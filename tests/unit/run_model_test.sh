#!/bin/sh
# run_model.sh — the root launcher that hands one OpenCode run to the model
# account (PER-122).
#
# Runs on the laptop, which cannot setuid, so `id`, `setpriv`, `timeout` and
# `pkill` are stubs. What this pins is the launcher's own logic: it refuses to
# run unprivileged or without the key, drops privileges with no_new_privs as the
# model account and in its home, returns opencode's status (or the time limit's
# 124) unchanged, and clears the account's processes afterwards either way. The
# boundary itself is proven live on agent-lxc (docs/AGENT_LXC.md, PER-122).
#
#   tests/unit/run_model_test.sh
#   SH=dash tests/unit/run_model_test.sh

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/run_model.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$WORK/bin" "$WORK/home"

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/run_model.sh" \
    agent_model_user=investigator \
    agent_model_home="$WORK/home" \
    agent_model_launcher="$WORK/run_model.sh" \
    primary_user=choco \
    agent_run_timeout_seconds=600 \
    opencode_bin="$WORK/bin/opencode" || exit 1

# ── Stubs ──────────────────────────────────────────────────────────────────
# id: the uid comes from FAKE_UID, so "root" is a choice, not a privilege.
cat > "$WORK/bin/id" <<'STUB'
#!/bin/sh
echo "${FAKE_UID:-1000}"
STUB
# timeout: drop `-k <n> <duration>` and run the rest, or report the limit hit.
cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/sh
[ -n "${FAKE_TIMEOUT:-}" ] && exit 124
while [ $# -gt 0 ]; do
    case "$1" in -k) shift 2 ;; [0-9]*) shift ;; *) break ;; esac
done
exec "$@"
STUB
# setpriv: record its options and the environment it would hand over, then run
# the command it wraps.
cat > "$WORK/bin/setpriv" <<'STUB'
#!/bin/sh
: > "$WORK/setpriv.args"
while [ $# -gt 0 ]; do
    case "$1" in --*) printf '%s\n' "$1" >> "$WORK/setpriv.args"; shift ;; *) break ;; esac
done
{
    echo "HOME=$HOME"; echo "USER=$USER"; echo "LOGNAME=$LOGNAME"; echo "SHELL=$SHELL"
    echo "PWD=$(pwd)"; echo "KEY=${ANTHROPIC_API_KEY:-}"
} > "$WORK/setpriv.env"
exec "$@"
STUB
# opencode: record its arguments, exit with FAKE_RC.
cat > "$WORK/bin/opencode" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$WORK/opencode.args"
exit "${FAKE_RC:-0}"
STUB
cat > "$WORK/bin/pkill" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$WORK/pkill.calls"
STUB
chmod +x "$WORK/bin/"*

run() {
    rm -f "$WORK/setpriv.args" "$WORK/setpriv.env" "$WORK/opencode.args" "$WORK/pkill.calls"
    (cd / && env PATH="$WORK/bin:/usr/bin:/bin" WORK="$WORK" "$@" \
        "$SH" "$WORK/run_model.sh" run --agent infra-monitor --format json 'the prompt') \
        > "$WORK/out" 2>&1
    RC=$?
}

printf '\n── Refuses to run unprivileged\n'
run FAKE_UID=1000 ANTHROPIC_API_KEY=k
if [ "$RC" -eq 1 ] && grep -q 'must run as root' "$WORK/out" && [ ! -e "$WORK/opencode.args" ]; then
    pass "not root: exit 1, opencode never started"
else
    fail "not root: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── Refuses to run without the key (a sudoers rule missing its env_keep)\n'
run FAKE_UID=0
if [ "$RC" -eq 1 ] && grep -q 'ANTHROPIC_API_KEY was not passed' "$WORK/out" && [ ! -e "$WORK/opencode.args" ]; then
    pass "no key: exit 1, opencode never started"
else
    fail "no key: rc=$RC $(cat "$WORK/out")"
fi

printf '\n── Drops to the model account and returns opencode'"'"'s status\n'
run FAKE_UID=0 ANTHROPIC_API_KEY=sk-test FAKE_RC=7 HOME=/root USER=root SHELL=/bin/bash
if [ "$RC" -eq 7 ]; then
    pass "opencode's exit status 7 comes back unchanged"
else
    fail "status: rc=$RC $(cat "$WORK/out")"
fi
for opt in --reuid=investigator --regid=investigator --init-groups --no-new-privs; do
    if grep -qx -- "$opt" "$WORK/setpriv.args" 2>/dev/null; then
        pass "setpriv $opt"
    else
        fail "setpriv missing $opt: $(cat "$WORK/setpriv.args" 2>/dev/null)"
    fi
done
for kv in "HOME=$WORK/home" USER=investigator LOGNAME=investigator SHELL=/bin/sh "PWD=$WORK/home" KEY=sk-test; do
    if grep -qx -- "$kv" "$WORK/setpriv.env" 2>/dev/null; then
        pass "hands over $kv"
    else
        fail "expected $kv in: $(cat "$WORK/setpriv.env" 2>/dev/null)"
    fi
done
if [ "$(tr '\n' ' ' < "$WORK/opencode.args")" = "run --agent infra-monitor --format json the prompt " ]; then
    pass "opencode gets the caller's arguments, the prompt as one"
else
    fail "opencode args: $(cat "$WORK/opencode.args")"
fi
if grep -qx -- '-KILL -u investigator' "$WORK/pkill.calls" 2>/dev/null; then
    pass "the model account's leftovers are killed after the run"
else
    fail "no cleanup: $(cat "$WORK/pkill.calls" 2>/dev/null)"
fi

printf '\n── The time limit: 124 comes back, and the cleanup still runs\n'
run FAKE_UID=0 ANTHROPIC_API_KEY=sk-test FAKE_TIMEOUT=1
if [ "$RC" -eq 124 ]; then
    pass "timeout: exit 124, which investigate.sh reports as a timeout"
else
    fail "timeout: rc=$RC $(cat "$WORK/out")"
fi
if grep -qx -- '-KILL -u investigator' "$WORK/pkill.calls" 2>/dev/null; then
    pass "leftovers killed after a timeout too"
else
    fail "no cleanup after timeout: $(cat "$WORK/pkill.calls" 2>/dev/null)"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    echo "run_model: all checks passed"
    exit 0
fi
echo "run_model: $failures check(s) failed"
exit 1
