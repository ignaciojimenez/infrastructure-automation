#!/bin/bash
# Home Assistant (dockassist) Health Monitor

set -euo pipefail

# Configuration
CONTAINER_NAME="home-assistant"
HA_URL="http://localhost:8123"
LOG_FILE="$HOME/logs/dockassist_monitor.log"
ACTIONS_TAKEN=""

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to check Docker service
check_docker_service() {
    if systemctl is-active --quiet docker; then
        log_message "✅ Docker service is running"
        return 0
    else
        log_message "❌ Docker service is not running"
        
        # Try to start Docker
        log_message "🔄 Attempting to start Docker service"
        if sudo systemctl start docker; then
            log_message "✅ Successfully started Docker service"
            ACTIONS_TAKEN="${ACTIONS_TAKEN}Started Docker service; "
            return 0
        else
            log_message "❌ Failed to start Docker service"
            return 1
        fi
    fi
}

# Function to check Home Assistant container
check_ha_container() {
    if docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
        log_message "✅ Home Assistant container is running"
        return 0
    elif docker ps -aq -f name="$CONTAINER_NAME" | grep -q .; then
        log_message "❌ Home Assistant container exists but is stopped"
        
        # Try to start the container
        log_message "🔄 Attempting to start Home Assistant container"
        if docker start "$CONTAINER_NAME"; then
            log_message "✅ Successfully started Home Assistant container"
            ACTIONS_TAKEN="${ACTIONS_TAKEN}Started HA container; "
            sleep 10  # Give it time to start
            return 0
        else
            log_message "❌ Failed to start Home Assistant container"
            return 1
        fi
    else
        log_message "❌ Home Assistant container not found"
        return 1
    fi
}

# Function to check Home Assistant web interface
check_ha_web_interface() {
    local timeout=30
    local count=0
    
    while [ $count -lt $timeout ]; do
        if curl -s --connect-timeout 5 "$HA_URL" >/dev/null 2>&1; then
            log_message "✅ Home Assistant web interface is accessible"
            return 0
        fi
        
        sleep 2
        count=$((count + 2))
    done
    
    log_message "❌ Home Assistant web interface is not accessible after ${timeout}s"
    return 1
}

# Function to check disk space
check_disk_space() {
    local config_dir="$HOME/homeassistant"
    local usage=$(df "$config_dir" | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [ "$usage" -lt 90 ]; then
        log_message "✅ Disk space usage: ${usage}% (healthy)"
        return 0
    elif [ "$usage" -lt 95 ]; then
        log_message "⚠️  Disk space usage: ${usage}% (warning)"
        return 0
    else
        log_message "❌ Disk space usage: ${usage}% (critical)"
        
        # Try to clean up old logs and backups
        log_message "🧹 Attempting to clean up old files"
        
        # Clean old Home Assistant logs
        find "$config_dir" -name "home-assistant.log.*" -mtime +7 -delete 2>/dev/null || true
        
        # Clean old backup files (keep only 5 most recent)
        if [ -d "$config_dir/backups" ]; then
            cd "$config_dir/backups"
            ls -t *.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
        fi
        
        ACTIONS_TAKEN="${ACTIONS_TAKEN}Cleaned old files; "
        
        # Check space again
        local new_usage=$(df "$config_dir" | awk 'NR==2 {print $5}' | sed 's/%//')
        log_message "📊 Disk space after cleanup: ${new_usage}%"
        
        if [ "$new_usage" -lt 95 ]; then
            return 0
        else
            return 1
        fi
    fi
}

# Main monitoring logic
main() {
    log_message "🏠 Starting Home Assistant health check"
    
    local failed_checks=0
    local total_checks=0
    
    # Check Docker service
    total_checks=$((total_checks + 1))
    if ! check_docker_service; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Only proceed with container checks if Docker is running
    if systemctl is-active --quiet docker; then
        # Check Home Assistant container
        total_checks=$((total_checks + 1))
        if ! check_ha_container; then
            failed_checks=$((failed_checks + 1))
        fi
        
        # Check web interface (only if container is running)
        if docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
            total_checks=$((total_checks + 1))
            if ! check_ha_web_interface; then
                failed_checks=$((failed_checks + 1))
            fi
        fi
    fi
    
    # Check disk space
    total_checks=$((total_checks + 1))
    if ! check_disk_space; then
        failed_checks=$((failed_checks + 1))
    fi
    
    # Report results
    if [ $failed_checks -eq 0 ]; then
        log_message "✅ All Home Assistant checks passed ($total_checks checks)"
        if [ -n "$ACTIONS_TAKEN" ]; then
            echo "ACTIONS TAKEN: $ACTIONS_TAKEN"
        fi
        exit 0
    else
        log_message "❌ $failed_checks out of $total_checks checks failed"
        if [ -n "$ACTIONS_TAKEN" ]; then
            echo "ACTIONS TAKEN: $ACTIONS_TAKEN"
        fi
        exit 1
    fi
}

# Run main function
main "$@"
