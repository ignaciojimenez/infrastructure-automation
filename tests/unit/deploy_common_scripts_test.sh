#!/bin/sh
# Regression test: deploy_monitoring.yml must not raw-copy the heartbeat_backup.sh
# template (PER-157), and must remove the stray copy earlier runs left behind.
#
#   tests/unit/deploy_common_scripts_test.sh
#
# Evaluates the "Deploy all common scripts" task's own `when:` against every file
# in scripts/common/ for a Debian and a FreeBSD host, rather than grepping for a
# filename. Needs only python3 (no jinja2): the condition is translated to the
# equivalent Python expression, which these `not/and/==/!=` forms allow.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
PLAYBOOK="$REPO_ROOT/ansible/playbooks/deploy_monitoring.yml"
COMMON="$REPO_ROOT/scripts/common"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── deploy_monitoring.yml common script selection\n'

[ -r "$PLAYBOOK" ] || { printf '   ✗ cannot read %s\n' "$PLAYBOOK"; exit 1; }

# The lines of one task, from its "- name:" to the next task.
task_block() {
    awk -v n="$1" '
        /^    - name: / { on = (index($0, n) > 0) }
        on { print }
    ' "$PLAYBOOK"
}

copy_block=$(task_block "Deploy all common scripts")
when=$(printf '%s\n' "$copy_block" | sed -n 's/^      when: //p')
if [ -z "$when" ]; then
    fail "copy task has no single-line when:"
    printf '   FAIL (%s)\n' "$failures"
    exit 1
fi

# selected <os_family> <file> -> prints "yes" or "no"
selected() {
    python3 - "$when" "$1" "$2" <<'PY'
import sys

when, os_family, fname = sys.argv[1:4]
expr = when.replace("item.path | basename", "fname")
print("yes" if eval(expr, {"__builtins__": {}}, {"os_family": os_family, "fname": fname}) else "no")
PY
}

expect() { # <os_family> <file> <yes|no>
    got=$(selected "$1" "$2")
    if [ "$got" = "$3" ]; then
        pass "$2 on $1: copied=$got"
    else
        fail "$2 on $1: copied=$got, expected $3"
    fi
}

expect debian heartbeat_backup.sh no
expect freebsd heartbeat_backup.sh no
expect debian system_health_check.sh yes
expect freebsd system_health_check.sh no

for f in "$COMMON"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in
        heartbeat_backup.sh) continue ;;
        system_health_check.sh) expect_os="debian" ;;
        *) expect_os="debian freebsd" ;;
    esac
    for os in $expect_os; do
        expect "$os" "$name" yes
    done
done

printf '\n── removal task\n'

rm_block=$(task_block "Remove the unrendered heartbeat template")
rm_path=$(printf '%s\n' "$rm_block" | sed -n 's/^        path: //p' | tr -d '"')
if [ "$rm_path" = '{{ scripts_dir }}/heartbeat_backup.sh' ]; then
    pass "removal targets {{ scripts_dir }}/heartbeat_backup.sh exactly"
else
    fail "removal path is '$rm_path'"
fi

if printf '%s\n' "$rm_block" | grep -q '^        state: absent$'; then
    pass "removal is state: absent"
else
    fail "removal is not state: absent"
fi

copy_tags=$(printf '%s\n' "$copy_block" | sed -n 's/^      tags: //p')
rm_tags=$(printf '%s\n' "$rm_block" | sed -n 's/^      tags: //p')
if [ -n "$rm_tags" ] && [ "$rm_tags" = "$copy_tags" ]; then
    pass "removal is tagged like the copy task"
else
    fail "removal tags '$rm_tags' differ from copy tags '$copy_tags'"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '   FAIL (%s)\n' "$failures"
exit 1
