#!/bin/bash
# Script to check if Unifi web interface is accessible
# Designed to work with enhanced_monitoring_wrapper for Slack notifications

set -e

if curl -s -f -k -o /dev/null --max-time 10 https://localhost:8443/manage/account/login?redirect=%2Fmanage; then
  echo "✅ Unifi controller web interface is accessible"
else
  echo "❌ Unifi controller web interface is not accessible - attempting to restart service"
  sudo systemctl restart unifi
  sleep 30
  if curl -s -f -k -o /dev/null --max-time 10 https://localhost:8443/manage/account/login?redirect=%2Fmanage; then
    echo "✅ Unifi controller web interface is now accessible after restart"
  else
    echo "❌ Unifi controller web interface is still not accessible after restart"
    exit 1
  fi
fi
