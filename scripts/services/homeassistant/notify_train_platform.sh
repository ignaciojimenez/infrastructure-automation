#!/bin/bash
# Train platform notification script
# Calls NS API directly - more reliable than HA sensors which are disabled by default

set -euo pipefail

# Read secrets from HA secrets.yaml
SECRETS_FILE="/config/secrets.yaml"
NS_API_KEY=$(grep "ns_api_key" "$SECRETS_FILE" | cut -d'"' -f2)
SLACK_WEBHOOK=$(grep "slack_alert_webhook" "$SECRETS_FILE" | cut -d'"' -f2)

FROM_STATION="Den Haag Centraal"
TO_STATION="Amsterdam Centraal"

# URL encode station names
from_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FROM_STATION'))")
to_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TO_STATION'))")

# Call NS API
response=$(curl -s "https://gateway.apiportal.ns.nl/reisinformatie-api/api/v3/trips?fromStation=${from_encoded}&toStation=${to_encoded}" \
    -H "Ocp-Apim-Subscription-Key: ${NS_API_KEY}")

# Parse response and build message
message=$(python3 << PYEOF
import json
import sys
from datetime import datetime

try:
    data = json.loads('''$response''')
    trips = data.get("trips", [])
    
    if not trips:
        print("🚆 *Train to Amsterdam*\n⚠️ No trains found")
        sys.exit(0)
    
    # Get first trip
    trip = trips[0]
    legs = trip.get("legs", [])
    
    if not legs:
        print("🚆 *Train to Amsterdam*\n⚠️ No route info")
        sys.exit(0)
    
    leg = legs[0]
    origin = leg.get("origin", {})
    
    # Extract info
    planned_time = origin.get("plannedDateTime", "")
    actual_time = origin.get("actualDateTime", planned_time)
    planned_track = origin.get("plannedTrack", "?")
    actual_track = origin.get("actualTrack", planned_track)
    
    # Format time (extract HH:MM)
    if actual_time:
        try:
            dt = datetime.fromisoformat(actual_time.replace("+0100", "+01:00").replace("+0200", "+02:00"))
            time_str = dt.strftime("%H:%M")
        except:
            time_str = actual_time[:16] if len(actual_time) > 16 else actual_time
    else:
        time_str = "?"
    
    # Check for delay
    delay_info = ""
    if planned_time and actual_time and planned_time != actual_time:
        try:
            planned_dt = datetime.fromisoformat(planned_time.replace("+0100", "+01:00").replace("+0200", "+02:00"))
            actual_dt = datetime.fromisoformat(actual_time.replace("+0100", "+01:00").replace("+0200", "+02:00"))
            delay_mins = int((actual_dt - planned_dt).total_seconds() / 60)
            if delay_mins > 0:
                delay_info = f" (+{delay_mins} min delay)"
        except:
            pass
    
    # Check if train is cancelled
    status = trip.get("status", "")
    cancelled = status == "CANCELLED"
    
    # Build message
    msg = f"🚆 *Train to Amsterdam*\n"
    msg += f"Departure: {time_str}{delay_info}\n"
    msg += f"Platform: *{actual_track}*"
    
    if cancelled:
        msg += "\n⚠️ TRAIN CANCELLED"
    
    print(msg)

except Exception as e:
    print(f"🚆 *Train to Amsterdam*\n⚠️ Error: {e}")
PYEOF
)

# Send to Slack
curl -s -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$message\"}" > /dev/null

echo "Notification sent: $message"
