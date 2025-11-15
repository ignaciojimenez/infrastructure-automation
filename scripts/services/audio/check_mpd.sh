#!/bin/bash
set -e
if systemctl is-active --quiet mpd; then
  echo "✅ MPD service is running"
else
  echo "❌ MPD service is not running - attempting restart"
  sudo systemctl restart mpd
  sleep 5
  if systemctl is-active --quiet mpd; then
    echo "✅ MPD service was successfully restarted"
  else
    echo "❌ Failed to restart MPD service"
    exit 1
  fi
fi
