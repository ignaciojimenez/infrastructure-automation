#!/bin/bash
# 
# Script to check Transmission daemon service status and restart if needed

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

if systemctl is-active --quiet transmission-daemon; then
  echo "✅ Transmission daemon is running"
  exit 0
else
  echo "❌ Transmission daemon is not running - attempting restart"
  sudo systemctl restart transmission-daemon
  sleep 5
  if systemctl is-active --quiet transmission-daemon; then
    echo "✅ Transmission daemon was successfully restarted"
    exit 0
  else
    echo "❌ Failed to restart Transmission daemon"
    exit 1
  fi
fi
