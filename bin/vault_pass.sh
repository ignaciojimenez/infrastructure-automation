#!/bin/sh
# Ansible Vault password — fetched from macOS Keychain item `ansible-vault-master`.
# Item is synced via iCloud Keychain, so a fresh laptop only needs the repo clone.
exec security find-generic-password -s ansible-vault-master -w
