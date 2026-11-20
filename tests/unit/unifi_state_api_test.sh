#!/bin/sh
# unifi_state.py's capture() against a fake UniFi OS Server.
#
#   tests/unit/unifi_state_api_test.sh
#
# The fake is strict where the real one is: UniFi OS answers only under
# /proxy/network, and only to a request carrying the session cookie and the
# CSRF token it issued at login. A server that does not (the fake's
# "standalone" flavor, the API of the retired Network Application) must make
# the capture fail, not return an empty or partial snapshot.
#
# It proves the client against what aiounifi says UniFi OS does. The real
# server was read the same way at the PER-127 cutover (2026-11-15).

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/unifi_state.py"
WORK=$(mktemp -d)
pids=''
cleanup() {
    for pid in $pids; do kill "$pid" 2>/dev/null; done
    for pid in $pids; do wait "$pid" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

cat > "$WORK/fake.py" <<'EOF'
import http.server, json, sys
FLAVOR = sys.argv[1]
PREFIX = "/proxy/network" if FLAVOR == "unifi-os" else ""
LOGIN = "/api/auth/login" if FLAVOR == "unifi-os" else "/api/login"
DATA = {
    "/api/self/sites": [{"name": "default", "desc": "Default"}],
    "/api/s/default/stat/device": [{"mac": "02:00:00:00:00:01", "name": "AP One", "model": "UAL6",
                                    "type": "uap", "adopted": True, "state": 1, "version": "6.8.2"}],
    "/api/s/default/rest/networkconf": [{"_id": "n1", "name": "LAN", "purpose": "corporate",
                                         "vlan_enabled": False, "ip_subnet": "10.0.0.1/24", "enabled": True}],
    "/api/s/default/rest/wlanconf": [{"_id": "w1", "name": "Home Net", "enabled": True,
                                      "networkconf_id": "n1", "security": "wpapsk", "wpa_mode": "wpa2",
                                      "hide_ssid": False, "is_guest": False}],
    "/api/s/default/stat/sysinfo": [{"version": "11.0.99" if FLAVOR == "unifi-os" else "9.4.19"}],
}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body, headers=()):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def authorised(self):
        if "session=ok" not in (self.headers.get("Cookie") or ""):
            return False
        return FLAVOR != "unifi-os" or self.headers.get("x-csrf-token") == "csrf-1"
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == LOGIN:
            extra = [("Set-Cookie", "session=ok; Path=/")]
            if FLAVOR == "unifi-os":
                extra.append(("x-csrf-token", "csrf-1"))
            return self.reply(200, {"meta": {"rc": "ok"}, "data": []}, extra)
        if self.path.endswith("/logout"):
            return self.reply(200, {"meta": {"rc": "ok"}, "data": []})
        self.reply(404, {"meta": {"rc": "error", "msg": "api.err.NotFound"}})
    def do_GET(self):
        if not self.path.startswith(PREFIX) or self.path[len(PREFIX):] not in DATA:
            return self.reply(404, {"meta": {"rc": "error", "msg": "api.err.NotFound"}})
        if not self.authorised():
            return self.reply(401, {"meta": {"rc": "error", "msg": "api.err.LoginRequired"}})
        self.reply(200, {"meta": {"rc": "ok"}, "data": DATA[self.path[len(PREFIX):]]})

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
EOF

# Starts a fake of one flavor. Called directly, never inside $(...): a
# subshell would keep the PID from the trap, and the orphaned server would
# hold the caller's output pipe open (it hung run_unit_tests.sh once).
# stderr goes to /dev/null for the same reason.
start() {
    python3 -I "$WORK/fake.py" "$1" > "$WORK/port.$1" 2>/dev/null &
    pids="$pids $!"
}

# Prints a fake's port once it is listening, or nothing after 5 s.
port() {
    i=0
    while [ ! -s "$WORK/port.$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    cat "$WORK/port.$1" 2>/dev/null
}

capture() {  # capture <out> [ARG...]
    out=$1; shift
    printf '{"username": "ro", "password": "fixture-pw"}' \
        | python3 -I "$SCRIPT" "$@" > "$WORK/$out" 2> "$WORK/$out.err"
}

printf '\n── unifi-state capture: UniFi OS Server (PER-128)\n'

start standalone
start unifi-os
standalone=$(port standalone)
unifi_os=$(port unifi-os)
if [ -z "$standalone" ] || [ -z "$unifi_os" ]; then
    fail "fake controllers did not start"; exit 1
fi

# The fake refuses a request without the cookie or the CSRF token, or outside
# /proxy/network, so a capture only succeeds if the client sends all three.
if capture new "http://127.0.0.1:$unifi_os"; then
    pass "captures UniFi OS: login, cookie, CSRF token, /proxy/network"
else
    fail "the capture failed:"; sed 's/^/       /' "$WORK/new.err"
fi

if grep -q '^device "default" "02:00:00:00:00:01" .*adopted=true state=1 ' "$WORK/new" \
    && grep -q '^wlan "default" "Home Net" ' "$WORK/new"; then
    pass "the snapshot holds the controller's devices and WLANs"
else
    fail "the snapshot is missing state:"; sed 's/^/       /' "$WORK/new"
fi

if grep -q '^controller 11.0.99$' "$WORK/new.err" && ! grep -q '11.0.99' "$WORK/new"; then
    pass "the controller's version goes to stderr, not the snapshot"
else
    fail "controller version not reported on stderr only"
fi

if capture wrong "http://127.0.0.1:$standalone"; then
    fail "a server without UniFi OS's API was captured"
elif [ -s "$WORK/wrong" ]; then
    fail "a server without UniFi OS's API left a partial snapshot"
else
    pass "a server without UniFi OS's API fails, with no snapshot"
fi

if capture flag --unifi-os; then
    fail "the retired --unifi-os flag was accepted"
elif grep -q '^usage:' "$WORK/flag.err"; then
    pass "the retired --unifi-os flag gets the usage line, not a traceback"
else
    fail "the retired --unifi-os flag:"; sed 's/^/       /' "$WORK/flag.err"
fi

if grep -q 'fixture-pw' "$WORK/new" "$WORK"/*.err; then
    fail "the password reached the output"
else
    pass "no password in snapshot or errors"
fi

[ "$failures" -eq 0 ]
