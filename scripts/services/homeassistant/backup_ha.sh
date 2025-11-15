#!/bin/bash
# Home Assistant Backup Script

set -euo pipefail

CONTAINER_NAME="home-assistant"
CONFIG_DIR="$HOME/homeassistant"
BACKUP_DIR="$CONFIG_DIR/backups"
LOG_FILE="$HOME/logs/ha_backup.log"
BACKUP_RETENTION_DAYS=30

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to create backup
create_backup() {
    local backup_type="${1:-manual}"
    local backup_name="ha_${backup_type}_$(date +%Y%m%d_%H%M%S)"
    local backup_file="$BACKUP_DIR/${backup_name}.tar.gz"
    
    log_message "📦 Creating $backup_type backup: $backup_name"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Create backup excluding unnecessary files
    if tar -czf "$backup_file" -C "$CONFIG_DIR" --exclude="backups" --exclude="*.log" .; then
        local size=$(du -h "$backup_file" | cut -f1)
        log_message "✅ Backup created successfully: $backup_file ($size)"
        
        # Clean up old backups based on type
        cleanup_old_backups "$backup_type"
        
        echo "$backup_file"
        return 0
    else
        log_message "❌ Failed to create backup"
        return 1
    fi
}

# Function to cleanup old backups
cleanup_old_backups() {
    local backup_type="$1"
    local keep_count
    
    case "$backup_type" in
        "manual")
            keep_count=10
            ;;
        "auto")
            keep_count=7
            ;;
        *)
            keep_count=5
            ;;
    esac
    
    log_message "🧹 Cleaning up old $backup_type backups (keeping $keep_count)"
    
    cd "$BACKUP_DIR"
    ls -t ha_${backup_type}_*.tar.gz 2>/dev/null | tail -n +$((keep_count + 1)) | xargs rm -f 2>/dev/null || true
}

# Function to list backups
list_backups() {
    log_message "📋 Available backups:"
    
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
        cd "$BACKUP_DIR"
        ls -lht *.tar.gz | while read -r line; do
            echo "  $line"
        done
    else
        echo "  No backups found"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 {create|list} [options]"
    echo ""
    echo "Commands:"
    echo "  create [manual|auto]  - Create backup (default: manual)"
    echo "  list                  - List available backups"
    echo ""
    echo "Examples:"
    echo "  $0 create"
    echo "  $0 create auto"
    echo "  $0 list"
    exit 1
}

# Main execution
main() {
    case "${1:-}" in
        "create")
            local backup_type="${2:-manual}"
            create_backup "$backup_type"
            ;;
        "list")
            list_backups
            ;;
        *)
            show_usage
            ;;
    esac
}

# Run main function
main "$@"
