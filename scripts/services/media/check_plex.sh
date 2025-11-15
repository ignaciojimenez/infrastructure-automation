#!/bin/bash
# 
# Script to check Plex Media Server service status and restart if needed

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

if systemctl is-active --quiet plexmediaserver; then
  echo "✅ Plex Media Server is running"
  exit 0
else
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
fi
