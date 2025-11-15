#!/bin/bash
set -e
if curl -s -f -k -o /dev/null --max-time 10 http://localhost:8123; then
  echo "✅ Home Assistant web interface is accessible"
else
  echo "❌ Home Assistant web interface is not accessible - attempting to restart container"
  docker restart home-assistant
  sleep 30
  if curl -s -f -k -o /dev/null --max-time 10 http://localhost:8123; then
    echo "✅ Home Assistant web interface is now accessible after restart"
  else
    echo "❌ Home Assistant web interface is still not accessible after restart"
    exit 1
  fi
fi
