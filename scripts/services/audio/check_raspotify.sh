#!/bin/bash
set -e
if systemctl is-active --quiet raspotify; then
  echo "✅ Raspotify service is running"
else
  echo "❌ Raspotify service is not running - attempting restart"
  sudo systemctl restart raspotify
  sleep 5
  if systemctl is-active --quiet raspotify; then
    echo "✅ Raspotify service was successfully restarted"
  else
    echo "❌ Failed to restart Raspotify service"
    exit 1
  fi
fi
