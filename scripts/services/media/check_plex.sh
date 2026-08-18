#!/bin/bash
#
# Script to check Plex Media Server service status and restart if needed

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

# Announced maintenance windows — written by backup_plex_config, read here and
# by system_health_check.sh. Format: `<expiry-epoch> <free text>`.
MAINTENANCE_MARKER="${MAINTENANCE_DIR:-${HOME:-/nonexistent}/.maintenance}/plexmediaserver"

# True only while a window exists AND has not expired. Anything unparseable
# reads as "no window", so this fails closed: a corrupt marker gets Plex
# restarted, it does not get the check skipped.
maintenance_window_active() {
  [ -r "$MAINTENANCE_MARKER" ] || return 1
  local line deadline
  line=$(head -n 1 "$MAINTENANCE_MARKER" 2>/dev/null) || return 1
  deadline=${line%% *}
  case "$deadline" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$(date +%s)" -le "$deadline" ]
}

if systemctl is-active --quiet plexmediaserver; then
  echo "✅ Plex Media Server is running"
  exit 0
fi

# This runs `0 * * * *` and the backup runs `0 4 */7 * *` — the same minute,
# with no ordering between them. Without this branch, whichever cron won the
# race could see Plex mid-snapshot and "repair" it: `systemctl restart` while
# backup_plex_config is copying Preferences.xml yields a torn config in the
# archive, and the backup's own `start` afterwards is then a no-op that hides
# it. The self-heal is right in general and wrong inside a window someone
# announced.
if maintenance_window_active; then
  echo "⏸️  Plex Media Server is stopped inside an announced maintenance window - not restarting"
  exit 0
fi

echo "❌ Plex Media Server is not running - attempting restart"
sudo systemctl restart plexmediaserver
sleep 10
if systemctl is-active --quiet plexmediaserver; then
  echo "✅ Plex Media Server was successfully restarted"
  exit 0
else
  echo "❌ Failed to restart Plex Media Server"
  exit 1
fi
