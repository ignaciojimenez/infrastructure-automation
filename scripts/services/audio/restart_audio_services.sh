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

# Reset hardware DAC and software master volume to 100%
/usr/bin/amixer -c 0 sset 'DAC' 100%
/usr/bin/amixer sset 'Master' 100%
sudo /usr/sbin/alsactl store
echo "Audio volume reset to 100%"

echo "✅ Weekly audio services maintenance completed successfully"
