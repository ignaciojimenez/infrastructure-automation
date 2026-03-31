#!/bin/sh
# Tado presence detection health check
# Verifies device trackers are fresh and person entities are valid
# Runs on host (not inside Docker) — HA uses host networking
set -eu

SECRETS_FILE="${HOMEASSISTANT_CONFIG_DIR:-/home/choco/homeassistant}/secrets.yaml"
HA_TOKEN=$(grep '^ha_monitor_token:' "$SECRETS_FILE" | cut -d'"' -f2)
HA_URL="http://localhost:8123"

if [ -z "$HA_TOKEN" ]; then
    echo "❌ ha_monitor_token missing in secrets.yaml"
    exit 1
fi

python3 - "$HA_TOKEN" "$HA_URL" << 'PYEOF'
import json
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

token = sys.argv[1]
ha_url = sys.argv[2]

def get_state(entity_id):
    req = Request(f"{ha_url}/api/states/{entity_id}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    with urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

issues = []

trackers = [
    ("device_tracker.nexuschoky", "Choco Phone"),
    ("device_tracker.iphone_de_candela_2", "Candela iPhone"),
]

for tracker_id, tracker_name in trackers:
    try:
        st = get_state(tracker_id)
    except (HTTPError, URLError, TimeoutError) as e:
        issues.append(f"{tracker_name} API error: {e}")
        continue

    if st.get("state") == "unavailable":
        issues.append(f"{tracker_name} is unavailable")

persons = [("person.choco", "Choco"), ("person.candela", "Candela")]
for person_id, person_name in persons:
    try:
        st = get_state(person_id)
    except (HTTPError, URLError, TimeoutError) as e:
        issues.append(f"{person_name} person API error: {e}")
        continue

    state = st.get("state")
    if state in ("unknown", "unavailable"):
        issues.append(f"{person_name} person state is {state}")

if issues:
    for issue in issues:
        print(f"- {issue}")
    sys.exit(1)

print("OK — all presence trackers reporting normally")
sys.exit(0)
PYEOF
