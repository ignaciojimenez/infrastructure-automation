#!/bin/sh
# raspotify on hifipi: its MQTT hook cannot hang the unit's start, and its
# health check names a Spotify 403 instead of restarting into it (PER-62).
#
#   tests/unit/raspotify_test.sh
#   SH=dash tests/unit/raspotify_test.sh
#
# Runs against stubs. The hang was forced live on hifipi first (2026-10-12):
# the deployed hook ran for 150 s against an unroutable broker, past systemd's
# 90 s start limit.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
HOOK="$REPO_ROOT/ansible/roles/services/audio_playback/files/spotify_event.sh"
CHECK="$REPO_ROOT/scripts/services/audio/check_raspotify.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SH=${SH:-sh}

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

command -v timeout > /dev/null 2>&1 || { echo "SKIP: no timeout(1) on this machine"; exit 0; }
mkdir -p "$WORK/bin"

printf '\n── The MQTT hook is bounded when the broker never answers\n'
# A broker that never answers: mosquitto_pub blocks far longer than systemd waits.
# shellcheck disable=SC2016  # literal: written for another shell to expand
printf '#!/bin/sh\necho "$*" >> "%s/pub.log"\nsleep 60\n' "$WORK" > "$WORK/bin/mosquitto_pub"
chmod +x "$WORK/bin/mosquitto_pub"
s=$(date +%s)
MQTT_BROKER=10.255.255.1 PATH="$WORK/bin:$PATH" "$SH" "$HOOK" reset
rc=$? took=$(( $(date +%s) - s ))
if [ "$rc" -eq 0 ] && [ "$took" -le 15 ] && [ "$(wc -l < "$WORK/pub.log")" -eq 2 ]; then
    pass "reset returns 0 in ${took}s with both publishes attempted (each capped at 5 s)"
else
    fail "hook: rc=$rc took=${took}s pubs=$(wc -l < "$WORK/pub.log" 2>/dev/null)"
fi

printf '\n── The health check names a 403 instead of restarting into it\n'
# systemctl: inactive, and records any restart. sudo: runs its arguments
# (dropping -n). journalctl: prints $WORK/journal.
cat > "$WORK/bin/systemctl" <<EOF
#!/bin/sh
case "\$1" in
    is-active) exit 3 ;;
    restart) echo restart >> "$WORK/restarts" ;;
esac
EOF
# shellcheck disable=SC2016  # literal: written for another shell to expand
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$WORK/bin/sudo"
printf '#!/bin/sh\ncat "%s/journal"\n' "$WORK" > "$WORK/bin/journalctl"
printf '#!/bin/sh\n:\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/systemctl" "$WORK/bin/sudo" "$WORK/bin/journalctl" "$WORK/bin/sleep"

printf 'librespot[812]: [ERROR librespot] could not initialize spirc: Permission denied { 403 Forbidden }\n' > "$WORK/journal"
rm -f "$WORK/restarts"
PATH="$WORK/bin:$PATH" bash "$CHECK" > "$WORK/out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ ! -f "$WORK/restarts" ] && grep -q "Spotify refuses this host's egress IP" "$WORK/out"; then
    pass "403 in the unit's last lines: exit 1, the cause named, no restart"
else
    fail "403: rc=$rc restarts=$(cat "$WORK/restarts" 2>/dev/null) $(cat "$WORK/out")"
fi

printf 'librespot[812]: [ERROR librespot] Audio device not found\n' > "$WORK/journal"
rm -f "$WORK/restarts"
PATH="$WORK/bin:$PATH" bash "$CHECK" > "$WORK/out" 2>&1
if [ -f "$WORK/restarts" ] && ! grep -q "403\|refuses" "$WORK/out"; then
    pass "any other failure still gets the restart"
else
    fail "non-403: restarts=$(cat "$WORK/restarts" 2>/dev/null) $(cat "$WORK/out")"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ raspotify: all checks passed\n'
    exit 0
fi
printf '❌ raspotify: %s check(s) failed\n' "$failures"
exit 1
