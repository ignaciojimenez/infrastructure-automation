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
from datetime import datetime, timezone

def parse_time(time_str):
    """Parse ISO datetime string to datetime object."""
    if not time_str:
        return None
    try:
        return datetime.fromisoformat(time_str.replace("+0100", "+01:00").replace("+0200", "+02:00"))
    except:
        return None

def format_train(trip, now):
    """Format a single train's info. Returns None if train has departed."""
    legs = trip.get("legs", [])
    if not legs:
        return None
    
    leg = legs[0]
    origin = leg.get("origin", {})
    
    planned_time = origin.get("plannedDateTime", "")
    actual_time = origin.get("actualDateTime", planned_time)
    planned_track = origin.get("plannedTrack", "?")
    actual_track = origin.get("actualTrack", planned_track)
    
    # Parse departure time
    dept_dt = parse_time(actual_time) or parse_time(planned_time)
    if not dept_dt:
        return None
    
    # Skip trains that have already departed
    if dept_dt <= now:
        return None
    
    time_str = dept_dt.strftime("%H:%M")
    
    # Check for delay
    delay_info = ""
    planned_dt = parse_time(planned_time)
    if planned_dt and dept_dt > planned_dt:
        delay_mins = int((dept_dt - planned_dt).total_seconds() / 60)
        if delay_mins > 0:
            delay_info = f" (+{delay_mins}min)"
    
    # Check if cancelled
    status = trip.get("status", "")
    cancelled = "❌" if status == "CANCELLED" else ""
    
    return f"{time_str}{delay_info} → Platform *{actual_track}*{cancelled}"

try:
    data = json.loads('''$response''')
    trips = data.get("trips", [])
    
    if not trips:
        print("🚆 *Train to Amsterdam*\\n⚠️ No trains found")
        sys.exit(0)
    
    now = datetime.now().astimezone()
    
    # Get up to 3 future trains
    train_lines = []
    for trip in trips:
        line = format_train(trip, now)
        if line:
            train_lines.append(line)
        if len(train_lines) >= 3:
            break
    
    if not train_lines:
        print("🚆 *Train to Amsterdam*\\n⚠️ No upcoming trains")
        sys.exit(0)
    
    msg = "🚆 *Trains to Amsterdam*\\n"
    msg += "\\n".join(train_lines)
    
    print(msg)

except Exception as e:
    print(f"🚆 *Train to Amsterdam*\\n⚠️ Error: {e}")
PYEOF
)

# Send to Slack
curl -s -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$message\"}" > /dev/null

echo "Notification sent: $message"
