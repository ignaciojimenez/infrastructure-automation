#!/bin/bash
# check_vm_status.sh
# Monitor status of specific VMs and containers on Proxmox
# Uses explicit list from configuration - will alert if any expected VM/CT is missing or down

set -euo pipefail

EXIT_OK=0
EXIT_WARNING=1
EXIT_CRITICAL=2

exit_code=$EXIT_OK
issues=()
warnings=()

# Configuration file path (deployed by Ansible)
CONFIG_FILE="${CONFIG_FILE:-/home/choco/.scripts/monitoring/vm_ct_config.txt}"

# Arrays to store expected VMs and CTs
declare -A EXPECTED_VMS  # vmid -> name
declare -A EXPECTED_CTS  # ctid -> name

# Read configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "CRITICAL: Configuration file $CONFIG_FILE not found"
    echo "Expected format:"
    echo "VM 100 OPNsense"
    echo "CT 101 unifi"
    exit $EXIT_CRITICAL
fi

# Parse config file
while read -r type id name; do
    case "$type" in
        VM)
            EXPECTED_VMS[$id]="$name"
            ;;
        CT)
            EXPECTED_CTS[$id]="$name"
            ;;
        \#*|"")
            # Skip comments and empty lines
            ;;
        *)
            warnings+=("Unknown type '$type' in config file (line: $type $id $name)")
            ;;
    esac
done < "$CONFIG_FILE"

# If no VMs/CTs configured, that's an error
if [ ${#EXPECTED_VMS[@]} -eq 0 ] && [ ${#EXPECTED_CTS[@]} -eq 0 ]; then
    echo "CRITICAL: No VMs or CTs configured in $CONFIG_FILE"
    exit $EXIT_CRITICAL
fi

# Check if VM exists and is running
check_vm() {
    local vmid=$1
    local expected_name=$2
    local status
    
    # Check if VM exists
    if ! sudo qm status "$vmid" >/dev/null 2>&1; then
        issues+=("CRITICAL: VM $vmid ($expected_name) does not exist")
        exit_code=$EXIT_CRITICAL
        return
    fi
    
    status=$(sudo qm status "$vmid" 2>/dev/null | awk '{print $2}')
    
    if [ "$status" != "running" ]; then
        issues+=("CRITICAL: VM $vmid ($expected_name) is $status")
        exit_code=$EXIT_CRITICAL
    fi
}

# Check if container exists and is running
check_ct() {
    local ctid=$1
    local expected_name=$2
    local status
    
    # Check if CT exists
    if ! sudo pct status "$ctid" >/dev/null 2>&1; then
        issues+=("CRITICAL: CT $ctid ($expected_name) does not exist")
        exit_code=$EXIT_CRITICAL
        return
    fi
    
    status=$(sudo pct status "$ctid" 2>/dev/null | awk '{print $2}')
    
    if [ "$status" != "running" ]; then
        issues+=("CRITICAL: CT $ctid ($expected_name) is $status")
        exit_code=$EXIT_CRITICAL
    fi
}

# Check all expected VMs
for vmid in "${!EXPECTED_VMS[@]}"; do
    check_vm "$vmid" "${EXPECTED_VMS[$vmid]}"
done

# Check all expected containers
for ctid in "${!EXPECTED_CTS[@]}"; do
    check_ct "$ctid" "${EXPECTED_CTS[$ctid]}"
done

# Output results
if [ ${#issues[@]} -gt 0 ]; then
    echo "CRITICAL VM/CT ISSUES:"
    printf '%s\n' "${issues[@]}"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo "WARNINGS:"
    printf '%s\n' "${warnings[@]}"
fi

if [ $exit_code -eq $EXIT_OK ]; then
    vm_count=${#EXPECTED_VMS[@]}
    ct_count=${#EXPECTED_CTS[@]}
    echo "OK: All expected VMs and containers are running ($vm_count VMs, $ct_count CTs)"
fi

exit $exit_code
