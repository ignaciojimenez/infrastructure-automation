#!/bin/bash
# 
# Script to check Samba service status and restart if needed

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

if systemctl is-active --quiet smbd; then
  echo "✅ Samba service is running"
  exit 0
else
  echo "❌ Samba service is not running - attempting restart"
  sudo systemctl restart smbd
  sleep 5
  if systemctl is-active --quiet smbd; then
    echo "✅ Samba service was successfully restarted"
    exit 0
  else
    echo "❌ Failed to restart Samba service"
    exit 1
  fi
fi
