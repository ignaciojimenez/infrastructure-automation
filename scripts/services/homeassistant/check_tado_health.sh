#!/bin/bash
# Tado integration health monitoring for Home Assistant
set -euo pipefail

SECRETS_FILE="/config/secrets.yaml"
SLACK_WEBHOOK=$(grep "slack_alert_webhook" "$SECRETS_FILE" | cut -d"\"" -f2)
DB_PATH="/config/home-assistant_v2.db"

MAX_TRACKER_AGE_HOURS=2
ALERT_FILE="/tmp/tado_health_alert_sent"

send_slack_alert() {
    local message="$1"
    curl -s -X POST "$SLACK_WEBHOOK" -H "Content-Type: application/json" -d "{\"text\": \"$message\"}" > /dev/null
}

check_tado_health() {
    python3 << "PYEOF"
import sqlite3
import sys
from datetime import datetime, timedelta

conn = sqlite3.connect("/config/home-assistant_v2.db")
c = conn.cursor()

issues = []
now = datetime.now()
max_age = timedelta(hours=2)

trackers = [
    ("device_tracker.choco13mini", "Choco iPhone 13 Mini"),
    ("device_tracker.candelaiphone12mini", "Candela iPhone 12 Mini")
]

for tracker_id, tracker_name in trackers:
    c.execute("SELECT metadata_id FROM states_meta WHERE entity_id = ?", (tracker_id,))
    meta = c.fetchone()
    
    if not meta:
        issues.append(f"{tracker_name} tracker not found")
        continue
    
    c.execute("SELECT s.state, s.last_updated_ts FROM states s WHERE s.metadata_id = ? ORDER BY s.last_updated_ts DESC LIMIT 1", (meta[0],))
    state = c.fetchone()
    
    if not state:
        issues.append(f"{tracker_name} has no state history")
        continue
    
    current_state, last_updated_ts = state
    last_updated = datetime.fromtimestamp(last_updated_ts)
    age = now - last_updated
    
    if current_state == "unavailable":
        issues.append(f"{tracker_name} is unavailable")
    elif age > max_age:
        hours = int(age.total_seconds() / 3600)
        issues.append(f"{tracker_name} hasn't updated in {hours} hours")

persons = [("person.choco", "Choco"), ("person.candela", "Candela")]

for person_id, person_name in persons:
    c.execute("SELECT metadata_id FROM states_meta WHERE entity_id = ?", (person_id,))
    meta = c.fetchone()
    
    if not meta:
        issues.append(f"{person_name} person entity not found")
        continue
    
    c.execute("SELECT s.state FROM states s WHERE s.metadata_id = ? ORDER BY s.last_updated_ts DESC LIMIT 1", (meta[0],))
    state = c.fetchone()
    
    if state and state[0] == "unknown":
        issues.append(f"{person_name} person state is unknown")

conn.close()

if issues:
    print("ISSUES_FOUND")
    for issue in issues:
        print(f"- {issue}")
    sys.exit(1)
else:
    print("OK")
    sys.exit(0)
PYEOF
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
