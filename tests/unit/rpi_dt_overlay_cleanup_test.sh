#!/bin/sh
# Regression test (PER-158): the raspberrypi playbook must strip the inert,
# malformed dt_overlay= lines from config.txt, and nothing else.
#
#   tests/unit/rpi_dt_overlay_cleanup_test.sh
#
# Applies the playbook's own lineinfile regexp to a fixture config.txt, then
# statically checks the task sits after the backup and before the assert.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
PLAYBOOK="$REPO_ROOT/ansible/playbooks/platform/raspberrypi.yml"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── dt_overlay= cleanup\n'

[ -r "$PLAYBOOK" ] || { printf '   ✗ cannot read %s\n' "$PLAYBOOK"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The regexp of the absent-state task named for dt_overlay.
regexp=$(grep -A6 'name: .*dt_overlay' "$PLAYBOOK" |
    sed -n "s/^[[:space:]]*regexp: '\(.*\)'[[:space:]]*\$/\1/p" | head -n 1)

if [ -z "$regexp" ]; then
    fail "no dt_overlay removal task with a regexp in the playbook"
else
    pass "found regexp: $regexp"
    ere=$(printf '%s' "$regexp" | sed 's/\\s/[[:space:]]/g')

    cat > "$tmp/config.txt" <<'EOF'
# Uncomment to enable; dt_overlay is not a real directive
dtoverlay=disable-bt
dt_overlay="disable-bt"
dtoverlay=vc4-kms-v3d,noaudio,nohdmi
  dt_overlay="disable-wifi"
dtoverlay=hifiberry-dacplushd
EOF
    cat > "$tmp/expected.txt" <<'EOF'
# Uncomment to enable; dt_overlay is not a real directive
dtoverlay=disable-bt
dtoverlay=vc4-kms-v3d,noaudio,nohdmi
dtoverlay=hifiberry-dacplushd
EOF
    grep -vE "$ere" "$tmp/config.txt" > "$tmp/actual.txt"

    if cmp -s "$tmp/actual.txt" "$tmp/expected.txt"; then
        pass "only the two malformed lines are removed"
    else
        fail "unexpected result after applying regexp"
        diff "$tmp/expected.txt" "$tmp/actual.txt" | sed 's/^/     /'
    fi
fi

backup=$(grep -n 'name: Back up config.txt before touching it' "$PLAYBOOK" | head -n 1 | cut -d: -f1)
task=$(grep -n 'name: .*dt_overlay' "$PLAYBOOK" | head -n 1 | cut -d: -f1)
check=$(grep -n 'name: Confirm config.txt is intact' "$PLAYBOOK" | head -n 1 | cut -d: -f1)

if [ -n "$backup" ] && [ -n "$task" ] && [ -n "$check" ] &&
    [ "$backup" -lt "$task" ] && [ "$task" -lt "$check" ]; then
    pass "task sits after the backup and before the assert"
else
    fail "task order wrong or missing (backup=${backup:-?} task=${task:-?} assert=${check:-?})"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '   FAIL (%s)\n' "$failures"
exit 1
