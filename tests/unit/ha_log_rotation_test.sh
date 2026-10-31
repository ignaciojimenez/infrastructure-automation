#!/bin/sh
# Static test: the Home Assistant and Matter Server containers rotate their
# json-file logs, and BOTH writers of the HA container say the same thing.
#
#   tests/unit/ha_log_rotation_test.sh
#
# The HA container has two writers: the docker_container task in
# roles/services/homeassistant/tasks/main.yml and the `docker run` in
# templates/update_ha.j2. If their log config differs, every Ansible run
# recreates the container (or an update silently drops rotation). So the values
# are pinned to literals here, identical to cloudflared's, and any divergence
# between the writers fails.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROLE="$REPO_ROOT/ansible/roles/services/homeassistant"
TASKS="$ROLE/tasks/main.yml"
UPDATE="$ROLE/templates/update_ha.j2"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── HA and matter-server log rotation, both writers\n'

[ -r "$TASKS" ] && [ -r "$UPDATE" ] || { printf '   ✗ cannot read role files\n'; exit 1; }

# The text of one task: from its "- name:" line to the next task.
task_block() {
    awk -v n="- name: $1" '
        $0 == n { on = 1; print; next }
        on && /^- name:/ { exit }
        on { print }
    ' "$TASKS"
}

check_task() {
    label="$1"; name="$2"
    block=$(task_block "$name")
    if [ -z "$block" ]; then
        fail "$label: task \"$name\" not found"
        return
    fi
    driver=$(printf '%s\n' "$block" | grep -E '^ +log_driver:' | sed 's/^ *log_driver: *//')
    size=$(printf '%s\n' "$block" | grep -E '^ +max-size:' | sed 's/^ *max-size: *//')
    files=$(printf '%s\n' "$block" | grep -E '^ +max-file:' | sed 's/^ *max-file: *//')
    [ "$driver" = 'json-file' ] \
        && pass "$label: log_driver json-file" \
        || fail "$label: log_driver is '$driver', want json-file"
    [ "$size" = '10m' ] \
        && pass "$label: max-size 10m" \
        || fail "$label: max-size is '$size', want 10m"
    [ "$files" = '"3"' ] \
        && pass "$label: max-file \"3\"" \
        || fail "$label: max-file is '$files', want \"3\" (quoted)"
}

check_task 'home-assistant task' 'Create and start Home Assistant container'
check_task 'matter-server task' 'Create and start Matter Server container'

# The `docker run -d` statement, continuation lines joined onto one line.
run=$(awk '
    /docker run -d/ { on = 1 }
    on { line = $0; sub(/\\$/, "", line); out = out " " line }
    on && $0 !~ /\\$/ { exit }
    END { print out }
' "$UPDATE" | tr -s ' ')

if [ -z "$(printf '%s' "$run" | tr -d ' ')" ]; then
    fail "update_ha.j2: no 'docker run -d' found"
else
    count() { printf '%s\n' "$run" | grep -oE -- "(^| )$1( |\$)" | wc -l | tr -d ' '; }
    for flag in '--log-driver json-file' '--log-opt max-size=10m' '--log-opt max-file=3'; do
        if [ "$(count "$flag")" -eq 1 ]; then
            pass "update_ha.j2: docker run has '$flag'"
        else
            fail "update_ha.j2: docker run lacks exactly one '$flag'"
        fi
    done
    # Any other log flag (a second driver, a different size) is a disagreement.
    extra=$(printf '%s\n' "$run" | grep -oE -- '--log-(driver|opt)[ =][^ ]+( [^ -][^ ]*)?' | wc -l | tr -d ' ')
    [ "$extra" -eq 3 ] \
        && pass "update_ha.j2: no additional --log-* flags" \
        || fail "update_ha.j2: expected exactly 3 --log-* flags, found $extra"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   all checks passed\n\n'
    exit 0
fi
printf '   %d check(s) failed\n\n' "$failures"
exit 1
