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

# Reset audio volume to 100%
/usr/bin/amixer sset 'Digital',0 100%
/usr/bin/amixer sset 'Analogue',0 100%
sudo /usr/sbin/alsactl store
echo "Audio volume reset to 100%"

echo "✅ Weekly audio services maintenance completed successfully"
