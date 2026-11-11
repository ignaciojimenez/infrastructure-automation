#!/bin/sh
# unifi_state.py's capture() against a fake controller of each kind.
#
#   tests/unit/unifi_state_api_test.sh
#
# The migration's pass/fail (PER-127) diffs the standalone controller against
# UniFi OS Server, so the two modes must render the same state identically and
# differ only in how they reach it. The fake is strict where the real one is
# believed to be: UniFi OS answers only under /proxy/network, and only to a
# request carrying the session cookie and the CSRF token it issued at login.
# Pointing a mode at the other kind must fail, not return an empty snapshot.
#
# It proves the client against what aiounifi says UniFi OS does, not against
# UniFi OS itself. That runs in the PER-178 spike.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/unifi_state.py"
WORK=$(mktemp -d)
pids=''
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

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

# Starts a fake of one flavor; prints its port once it is listening.
start() {
    python3 -I "$WORK/fake.py" "$1" > "$WORK/port.$1" &
    pids="$pids $!"
    i=0
    while [ ! -s "$WORK/port.$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    cat "$WORK/port.$1"
}

capture() {  # capture <out> [--unifi-os] URL
    out=$1; shift
    printf '{"username": "ro", "password": "fixture-pw"}' \
        | python3 -I "$SCRIPT" "$@" > "$WORK/$out" 2> "$WORK/$out.err"
}

printf '\n── unifi-state capture: standalone and UniFi OS (PER-128, PER-178)\n'

standalone=$(start standalone)
unifi_os=$(start unifi-os)
if [ -z "$standalone" ] || [ -z "$unifi_os" ]; then
    fail "fake controllers did not start"; exit 1
fi

if capture old "http://127.0.0.1:$standalone" && capture new --unifi-os "http://127.0.0.1:$unifi_os"; then
    pass "both modes capture their own kind of controller"
else
    fail "a capture failed:"; cat "$WORK/old.err" "$WORK/new.err" | sed 's/^/       /'
fi

if [ -s "$WORK/old" ] && cmp -s "$WORK/old" "$WORK/new"; then
    pass "the same state renders identically from both: a clean migration diffs empty"
else
    fail "same state, different snapshot:"; diff -u "$WORK/old" "$WORK/new" | sed 's/^/       /'
fi

if grep -q '^controller 9.4.19$' "$WORK/old.err" && grep -q '^controller 11.0.99$' "$WORK/new.err"; then
    pass "each controller's version goes to stderr, not the snapshot"
else
    fail "controller version not reported on stderr"
fi

# The fake UniFi OS refuses a request without the CSRF token or outside
# /proxy/network, so these two only pass if the client fails loudly.
if capture wrong1 "http://127.0.0.1:$unifi_os"; then
    fail "standalone mode against UniFi OS succeeded"
elif [ -s "$WORK/wrong1" ]; then
    fail "standalone mode against UniFi OS wrote a partial snapshot"
else
    pass "standalone mode against UniFi OS fails, with no snapshot"
fi

if capture wrong2 --unifi-os "http://127.0.0.1:$standalone"; then
    fail "UniFi OS mode against a standalone controller succeeded"
else
    pass "UniFi OS mode against a standalone controller fails"
fi

if grep -q 'fixture-pw' "$WORK/old" "$WORK/new" "$WORK"/*.err; then
    fail "the password reached the output"
else
    pass "no password in snapshot or errors"
fi

[ "$failures" -eq 0 ]
