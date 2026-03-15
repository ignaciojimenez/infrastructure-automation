#!/bin/bash
# Tado integration health monitoring for Home Assistant
set -euo pipefail

SECRETS_FILE="/config/secrets.yaml"
SLACK_WEBHOOK=$(grep "slack_alert_webhook" "$SECRETS_FILE" | cut -d"\"" -f2)
HA_TOKEN=$(grep '^ha_monitor_token:' "$SECRETS_FILE" | cut -d'"' -f2)
HA_URL="http://localhost:8123"

MAX_TRACKER_AGE_HOURS=2
ALERT_FILE="/tmp/tado_health_alert_sent"

send_slack_alert() {
    local message="$1"
    curl -s -X POST "$SLACK_WEBHOOK" -H "Content-Type: application/json" -d "{\"text\": \"$message\"}" > /dev/null
}

check_tado_health() {
    if [ -z "$HA_TOKEN" ]; then
        echo "ISSUES_FOUND"
        echo "- ha_monitor_token missing in secrets.yaml"
        return 1
    fi

    python3 - << 'PYEOF'
import json
import sys
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

HA_URL = "http://localhost:8123"

def get_state(entity_id: str, token: str):
    url = f"{HA_URL}/api/states/{entity_id}"
    req = Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body)

token = None
# token passed via env var injected below
token = sys.argv[1]

issues = []
now = datetime.now(timezone.utc)
max_age = timedelta(hours=2)

trackers = [
    ("device_tracker.choco13mini", "Choco iPhone 13 Mini"),
    ("device_tracker.candelaiphone12mini", "Candela iPhone 12 Mini"),
]

for tracker_id, tracker_name in trackers:
    try:
        st = get_state(tracker_id, token)
    except (HTTPError, URLError, TimeoutError) as e:
        issues.append(f"{tracker_name} API error: {e}")
        continue

    state = st.get("state")
    lu = st.get("last_updated")
    if not lu:
        issues.append(f"{tracker_name} missing last_updated")
        continue

    try:
        last_updated = datetime.fromisoformat(lu.replace("Z", "+00:00"))
    except Exception:
        issues.append(f"{tracker_name} invalid last_updated format: {lu}")
        continue

    age = now - last_updated
    if state == "unavailable":
        issues.append(f"{tracker_name} is unavailable")
    elif age > max_age:
        hours = int(age.total_seconds() / 3600)
        issues.append(f"{tracker_name} hasn't updated in {hours} hours")

persons = [("person.choco", "Choco"), ("person.candela", "Candela")]
for person_id, person_name in persons:
    try:
        st = get_state(person_id, token)
    except (HTTPError, URLError, TimeoutError) as e:
        issues.append(f"{person_name} person API error: {e}")
        continue

    state = st.get("state")
    if state in ("unknown", "unavailable"):
        issues.append(f"{person_name} person state is {state}")

if issues:
    print("ISSUES_FOUND")
    for issue in issues:
        print(f"- {issue}")
    sys.exit(1)

print("OK")
sys.exit(0)
PYEOF "$HA_TOKEN"
}

result=$(check_tado_health)
exit_code=$?

if [ $exit_code -ne 0 ]; then
    if [ ! -f "$ALERT_FILE" ]; then
        message="⚠️ *Tado Health Check Failed*\n$result"
        send_slack_alert "$message"
        touch "$ALERT_FILE"
        echo "Alert sent: Tado health issues detected"
    else
        echo "Issues persist (alert already sent)"
    fi
    exit 1
else
    if [ -f "$ALERT_FILE" ]; then
        send_slack_alert "✅ *Tado Health Restored*\nAll device trackers are updating normally"
        rm -f "$ALERT_FILE"
        echo "Recovery notification sent"
    else
        echo "Tado health check: OK"
    fi
    exit 0
fi
