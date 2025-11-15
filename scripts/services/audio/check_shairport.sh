#!/bin/bash
set -e
if systemctl is-active --quiet shairport-sync; then
  echo "✅ Shairport-sync service is running"
else
  echo "❌ Shairport-sync service is not running - attempting restart"
  sudo systemctl restart shairport-sync
  sleep 5
  if systemctl is-active --quiet shairport-sync; then
    echo "✅ Shairport-sync service was successfully restarted"
  else
    echo "❌ Failed to restart Shairport-sync service"
    exit 1
  fi
fi
