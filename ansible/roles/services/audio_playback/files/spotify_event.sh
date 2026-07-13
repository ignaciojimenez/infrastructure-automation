#!/bin/sh
# Managed by Ansible — librespot (raspotify) --onevent hook.
# Publishes Spotify Connect playback state to MQTT for Home Assistant.
#
# librespot sets PLAYER_EVENT for each event and inherits the MQTT_* variables
# from the raspotify EnvironmentFile (/etc/raspotify/conf, mode 0600). State is
# published retained so HA always holds the current value.
#
# Invoked as "spotify_event.sh reset" from ExecStartPre to clear stale state
# (e.g. a retained "playing" left over across a reboot).

# Never fail the caller — a broker blip must not block raspotify from starting.
[ -n "$MQTT_BROKER" ] || exit 0

pub() {
    mosquitto_pub -h "$MQTT_BROKER" -p "${MQTT_PORT:-1883}" \
        -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
        -r -t "${MQTT_TOPIC:-raspotify/hifipi}/$1" -m "$2" 2>/dev/null || true
}

event="${1:-$PLAYER_EVENT}"
case "$event" in
    playing)                      pub state playing; pub playing 1 ;;
    paused)                       pub state paused;  pub playing 0 ;;
    stopped|session_disconnected) pub state stopped; pub playing 0 ;;
    reset)                        pub state stopped; pub playing 0 ;;
esac

exit 0
