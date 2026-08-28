#!/bin/sh
# Regression test: the Tier 1 sweep must ping its healthchecks.io check on
# EVERY run, and must never let that ping affect its own exit status.
#
# Runs on the laptop — no container, no fleet, no network, no spend. The
# template is rendered with test values and driven against stubs.
#
#   tests/unit/sweep_healthcheck_test.sh
#
# What this pins (the 2026-07/08 incident): agent-lxc executed ZERO jobs for
# its first 12 days. Every cron died on a redirect into a `logs_dir` that did
# not exist, before the script was reached — so nothing ran, nothing failed
# loudly, and nothing was logged. It went unnoticed for twelve days because
# agent-lxc was the only host in the fleet with no healthchecks.io check: the
# fleet observer was the one machine nobody was observing.
#
# Three properties are load-bearing, and two of them are easy to get exactly
# backwards:
#
#   * the ping fires when the sweep FINDS THINGS too. A dead-man's switch
#     gated on a clean run stops pinging the moment the fleet is unwell, which
#     conflates "the observer is dead" with "the fleet is broken" — the two
#     states it exists to tell apart. Findings already reach #home-alerts via
#     the wrapper; this covers silence, not findings.
#   * a failed ping is not a fleet finding. hc-ping.com being unreachable must
#     not turn a healthy sweep into a page.
#   * an absent URL degrades to "no ping", not to curling a literal `{{ … }}`.
#     `agent_sweep_healthcheck_url` defaults to '' precisely so a vault without
#     the entry renders a script that still works.
#
# ⚠️ Coverage note, stated rather than implied: agent-lxc has both curl and
# wget (measured 2026-08-06), so the deployed host always takes the curl
# branch. The wget branch is exercised here only by forcing curl off PATH.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SWEEP_TMPL="$REPO_ROOT/scripts/services/agent/fleet_health_check.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
STUB_DIR="$WORK/stub"
PINGS="$WORK/pings"
mkdir -p "$AGENT_DIR" "$STUB_DIR" "$WORK/bin"

PING_URL="https://hc-ping.example/00000000-0000-0000-0000-000000000000"

# ------------------------------------------------------------------
# Two renders: one with a URL configured, one with the vault entry absent.
# ------------------------------------------------------------------
render() {
    python3 "$REPO_ROOT/tests/lib/render_j2.py" "$SWEEP_TMPL" "$1" \
        agent_opnsense_api_pubkey_pin="sha256//eX/oOnHGacY+Z41pCAhi2/cxAREZHgcqW5ODY4yisJA=" \
        agent_opnsense_api_timeout=15 \
        agent_opnsense_monitoring_check_name="OPNsense monitoring alive" \
        agent_healthchecks_api_key_file="$AGENT_DIR/healthchecks_api.creds" \
        agent_opnsense_api_creds_path="$AGENT_DIR/opnsense_api.creds" \
        agent_opnsense_api_ip=10.30.40.254 \
        agent_disk_threshold=85 \
        agent_wrapper_max_age_hours=26 \
        agent_ssh_timeout=5 \
        agent_ssh_backoff_base_seconds=3600 \
        agent_ssh_backoff_max_seconds=21600 \
        agent_fleet_wide_threshold=3 \
        agent_sweep_healthcheck_url="$2" \
        agent_state_dir="$AGENT_DIR" \
        agent_fleet_hosts=cobra:linux,opnsense:linux || exit 1
}

render "$WORK/sweep.sh" "$PING_URL"
render "$WORK/sweep_nourl.sh" ""

# ------------------------------------------------------------------
# Stubs. `curl` and `wget` record the URL they were handed and obey a mode
# file, so "the ping was attempted" and "the ping failed" are separable.
# ------------------------------------------------------------------
cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
host=""
for a in "$@"; do
    case "$a" in *-agent) host="${a%-agent}" ;; esac
done
cat >/dev/null   # swallow the probe script
mode=ok
[ -f "$STUB_DIR/$host" ] && mode=$(cat "$STUB_DIR/$host")
case "$mode" in
    diskfull) echo "DISK=99" ;;
    *)        echo "DISK=10" ;;
esac
echo "FAILED=0"
echo "FAILEDUNITS="
echo "WRAPPER_LAST=$(date +%s)"
STUB

cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do url="$a"; done
printf 'curl %s\n' "$url" >> "$PINGS"
[ -f "$STUB_DIR/ping_fails" ] && exit 7
exit 0
STUB

cat > "$WORK/bin/wget" <<'STUB'
#!/bin/sh
for a in "$@"; do url="$a"; done
printf 'wget %s\n' "$url" >> "$PINGS"
exit 0
STUB

printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/getent"
chmod +x "$WORK"/bin/*

export STUB_DIR PINGS
PATH="$WORK/bin:$PATH"
export PATH

sweep() {
    : > "$PINGS"
    sh "$1" > "$WORK/out" 2>&1
    rc=$?
}
pinged() { grep -q " $PING_URL\$" "$PINGS"; }

# ==================================================================
printf '\n── The sweep pings on every run\n'
# ==================================================================

rm -f "$STUB_DIR"/*
sweep "$WORK/sweep.sh"
# Precondition: a test that asserts "pinged on a clean sweep" proves nothing if
# the sweep was not in fact clean.
if [ "$rc" -eq 0 ] && grep -q 'Fleet OK' "$WORK/out"; then
    if pinged; then
        pass "a clean sweep pings"
    else
        fail "a clean sweep did not ping — 12 days of silence is invisible again"
    fi
else
    fail "precondition: the clean sweep was not clean (rc=$rc): $(cat "$WORK/out")"
fi
if [ "$(wc -l < "$PINGS" | tr -d ' ')" = "1" ]; then
    pass "exactly one ping per run"
else
    fail "expected one ping, got $(wc -l < "$PINGS" | tr -d ' ')"
fi
if grep -q "^curl " "$PINGS"; then
    pass "curl is preferred when present"
else
    fail "curl was present but not used"
fi

# --- the case a gated implementation gets wrong ---------------------
echo diskfull > "$STUB_DIR/cobra"
sweep "$WORK/sweep.sh"
if [ "$rc" -ne 0 ] && grep -q 'disk usage 99%' "$WORK/out"; then
    if pinged; then
        pass "a sweep WITH findings still pings (it ran; that is what this asserts)"
    else
        fail "the ping is gated on a clean sweep — the observer looks dead whenever the fleet is unwell"
    fi
else
    fail "precondition: the sweep did not produce the expected finding (rc=$rc): $(cat "$WORK/out")"
fi

# ==================================================================
printf '\n── The ping can never change the verdict\n'
# ==================================================================

rm -f "$STUB_DIR"/*
: > "$STUB_DIR/ping_fails"
sweep "$WORK/sweep.sh"
if pinged; then
    pass "precondition: the ping was attempted and failed"
else
    fail "precondition: no ping attempted, so this proves nothing"
fi
if [ "$rc" -eq 0 ]; then
    pass "a failed ping leaves a healthy sweep exiting 0"
else
    fail "an unreachable hc-ping.com turned a healthy fleet into a page (rc=$rc)"
fi
if ! grep -q 'curl' "$WORK/out"; then
    pass "the ping is silent in the sweep's output"
else
    fail "curl noise leaked into the wrapper's Slack message"
fi
rm -f "$STUB_DIR/ping_fails"

# ==================================================================
printf '\n── No URL configured degrades to no ping\n'
# ==================================================================

sweep "$WORK/sweep_nourl.sh"
if [ "$rc" -eq 0 ] && grep -q 'Fleet OK' "$WORK/out"; then
    pass "an unconfigured check leaves the sweep working"
else
    fail "an empty URL broke the sweep (rc=$rc): $(cat "$WORK/out")"
fi
if [ -s "$PINGS" ]; then
    fail "pinged with no URL configured: $(cat "$PINGS")"
else
    pass "nothing is pinged"
fi

# ==================================================================
printf '\n── wget fallback, with curl off PATH\n'
# ==================================================================

# A restricted PATH is the only way to make `command -v curl` fail, so the
# fallback needs one built from just what the sweep calls. If any of these is
# missing the case aborts rather than passing vacuously.
NOCURL="$WORK/nocurl"
mkdir -p "$NOCURL"
missing=""
for u in sh date sed awk grep wc tr head cat rm mkdir mv mktemp; do
    p=$(command -v "$u" 2>/dev/null) || p=""
    if [ -n "$p" ]; then
        ln -sf "$p" "$NOCURL/$u"
    else
        missing="$missing $u"
    fi
done
ln -sf "$WORK/bin/ssh" "$NOCURL/ssh"
ln -sf "$WORK/bin/getent" "$NOCURL/getent"
ln -sf "$WORK/bin/wget" "$NOCURL/wget"

if [ -n "$missing" ]; then
    fail "cannot build a curl-free PATH, missing:$missing"
elif [ -n "$(PATH="$NOCURL" command -v curl 2>/dev/null)" ]; then
    fail "precondition: curl is still reachable, so the fallback was not exercised"
else
    : > "$PINGS"
    PATH="$NOCURL" sh "$WORK/sweep.sh" > "$WORK/out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'Fleet OK' "$WORK/out"; then
        pass "precondition: the sweep still runs without curl"
    else
        fail "precondition: the sweep broke without curl (rc=$rc): $(cat "$WORK/out")"
    fi
    if grep -q "^wget $PING_URL\$" "$PINGS"; then
        pass "wget carries the ping when curl is absent"
    else
        fail "no ping without curl: $(cat "$PINGS")"
    fi
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
