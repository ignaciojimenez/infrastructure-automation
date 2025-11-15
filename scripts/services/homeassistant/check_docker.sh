#!/bin/bash
set -e
if systemctl is-active --quiet docker; then
  echo "✅ Docker service is running"
else
  echo "❌ Docker service is not running - attempting restart"
  sudo systemctl restart docker
  sleep 5
  if systemctl is-active --quiet docker; then
    echo "✅ Docker service was successfully restarted"
  else
    echo "❌ Failed to restart Docker service"
    exit 1
  fi
fi
