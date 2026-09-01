#!/bin/sh
# Ansible Vault password, read from the macOS Keychain item `ansible-vault-master`.
#
# ⚠️ On a FRESH MACHINE this will fail, and that is expected. The item lives in
# `login.keychain-db`, which is a local file and does NOT sync via iCloud — an
# earlier version of this comment claimed it did, which was wrong and would have
# stalled a recovery at the first playbook run.
#
# The durable copies are in Apple Passwords and Bitwarden. To restore this
# accessor on a new machine, paste it back once:
#
#     security add-generic-password -s ansible-vault-master -a "$USER" -w
#
# See docs/BACKUP_AND_RECOVERY.md -> "Recovering without the laptop".
if ! security find-generic-password -s ansible-vault-master -w 2>/dev/null; then
    echo "vault_pass.sh: keychain item 'ansible-vault-master' not found." >&2
    echo "  Restore it from Apple Passwords or Bitwarden, then retry:" >&2
    echo '  security add-generic-password -s ansible-vault-master -a "$USER" -w' >&2
    exit 1
fi
