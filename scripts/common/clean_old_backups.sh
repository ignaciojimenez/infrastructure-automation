#!/bin/bash
set -e
# Clean old backups - keeps only the most recent 7
BACKUP_DIR="${HOME}/homeassistant/backups"
if [ -d "$BACKUP_DIR" ]; then
    cd "$BACKUP_DIR" && \
    ls -A1t | tail -n +8 | xargs rm -v 2>/dev/null || true
fi
