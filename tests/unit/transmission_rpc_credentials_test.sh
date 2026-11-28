#!/bin/sh
# The Transmission role refuses to deploy without a real RPC password hash.
#
#   tests/unit/transmission_rpc_credentials_test.sh
#
# From 2025-11-15 the template fell back to `{changeme}`, which Transmission
# takes as a stored hash that matches no input. The 2026-08-23 run deployed it
# over the working settings and RPC stayed locked until someone tried to log in
# on 2026-11-28. This forces that condition and checks the role now stops on it:
#
#   1. The hash format, from Transmission 3.00's own vectors
#      (libtransmission/crypto-test.c, test_ssha1). They check the matcher used below.
#   2. bin/transmission-rpc-credentials generates hashes that matcher accepts,
#      and a wrong password does not match.
#   3. The template has no credential default left.
#   4. The role's assert, run by ansible-playbook on localhost: missing vars,
#      a vault var that does not exist, the old `{changeme}` and a plaintext
#      password all fail; Transmission's vector passes.
#
# Needs python3 and ansible-playbook on PATH; no host, no vault.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
ROLE="$REPO_ROOT/ansible/roles/services/transmission"
SCRIPT="$REPO_ROOT/bin/transmission-rpc-credentials"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

# tr_ssha1_matches, reimplemented: sha1(plain + salt), salt = everything after
# the brace and 40 hex characters.
matches() { # <ssha1> <plain>
    python3 -c '
import hashlib, sys
h, p = sys.argv[1], sys.argv[2]
ok = len(h) >= 41 and h[0] == "{" and hashlib.sha1((p + h[41:]).encode()).hexdigest() == h[1:41]
sys.exit(0 if ok else 1)
' "$1" "$2"
}

VECTOR='{15ad0621b259a84d24dcd4e75b09004e98a3627bAMbyRHJy'

printf '\n── transmission: RPC credentials\n'

# 1 ── the matcher agrees with Transmission
# shellcheck disable=SC2016  # the second vector's literal $ signs
if matches "$VECTOR" test \
    && matches '{10e2d7acbb104d970514a147cd16d51dfa40fb3c0OSwJtOL' 'QNY)(*#$B)!_X$B !_B#($^!)*&$%CV!#)&$C!@$(P*)'; then
    pass "matcher accepts both Transmission 3.00 test vectors"
else
    fail "matcher rejects a Transmission 3.00 test vector"
fi
if matches "$VECTOR" Test; then
    fail "matcher accepts a wrong password"
else
    pass "matcher rejects a wrong password (control)"
fi
if matches '{changeme}' changeme || matches '{changeme}' ''; then
    fail "the old placeholder matched an input"
else
    pass "the old placeholder {changeme} matches no input"
fi

# 2 ── the helper's generator, lifted from the script so the test runs its code
sed -n "/python3 -c '\$/,/^')\$/p" "$SCRIPT" | sed '1d;$d' > "$WORK/gen.py"
if [ -s "$WORK/gen.py" ]; then
    h1=$(printf '%s' 'correct horse' | python3 "$WORK/gen.py")
    h2=$(printf '%s' 'correct horse' | python3 "$WORK/gen.py")
    if printf '%s' "$h1" | grep -Eq '^[{][0-9a-f]{40}[./0-9A-Za-z]{8}$'; then
        pass "generated hash has Transmission's shape"
    else
        fail "generated hash has the wrong shape: ${#h1} chars"
    fi
    if matches "$h1" 'correct horse' && ! matches "$h1" 'correct horsf'; then
        pass "generated hash matches its password and not another"
    else
        fail "generated hash does not verify"
    fi
    if [ "$h1" != "$h2" ]; then
        pass "each run gets a fresh salt"
    else
        fail "two runs produced the same salt"
    fi
else
    fail "could not find the hash generator in $SCRIPT"
fi

# 3 ── no fallback in the template
TEMPLATE="$ROLE/templates/settings.json.j2"
if grep -E '"rpc-(password|username)"' "$TEMPLATE" | grep -q 'default('; then
    fail "the template still has a credential default"
else
    pass "the template has no credential default"
fi
if grep -q '"message-level": 1,' "$TEMPLATE"; then
    pass "message-level is 1, what the daemon writes back under --log-error"
else
    fail "message-level differs from the daemon's --log-error, so the file never converges"
fi

# 4 ── the role's assert, run for real. No repo ansible.cfg: no vault, no inventory.
command -v ansible-playbook > /dev/null 2>&1 || {
    fail "ansible-playbook not on PATH"
    printf '\n   %d FAILED\n\n' "$failures"
    exit 1
}
cat > "$WORK/play.yml" <<'EOF'
- name: Transmission credential guard
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Run the role's credential check
      ansible.builtin.import_role:
        name: services/transmission
        tasks_from: credentials
EOF

: > "$WORK/ansible.cfg"

guard() { # <vars yaml> → exit status of the play
    printf '%s\n' "$1" > "$WORK/vars.yml"
    (cd "$WORK" && ANSIBLE_CONFIG="$WORK/ansible.cfg" ANSIBLE_ROLES_PATH="$REPO_ROOT/ansible/roles" \
        ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
        ansible-playbook -i localhost, -c local play.yml -e @vars.yml > "$WORK/out" 2>&1)
}

# A failure counts only if the credential task is the one that failed: a play
# that never starts (bad config, missing role) also exits non-zero, and once
# made every case here read as a pass.
expect() { # <pass|fail> <label> <vars yaml>
    if guard "$3"; then
        got=pass
    elif grep -q '^fatal: \[localhost\]' "$WORK/out" \
        && grep -B3 '^fatal: \[localhost\]' "$WORK/out" | grep -q 'Require vault-backed RPC credentials'; then
        got=fail
    else
        got="an error outside the credential task"
    fi
    if [ "$got" = "$1" ]; then
        pass "$2 → $1"
    else
        fail "$2 → expected $1, got $got"
        sed 's/^/        /' "$WORK/out" | tail -8
    fi
}

expect fail "no credential vars" '{}'
expect fail "vault var not in vault (the production path)" \
    'transmission_rpc_username: admin
transmission_rpc_password_hash: "{{ vault_transmission_rpc_password_hash }}"'
expect fail "the old {changeme} placeholder" \
    'transmission_rpc_username: transmission
transmission_rpc_password_hash: "{changeme}"'
expect fail "a plaintext password" \
    'transmission_rpc_username: admin
transmission_rpc_password_hash: "hunter2hunter2"'
expect fail "the vault.yml.example placeholder" \
    'transmission_rpc_username: admin
transmission_rpc_password_hash: replace-me'
expect fail "an empty username" \
    "transmission_rpc_username: ''
transmission_rpc_password_hash: '$VECTOR'"
expect pass "Transmission's own test vector" \
    "transmission_rpc_username: admin
transmission_rpc_password_hash: '$VECTOR'"

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   ALL PASS\n\n'
    exit 0
fi
printf '   %d FAILED\n\n' "$failures"
exit 1
