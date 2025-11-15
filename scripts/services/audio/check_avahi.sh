#!/bin/bash
set -e
if systemctl is-active --quiet avahi-daemon; then
  echo "✅ Avahi daemon is running"
else
  echo "❌ Avahi daemon is not running - attempting restart"
  sudo systemctl restart avahi-daemon
  sleep 5
  if systemctl is-active --quiet avahi-daemon; then
    echo "✅ Avahi daemon was successfully restarted"
  else
    echo "❌ Failed to restart Avahi daemon"
    exit 1
  fi
fi
