#!/bin/sh
# audio_playback: the Raspotify repository is managed with deb822_repository,
# not the deprecated apt_repository (PER 155).
#
#   tests/unit/audio_playback_deb822_test.sh
#
# Static: reads the role's tasks file. Comments are stripped first, so prose
# that mentions the old module does not count as using it.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROLE="$REPO_ROOT/ansible/roles/services/audio_playback"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

# Every YAML file in the role, comment lines removed, line numbers kept.
for f in "$ROLE"/tasks/*.yml; do
    sed 's/^[[:space:]]*#.*$//' "$f" > "$WORK/$(basename "$f")"
done
TASKS="$WORK/main.yml"

printf '\n── No apt_repository left in the role\n'
if grep -n 'apt_repository' "$WORK"/*.yml > "$WORK/hits"; then
    fail "apt_repository still present: $(head -n 1 "$WORK/hits")"
else
    pass "no apt_repository task in the role"
fi

printf '\n── The deb822 task keeps URI, suite, components and key\n'
# The task body: from its module line to the next task.
awk '/ansible.builtin.deb822_repository:/ { on = 1; next }
     on && /^ *- name:/ { exit }
     on { print }' "$TASKS" > "$WORK/deb822"
check() {
    if grep -Eq "$2" "$WORK/deb822"; then pass "$1"; else fail "$1 missing"; fi
}
check "uris: https://dtcooper.github.io/raspotify" '^ *uris: *https://dtcooper\.github\.io/raspotify *$'
check "suites: raspotify" '^ *suites: *raspotify *$'
check "components: [main]" '^ *components: *\[ *main *\] *$'
check "signed_by: raspotify-archive-keyring.asc" '^ *signed_by: */usr/share/keyrings/raspotify-archive-keyring\.asc *$'
check "state: present" '^ *state: *present *$'

printf '\n── Ordering\n'
line_of() { grep -n "$1" "$TASKS" | head -n 1 | cut -d: -f1; }
deb=$(line_of 'ansible.builtin.deb822_repository:')
pydeb=$(line_of 'name: python3-debian')
list=$(line_of 'path: /etc/apt/sources.list.d/raspotify.list')
# By task title: the deb822 task's own `name: raspotify` would match first.
inst=$(line_of '^ *- name: Install Raspotify$')

if [ -n "$pydeb" ] && [ -n "$deb" ] && [ "$pydeb" -lt "$deb" ]; then
    pass "python3-debian is ensured before the deb822 task"
else
    fail "python3-debian not ensured before the deb822 task (${pydeb:-none} vs ${deb:-none})"
fi

if [ -n "$list" ] && [ -n "$inst" ] && [ "$list" -lt "$inst" ] \
    && sed -n "$list,$((list + 2))p" "$TASKS" | grep -q 'state: absent'; then
    pass "raspotify.list is removed (state: absent) before the apt install"
else
    fail "raspotify.list not removed before the install (${list:-none} vs ${inst:-none})"
fi

if [ "$failures" -eq 0 ]; then
    printf '   PASS\n'
    exit 0
fi
printf '❌ audio_playback deb822: %s check(s) failed\n' "$failures"
exit 1
