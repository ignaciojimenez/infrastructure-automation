#!/bin/bash
#
# Script to check audio output and volume settings
# Targets the HiFiBerry DAC+ HD hardware mixer on card 0

set -e          # stop on errors
set -u          # stop on unset variables
set -o pipefail # stop on pipe failures

# Check if ALSA is working properly
if aplay -l | grep -q 'card'; then
  # Check hardware DAC volume (card 0, HiFiBerry DAC+ HD)
  # Take the first percentage amixer prints. Do NOT filter by channel label:
  # a stereo control also prints an empty 'Mono:' line, which yields a blank
  # field, makes VOLUME multi-line, and silently disables the check below.
  VOLUME=$(amixer -c 0 sget 'DAC',0 | grep -oE '[0-9]+%' | head -1 | tr -d '%')
  # Make sure VOLUME is a number before comparing
  if [[ "$VOLUME" =~ ^[0-9]+$ ]] && [ "$VOLUME" -lt "90" ]; then
    echo "❌ Hardware DAC volume is too low ($VOLUME%) - setting to 100%"
    amixer -c 0 sset 'DAC' 100%
    sudo /usr/sbin/alsactl store
    echo "✅ Hardware DAC volume has been reset to 100%"
    exit 0
  else
    echo "✅ Audio system is configured correctly (DAC volume: $VOLUME%)"
    exit 0
  fi
else
  echo "❌ No audio devices found"
  exit 1
fi

