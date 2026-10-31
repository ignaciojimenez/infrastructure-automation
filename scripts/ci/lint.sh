#!/bin/sh
# CI's lint, as one script — run by .github/workflows/ansible-lint.yml and by
# the unattended builder before it opens a PR (PER-159).
#
#   scripts/ci/lint.sh
#
# Why one script: the builder ran the unit tests and the rig but not this, so
# PR #23 went up with a test that failed CI's shellcheck (SC2034). Two copies
# of a command list drift; this is the only one.
#
# What it lints: the git INDEX of the current repo, exported to a temporary
# directory and set up the way CI sets up its checkout (example inventory, a
# dummy vault). The working tree is never touched, so it is safe to run in the
# builder's worktree or on the laptop with the real vault present.
#
# Needs on PATH: git, ansible-lint, ansible-playbook, ansible-vault, shellcheck,
# and a python with jinja2. ⚠️ shellcheck versions differ: CI installs Ubuntu's,
# Debian 13 ships another, the laptop another. CI is the authority; a check that
# passes here and fails there is a version skew to note, not to argue with.

set -eu

REPO=$(git rev-parse --show-toplevel)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

git -C "$REPO" checkout-index --all --prefix="$WORK/tree/"
cd "$WORK/tree"

# ── Set up like CI's checkout ─────────────────────────────────────────────
printf 'ci-dummy\n' > "$WORK/vault-pass"
ANSIBLE_VAULT_PASSWORD_FILE="$WORK/vault-pass"
export ANSIBLE_VAULT_PASSWORD_FILE
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/inventory/group_vars/all/main.yml.example ansible/inventory/group_vars/all/main.yml
cp ansible/inventory/group_vars/all/vault.yml.example ansible/inventory/group_vars/all/vault.yml
ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml >/dev/null

# check_jinja_syntax.py needs jinja2. CI's python has it via ansible-lint; on
# the laptop and the workbench, ansible lives in its own venv, so fall back to
# the interpreter next to ansible-playbook.
PY=python3
if ! "$PY" -c 'import jinja2' 2>/dev/null; then
    PY="$(dirname "$(readlink -f "$(command -v ansible-playbook)")")/python"
fi

failed=0
step() {
    printf '\n── %s\n' "$1"
    shift
    if "$@"; then printf '   ok\n'; else printf '   FAILED: %s\n' "$*"; failed=1; fi
}

syntax_check_playbooks() {
    rc=0
    for pb in ansible/playbooks/*.yml; do
        ansible-playbook "$pb" --syntax-check >/dev/null || { echo "syntax check failed: $pb"; rc=1; }
    done
    return "$rc"
}

# SC1091 excluded: the cases source ../lib/harness.sh at runtime on the
# container, a path shellcheck cannot follow from the repo. Scoped to tests/:
# scripts/ is not clean yet (see the workflow).
shellcheck_tests() {
    shellcheck -e SC1091 tests/*.sh tests/lib/*.sh tests/cases/*.sh tests/unit/*.sh
}

role_structure() {
    rc=0
    for role in ansible/roles/services/*/; do
        name=$(basename "$role")
        [ "$name" = "_skeleton" ] && continue
        [ -f "$role/tasks/main.yml" ] || { echo "$role missing tasks/main.yml"; rc=1; }
        [ -f "$role/defaults/main.yml" ] || { echo "$role missing defaults/main.yml"; rc=1; }
    done
    return "$rc"
}

step "ansible-lint" ansible-lint
step "Jinja2 syntax — all .j2 templates" "$PY" scripts/ci/check_jinja_syntax.py
step "Playbook syntax check" syntax_check_playbooks
step "ShellCheck the test harness" shellcheck_tests
step "Role structure" role_structure

if [ "$failed" -ne 0 ]; then
    printf '\nLINT FAILED\n'
    exit 1
fi
printf '\nLINT PASSED\n'
