#!/bin/sh
# Control-flow test for `tests/sandbox.sh --create` (TODO 3c).
#
# Runs on the laptop: `ssh` and `ssh-keygen` are stubs, HOME is a scratch
# directory holding a dummy rig key, and the script runs under dash. It proves
# the refusals and the lock handling; only the workbench proves that rig_ct
# actually builds a container (see docs/TODO.md item 3c for that run).
#
#   tests/unit/sandbox_create_test.sh
#
# What it pins:
#   - --create refuses anything but CT 199/198, refuses --root (a bare
#     container is a laptop job), and refuses to run without the rig key
#   - it takes rig_loop's lock, and never removes a lock it did not take
#   - it destroys only after a yes, and releases the lock on every path out,
#     including a failed create

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SANDBOX="$REPO_ROOT/tests/sandbox.sh"
WORK=$(mktemp -d)
LOCK=/tmp/rig_loop.199.lock
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── sandbox.sh --create\n'

# The lock path is the real one rig_loop uses. Never touch one we did not make.
if [ -e "$LOCK" ]; then
    printf '   ✗ %s exists — a rig_loop may be running; not testing\n' "$LOCK"
    exit 1
fi

mkdir -p "$WORK/bin" "$WORK/home/.ssh"
: > "$WORK/home/.ssh/rig_runner_ed25519"

# rig_runner@… calls are the rig_ct grant: "status|destroy|create <vmid>".
# Anything else is the container itself.
cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
cmd=""
for a in "$@"; do cmd="$a"; done
case "$*" in
    *rig_runner@*)
        echo "rig $cmd" >> "$STUB_LOG"
        case "$cmd" in
            status*)  exit "${STUB_STATUS_RC:-0}" ;;
            create*)  exit "${STUB_CREATE_RC:-0}" ;;
            *)        exit 0 ;;
        esac ;;
    *)
        echo "ct $cmd" | head -1 >> "$STUB_LOG"
        [ "$cmd" = hostname ] && echo testlxc
        exit 0 ;;
esac
STUB
cat > "$WORK/bin/ssh-keygen" <<'STUB'
#!/bin/sh
echo "keygen $*" >> "$STUB_LOG"
STUB
chmod +x "$WORK/bin/ssh" "$WORK/bin/ssh-keygen"

# run <answer> <args…> — sets $out, $rc; the stub log is in $WORK/log
run() {
    _answer=$1; shift
    : > "$WORK/log"
    out=$(printf '%s\n' "$_answer" | env -u SSH_KEY HOME="$WORK/home" \
        PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/log" dash "$SANDBOX" "$@" 2>&1)
    rc=$?
}
called() { grep -q "^$1\$" "$WORK/log"; }

# ------------------------------------------------------------------
run "" --create --target 10.30.40.1
if [ "$rc" -ne 0 ] && ! called "rig status 199"; then
    pass "refuses a target that is not CT 199/198"
else fail "a foreign target was accepted (rc=$rc)"; fi

run "" --create --root
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'TEST_CT_BARE'; then
    pass "refuses --root and points at the laptop's bare path"
else fail "--root --create was not refused (rc=$rc)"; fi

: > "$WORK/log"
out=$(env -u SSH_KEY HOME="$WORK/nohome" PATH="$WORK/bin:$PATH" \
    STUB_LOG="$WORK/log" dash "$SANDBOX" --create 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'runs on the workbench' \
    && ! [ -s "$WORK/log" ]; then
    pass "without the rig key it refuses before touching anything"
else fail "ran without the rig key (rc=$rc)"; fi

mkdir "$LOCK"
run y --create
if [ "$rc" -ne 0 ] && [ -d "$LOCK" ] && ! called "rig destroy 199"; then
    pass "a held rig_loop lock refuses the run and is left in place"
else fail "ran under someone else's lock, or removed it (rc=$rc)"; fi
rmdir "$LOCK"

run n --create
if [ "$rc" -ne 0 ] && ! called "rig destroy 199" && ! [ -e "$LOCK" ]; then
    pass "an existing container is not destroyed without a yes; lock released"
else fail "destroyed without a yes, or leaked the lock (rc=$rc)"; fi

run y --create
if [ "$rc" -eq 0 ] && called "rig destroy 199" && called "rig create 199" \
    && called "keygen -R 10.30.40.205" && ! [ -e "$LOCK" ]; then
    pass "yes: destroy, create, old host key dropped, lock released"
else fail "the happy path did not run in full (rc=$rc)"; fi
if [ "$(grep -n 'rig destroy' "$WORK/log" | cut -d: -f1)" -lt \
     "$(grep -n 'rig create' "$WORK/log" | cut -d: -f1)" ]; then
    pass "destroy runs before create"
else fail "create ran before destroy"; fi

STUB_STATUS_RC=1; export STUB_STATUS_RC
run "" --create
if [ "$rc" -eq 0 ] && ! called "rig destroy 199" && called "rig create 199"; then
    pass "no container yet: creates without asking"
else fail "an absent container was not simply created (rc=$rc)"; fi
unset STUB_STATUS_RC

STUB_CREATE_RC=1; export STUB_CREATE_RC
run y --create
if [ "$rc" -ne 0 ] && ! [ -e "$LOCK" ]; then
    pass "a failed create exits non-zero and still releases the lock"
else fail "a failed create passed, or leaked the lock (rc=$rc)"; fi
unset STUB_CREATE_RC

run y --create --deb12
if [ "$rc" -eq 0 ] && called "rig create 198" && called "keygen -R 10.30.40.206"; then
    pass "--deb12 maps to CT 198"
else fail "--deb12 did not drive CT 198 (rc=$rc)"; fi

[ -e "$LOCK" ] && rmdir "$LOCK"
printf '\n'
[ "$failures" -eq 0 ] && { printf 'all passed\n'; exit 0; }
printf '%s failure(s)\n' "$failures"; exit 1
