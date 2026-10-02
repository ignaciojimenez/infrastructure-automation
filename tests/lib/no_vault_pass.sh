#!/bin/sh
# Vault "password" for the test rig — deliberately not one. Used by
# tests/rig_loop.sh via ANSIBLE_VAULT_PASSWORD_FILE.
#
# The rig's vault (ansible/inventory_test/group_vars/all/vault.yml) is
# plaintext and needs no password. But ansible.cfg names bin/vault_pass.sh, a
# macOS Keychain call that exits 1 on Linux, and Ansible aborts on that before
# it loads a single file — so the workbench could not run even a playbook that
# touches no secret.
#
# This answers with a string that decrypts nothing. Anything that reaches for
# the fleet's vault therefore fails closed ("Decryption failed"), rather than
# the rig quietly running with a secret it must never hold. Both halves were
# forced on 2026-10-03: a plaintext play runs, a play loading the fleet vault
# refuses.
echo "the-test-rig-holds-no-vault-password"
