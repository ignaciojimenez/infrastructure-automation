#!/bin/bash
set -e
if systemctl is-active --quiet raspotify; then
  echo "✅ Raspotify service is running"
# Spotify refusing this host's egress IP (2026-09-13: a Mullvad exit) kills
# librespot with this line, and no restart can change the IP (PER-62). Say so
# instead of restarting, so the alert names the cause. Only the unit's last
# lines count: a 403 that has since cleared must not excuse a different crash.
elif sudo -n journalctl -u raspotify -n 30 --no-pager 2>/dev/null | grep -q "403 Forbidden"; then
  echo "❌ Raspotify is down: Spotify refuses this host's egress IP (403 Forbidden in raspotify's journal)."
  echo "   A restart cannot fix it. Check the route out (docs/TODO.md item 38); not restarting."
  exit 1
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
