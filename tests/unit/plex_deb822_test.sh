#!/bin/sh
# Static test: the plex role manages its apt repo with deb822_repository.
#
#   tests/unit/plex_deb822_test.sh
#
# apt_repository is deprecated (removed in ansible-core 2.25) and needs a gpg
# binary on the target. The replacement writes plex.sources, so the plex.list
# the old task wrote must be removed or apt sees the repo twice, and
# python3-debian must be installed first or --check fails.
#
# Comment lines are stripped before matching so prose cannot satisfy or break
# an assertion.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROLE="$REPO_ROOT/ansible/roles/services/plex"
TASKS="$ROLE/tasks/main.yml"
CODE=$(mktemp)
trap 'rm -f "$CODE"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── plex role: deb822_repository\n'

[ -r "$TASKS" ] || { printf '   ✗ cannot read %s\n' "$TASKS"; exit 1; }
grep -v '^[[:space:]]*#' "$TASKS" > "$CODE"

# First line number matching a pattern in the comment-free tasks, or empty.
line_of() { grep -n -- "$1" "$CODE" | head -1 | cut -d: -f1; }

if grep -rv '^[[:space:]]*#' "$ROLE" | grep -q 'apt_repository'; then
    fail "apt_repository is still used in the plex role"
else
    pass "no apt_repository left in the plex role"
fi

repo=$(line_of 'ansible.builtin.deb822_repository:')
if [ -n "$repo" ]; then
    pass "uses ansible.builtin.deb822_repository"
else
    fail "no ansible.builtin.deb822_repository task"
    repo=0
fi

if grep -q "uris: .*plex_distro_url | default('https://repo.plex.tv/deb/')" "$CODE"; then
    pass "URI keeps the plex_distro_url default"
else
    fail "URI no longer comes from plex_distro_url with the repo.plex.tv default"
fi
if grep -Eq 'suites: \[?public\]?$' "$CODE"; then
    pass "suite is public"
else
    fail "suite is not public"
fi
if grep -Eq 'components: \[?main\]?$' "$CODE"; then
    pass "components is main"
else
    fail "components is not main"
fi
if grep -q 'signed_by: /etc/apt/keyrings/plexmediaserver.v2.gpg$' "$CODE"; then
    pass "signed_by keeps the v2 keyring"
else
    fail "signed_by is not the v2 keyring"
fi

# The old task's filename: plex → /etc/apt/sources.list.d/plex.list.
absent=$(grep -n -A2 'path: /etc/apt/sources.list.d/plex.list$' "$CODE" \
    | grep 'state: absent' | head -1 | cut -d- -f1)
install=$(line_of 'name: plexmediaserver$')
if [ -n "$absent" ]; then
    pass "plex.list is removed with state: absent"
else
    fail "plex.list is not removed with state: absent"
    absent=999999
fi

if [ -n "$install" ] && [ "$absent" -lt "$install" ]; then
    pass "plex.list removal precedes the plexmediaserver install"
else
    fail "plex.list removal does not precede the plexmediaserver install"
fi

debian=$(line_of 'name: python3-debian$')
if [ -n "$debian" ] && [ "$debian" -lt "$repo" ]; then
    pass "python3-debian is installed before deb822_repository"
else
    fail "python3-debian is not installed before deb822_repository"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   ALL PASS\n\n'
    exit 0
fi
printf '   %d FAILED\n\n' "$failures"
exit 1
