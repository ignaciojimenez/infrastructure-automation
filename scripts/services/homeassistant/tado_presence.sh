#!/bin/bash
# Tado presence lock script — sets home/away via Tado API
# Uses presenceLock endpoint to properly control Tado schedules
# without fighting HomeKit Controller or creating manual temperature holds.
#
# Before setting AWAY, cross-checks Tado's own mobile device tracking
# to guard against HA presence detection errors (GPS drift, dead phone).
# If any non-stale Tado device reports atHome, AWAY is skipped and a
# Slack alert is sent.
#
# Usage: tado_presence.sh HOME|AWAY
# Reads credentials from /config/.tado_tokens (created by tado_setup.sh)

set -euo pipefail

MODE="${1:-}"
if [ "$MODE" != "HOME" ] && [ "$MODE" != "AWAY" ]; then
    echo "Usage: $0 HOME|AWAY" >&2
    exit 1
fi

TOKENS_FILE="/config/.tado_tokens"
SECRETS_FILE="/config/secrets.yaml"
TADO_AUTH_URL="https://login.tado.com/oauth2/token"
TADO_API_URL="https://my.tado.com/api/v2"

# Read Slack webhook for error alerting
slack_alert() {
    local msg="$1"
    local webhook
    webhook=$(grep "slack_alert_webhook" "$SECRETS_FILE" | cut -d'"' -f2)
    if [ -n "$webhook" ]; then
        curl -s -X POST "$webhook" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"$msg\"}" > /dev/null 2>&1 || true
    fi
}

# Read tokens file
if [ ! -f "$TOKENS_FILE" ]; then
    echo "ERROR: $TOKENS_FILE not found. Run tado_setup.sh first." >&2
    slack_alert "⚠️ Tado presence script failed: tokens file not found"
    exit 1
fi

REFRESH_TOKEN=$(grep "refresh_token" "$TOKENS_FILE" | cut -d'"' -f2)
HOME_ID=$(grep "home_id" "$TOKENS_FILE" | cut -d'"' -f2)
CLIENT_ID=$(grep "client_id" "$TOKENS_FILE" | cut -d'"' -f2)

if [ -z "$REFRESH_TOKEN" ] || [ -z "$HOME_ID" ] || [ -z "$CLIENT_ID" ]; then
    echo "ERROR: Missing fields in $TOKENS_FILE" >&2
    slack_alert "⚠️ Tado presence script failed: incomplete tokens file"
    exit 1
fi

# Refresh OAuth2 access token
token_response=$(curl -s -X POST "$TADO_AUTH_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$REFRESH_TOKEN" \
    -d "client_id=$CLIENT_ID")

ACCESS_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
    echo "ERROR: Failed to refresh access token" >&2
    echo "Response: $token_response" >&2
    slack_alert "⚠️ Tado presence script failed: OAuth2 token refresh error"
    exit 1
}

# Extract new refresh token (Tado rotates tokens)
NEW_REFRESH_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null)

# Atomically update refresh token if rotated
if [ -n "$NEW_REFRESH_TOKEN" ] && [ "$NEW_REFRESH_TOKEN" != "$REFRESH_TOKEN" ]; then
    tmp_file=$(mktemp "${TOKENS_FILE}.XXXXXX")
    cat > "$tmp_file" << EOF
refresh_token: "$NEW_REFRESH_TOKEN"
home_id: "$HOME_ID"
client_id: "$CLIENT_ID"
EOF
    mv "$tmp_file" "$TOKENS_FILE"
    echo "Refresh token rotated"
fi

# Cross-check: before setting AWAY, verify no Tado device reports atHome
# Guards against HA presence detection errors (GPS drift, dead phone, etc.)
if [ "$MODE" = "AWAY" ]; then
    devices_response=$(curl -s \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${TADO_API_URL}/homes/${HOME_ID}/mobileDevices")

    devices_at_home=$(echo "$devices_response" | python3 -c "
import sys, json
try:
    devices = json.load(sys.stdin)
    at_home = [d['name'] for d in devices
               if d.get('location', {}).get('atHome') is True
               and not d.get('location', {}).get('stale', False)]
    print(','.join(at_home))
except Exception:
    print('')
" 2>/dev/null)

    if [ -n "$devices_at_home" ]; then
        echo "SKIPPED: Tado device(s) at home: $devices_at_home — not setting AWAY" >&2
        slack_alert "⚠️ Tado AWAY skipped — HA says nobody home but Tado device(s) still at home: $devices_at_home"
        exit 0
    fi
    echo "Tado cross-check passed: no devices at home"
fi

# Set presence lock
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${TADO_API_URL}/homes/${HOME_ID}/presenceLock" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"homePresence\": \"$MODE\"}")

if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "Tado presence set to $MODE (HTTP $http_code)"
else
    echo "ERROR: Failed to set Tado presence to $MODE (HTTP $http_code)" >&2
    slack_alert "⚠️ Tado presence script failed: HTTP $http_code setting $MODE"
    exit 1
fi
