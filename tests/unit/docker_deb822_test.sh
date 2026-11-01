#!/bin/sh
# Static test: the docker role manages its apt repository with
# deb822_repository, not the deprecated apt_repository (PER-154).
#
#   tests/unit/docker_deb822_test.sh
#
# apt_repository is removed in ansible-core 2.25 and needs a gpg binary on the
# target. The replacement has two traps, both pinned here: python3-debian must
# be installed first (or --check fails), and the old docker.list must be removed
# before any apt run (or apt sees the repository twice).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROLE="$REPO_ROOT/ansible/roles/services/docker/tasks/main.yml"

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

[ -r "$ROLE" ] || { printf '   ✗ cannot read %s\n' "$ROLE"; exit 1; }

# Comments may mention the old module; only live YAML counts.
CODE=$(mktemp)
trap 'rm -f "$CODE"' EXIT
grep -v '^[[:space:]]*#' "$ROLE" > "$CODE"

# Text of the task whose body contains $1, from its "- name:" line on.
task_block() {
    awk -v pat="$1" '
        /^- name:/ { if (hit) printf "%s", buf; buf = ""; hit = 0 }
        { buf = buf $0 "\n"; if (index($0, pat)) hit = 1 }
        END { if (hit) printf "%s", buf }
    ' "$CODE"
}

# Line of the first match of $1 in the live YAML (empty if none).
first_line() { grep -n "$1" "$CODE" | head -n 1 | cut -d: -f1; }

printf '\n── The deprecated one-line module is gone\n'
if grep -q 'apt_repository' "$CODE"; then
    fail 'apt_repository still used in the docker role'
else
    pass 'no apt_repository in the docker role'
fi

printf '\n── deb822_repository carries the same repository\n'
repo=$(task_block 'ansible.builtin.deb822_repository:')
if [ -z "$repo" ]; then
    fail 'no deb822_repository task'
else
    pass 'deb822_repository task exists'
    case $repo in *"docker_distro_url | default('https://download.docker.com/linux/debian')"*)
        pass 'same URI' ;; *) fail 'URI differs' ;; esac
    case $repo in *'{{ ansible_distribution_release }}'*)
        pass 'suite is ansible_distribution_release' ;; *) fail 'suite differs' ;; esac
    case $repo in *'components: [stable]'*)
        pass 'component stable' ;; *) fail 'component is not stable' ;; esac
    case $repo in *'architecture_result.stdout'*)
        pass 'architecture from architecture_result' ;; *) fail 'architecture not from architecture_result' ;; esac
    case $repo in *"signed_by: \"{{ docker_key_file | default('/usr/share/keyrings/docker.asc') }}\""*)
        pass 'same signed_by path' ;; *) fail 'signed_by differs' ;; esac
    case $repo in *'become: true'*) pass 'become: true' ;; *) fail 'missing become' ;; esac
    case $repo in *'tags: [docker]'*) pass 'tagged docker' ;; *) fail 'missing docker tag' ;; esac
fi

printf '\n── The old docker.list is removed before any apt install\n'
rm_block=$(task_block 'docker.list')
rm_line=$(first_line 'docker\.list')
case $rm_block in
    *'state: absent'*) pass 'a task removes docker.list with state: absent' ;;
    *) fail 'no task removes docker.list with state: absent' ;;
esac
apt_line=$(first_line 'ansible.builtin.apt:')
if [ -z "$rm_line" ] || [ -z "$apt_line" ]; then
    fail 'cannot order docker.list removal against the first apt task'
elif [ "$rm_line" -lt "$apt_line" ]; then
    pass "removal (line $rm_line) precedes the first apt task (line $apt_line)"
else
    fail "removal (line $rm_line) comes after the first apt task (line $apt_line)"
fi

printf '\n── python3-debian is ensured before deb822_repository\n'
deb_line=$(first_line 'ansible.builtin.deb822_repository:')
pd_line=$(first_line 'python3-debian')
if [ -z "$deb_line" ] || [ -z "$pd_line" ]; then
    fail 'python3-debian or deb822_repository task missing'
elif [ "$pd_line" -lt "$deb_line" ]; then
    pass "python3-debian (line $pd_line) precedes deb822_repository (line $deb_line)"
else
    fail "python3-debian (line $pd_line) comes after deb822_repository (line $deb_line)"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ docker deb822: all checks passed\n'
    exit 0
fi
printf '❌ docker deb822: %s check(s) failed\n' "$failures"
exit 1
