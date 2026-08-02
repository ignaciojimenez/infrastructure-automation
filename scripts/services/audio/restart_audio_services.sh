#!/bin/bash
set -e
echo "Performing weekly restart of audio services..."

# Restart MPD
sudo systemctl restart mpd
echo "MPD restarted"

# Restart Shairport-sync
sudo systemctl restart shairport-sync
echo "Shairport-sync restarted"

# Restart Raspotify
sudo systemctl restart raspotify
echo "Raspotify restarted"

# Reset hardware DAC volume to 100%
# Note: no software/PulseAudio 'Master' control exists in cron context (no user
# session), and this card has no such control at all — see docs/TODO.md.
/usr/bin/amixer -c 0 sset 'DAC' 100%
sudo /usr/sbin/alsactl store
echo "Audio volume reset to 100%"

echo "✅ Weekly audio services maintenance completed successfully"
