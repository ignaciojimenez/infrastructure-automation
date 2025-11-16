#!/bin/bash
# Heartbeat check for Proxmox critical health
# Only sends heartbeat if VMs/CTs are running and ZFS is healthy

set -e

# Configuration
HEALTHCHECK_URL="{{ vault_healthcheck_proxmox_health }}"
SCRIPTS_DIR="${HOME}/.scripts/monitoring"

# Check critical health conditions
critical_ok=true

# Check VM/CT status
if ! "${SCRIPTS_DIR}/check_vm_status.sh" >/dev/null 2>&1; then
    critical_ok=false
fi

# Check ZFS health (allow it to not exist for non-ZFS systems)
if [ -f "${SCRIPTS_DIR}/check_zfs_health.sh" ]; then
    if ! "${SCRIPTS_DIR}/check_zfs_health.sh" >/dev/null 2>&1; then
        critical_ok=false
    fi
fi

# If all critical checks pass, send heartbeat
if [ "$critical_ok" = true ]; then
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 10 -t 3 -O /dev/null "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
fi

# Silent success - no output needed for cron
exit 0
