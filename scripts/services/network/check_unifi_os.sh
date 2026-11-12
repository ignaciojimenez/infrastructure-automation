#!/bin/bash
# Is UniFi OS Server up, and does it answer its devices? (PER-127)
# Designed to work with enhanced_monitoring_wrapper for Slack notifications.
#
# The UniFi OS sibling of check_unifi.sh + check_unifi_web.sh, in one script
# because one unit runs everything: uosserver.service starts a rootless podman
# container (user uosserver) that holds UniFi OS, the Network application and
# its MongoDB. Four checks, outermost first:
#
#   1. uosserver.service is active
#   2. the container is running (podman, as uosserver)
#   3. the console answers on the web port
#   4. the inform port answers HTTP: the port the APs report to. pasta accepts
#      the TCP connection on the host either way, so only an HTTP status
#      proves the Network application behind it is there.
#
# Self-healing like its siblings: one restart of the unit, then a recheck.
#
# Env overrides (tests): UNIFI_OS_WEB_URL, UNIFI_OS_INFORM_URL,
# UNIFI_OS_RESTART_WAIT.

WEB_URL="${UNIFI_OS_WEB_URL:-https://127.0.0.1:11443/}"
INFORM_URL="${UNIFI_OS_INFORM_URL:-http://127.0.0.1:8080/inform}"
RESTART_WAIT="${UNIFI_OS_RESTART_WAIT:-90}"

ALERTS=()
ACTIONS=()

# Rootless podman needs a working directory the uosserver user can read.
podman_uos() {
    (cd /tmp && sudo -u uosserver podman "$@")
}

# Fills FAILED with every check that does not pass.
run_checks() {
    FAILED=()
    if ! sudo systemctl is-active --quiet uosserver; then
        FAILED+=("uosserver service is not active")
    fi
    if [ "$(podman_uos container inspect --format '{{.State.Running}}' uosserver 2>/dev/null)" != "true" ]; then
        FAILED+=("uosserver container is not running")
    fi
    if ! curl -s -f -k -o /dev/null --max-time 10 "$WEB_URL"; then
        FAILED+=("UniFi OS console does not answer on $WEB_URL")
    fi
    code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$INFORM_URL")
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        FAILED+=("Network application does not answer on $INFORM_URL (the APs' inform port)")
    fi
}

run_checks
if [ ${#FAILED[@]} -gt 0 ]; then
    ALERTS+=("${FAILED[@]}")
    ACTIONS+=("Restarting uosserver")
    sudo systemctl restart uosserver
    sleep "$RESTART_WAIT"
    run_checks
    if [ ${#FAILED[@]} -gt 0 ]; then
        ALERTS+=("Still failing after the restart:" "${FAILED[@]}")
    else
        for alert in "${ALERTS[@]}"; do ACTIONS+=("Found: $alert"); done
        ACTIONS+=("UniFi OS Server answers again after the restart")
        ALERTS=()
    fi
fi

if [ ${#ALERTS[@]} -gt 0 ]; then
    echo "UNIFI OS SERVER ALERTS:"
    for alert in "${ALERTS[@]}"; do
        echo "❌ $alert"
    done
    echo ""
    echo "ACTIONS TAKEN:"
    for action in "${ACTIONS[@]}"; do
        echo "✅ $action"
    done
    exit 1
fi

if [ ${#ACTIONS[@]} -gt 0 ]; then
    echo "UNIFI OS SERVER STATUS: Fixed Issues"
    for action in "${ACTIONS[@]}"; do
        echo "✅ $action"
    done
else
    echo "✅ UniFi OS Server is running normally"
fi
exit 0
