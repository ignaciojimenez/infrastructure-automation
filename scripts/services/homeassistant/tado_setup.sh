#!/bin/bash
# Tado OAuth2 setup — one-time interactive script
# Run on dockassist (outside the HA container) to authorize Tado API access.
# Creates /home/choco/homeassistant/.tado_tokens for tado_presence.sh
#
# Usage: bash tado_setup.sh

set -euo pipefail

CLIENT_ID="1bb50063-6b0c-4d11-bd99-387f4a91cc46"
DEVICE_AUTH_URL="https://login.tado.com/oauth2/device_authorize"
TOKEN_URL="https://login.tado.com/oauth2/token"
API_URL="https://my.tado.com/api/v2"
TOKENS_FILE="/home/choco/homeassistant/.tado_tokens"

echo "=== Tado OAuth2 Device Authorization ==="
echo

# Step 1: Request device code
device_response=$(curl -s -X POST "$DEVICE_AUTH_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=$CLIENT_ID" \
    -d "scope=home.user offline_access")

DEVICE_CODE=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_code'])")
USER_CODE=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['user_code'])")
VERIFICATION_URL=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['verification_uri_complete'])")
INTERVAL=$(echo "$device_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('interval', 5))")

echo "Open this URL in your browser:"
echo
echo "  $VERIFICATION_URL"
echo
echo "Or go to https://login.tado.com/device and enter code: $USER_CODE"
echo
echo "Waiting for authorization..."

# Step 2: Poll for token
while true; do
    sleep "$INTERVAL"

    token_response=$(curl -s -X POST "$TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
        -d "device_code=$DEVICE_CODE" \
        -d "client_id=$CLIENT_ID")

    # Check for access_token in response
    access_token=$(echo "$token_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

    if [ -n "$access_token" ]; then
        echo "Authorization successful!"
        break
    fi

    # Check for error
    error=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null)

    if [ "$error" = "authorization_pending" ] || [ "$error" = "slow_down" ]; then
        printf "."
        continue
    fi

    echo "ERROR: Unexpected response: $token_response" >&2
    exit 1
done

# Extract refresh token
REFRESH_TOKEN=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['refresh_token'])")

# Step 3: Fetch home ID
echo
echo "Fetching Tado home ID..."
me_response=$(curl -s "${API_URL}/me" \
    -H "Authorization: Bearer $access_token")

HOME_ID=$(echo "$me_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['homes'][0]['id'])")

echo "Home ID: $HOME_ID"

# Step 4: Write tokens file
cat > "$TOKENS_FILE" << EOF
refresh_token: "$REFRESH_TOKEN"
home_id: "$HOME_ID"
client_id: "$CLIENT_ID"
EOF

chmod 600 "$TOKENS_FILE"

echo
echo "Tokens written to $TOKENS_FILE"
echo "You can now deploy and test tado_presence.sh"
