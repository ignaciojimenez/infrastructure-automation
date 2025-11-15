#!/bin/bash
# Script to check if the Unifi service is running properly
# Designed to work with enhanced_monitoring_wrapper for Slack notifications

# Initialize arrays for tracking issues and actions
ALERTS=()
ACTIONS=()

# Check if unifi service is running
if ! sudo systemctl is-active --quiet unifi; then
    ALERTS+=("Unifi service is not running")
    ACTIONS+=("Attempting to restart Unifi service")
    
    # Try to restart the service
    sudo systemctl restart unifi
    sleep 10
    
    if ! sudo systemctl is-active --quiet unifi; then
        ALERTS+=("Failed to restart Unifi service")
    else
        ACTIONS+=("Unifi service restarted successfully")
    fi
fi

# Check if MongoDB process is running (part of Unifi)
if ! pgrep -f "mongod.*27117" > /dev/null; then
    ALERTS+=("MongoDB for Unifi is not running")
fi

# Check if Java process for Unifi is running
if ! pgrep -f "java.*unifi" > /dev/null; then
    ALERTS+=("Java process for Unifi is not running")
fi

# Output results for monitoring_wrapper
if [ ${#ALERTS[@]} -gt 0 ]; then
    echo "UNIFI SERVICE ALERTS:"
    for alert in "${ALERTS[@]}"; do
        echo "❌ $alert"
    done
    
    if [ ${#ACTIONS[@]} -gt 0 ]; then
        echo ""
        echo "ACTIONS TAKEN:"
        for action in "${ACTIONS[@]}"; do
            echo "✅ $action"
        done
    fi
    
    exit 1
else
    if [ ${#ACTIONS[@]} -gt 0 ]; then
        echo "UNIFI SERVICE STATUS: Fixed Issues"
        for action in "${ACTIONS[@]}"; do
            echo "✅ $action"
        done
    else
        echo "✅ Unifi service is running normally"
    fi
    exit 0
fi
