#!/bin/sh
# Regression test: the Tier 1 sweep's resolver pre-check must ask DNS for the
# name the SSH probes actually dial — <host>.$fleet_dns_domain — and nothing
# looser.
#
# Runs on the laptop — no container, no fleet, no network, no spend.
#
#   tests/unit/sweep_resolver_test.sh
#
# The pre-check used to look up the bare first host and lean on the
# container's `search local` domain. When fleet names moved from `.local` to
# Dnsmasq's `internal` domain (2026-11), that would have left a check able to
# pass on an answer ssh never uses: bare `cobra` still resolving through a
# stale search domain while `cobra.internal` — the HostName in ssh_config —
# does not. Every SSH probe would then fail and the sweep would blame seven
# healthy hosts, which is exactly what the pre-check exists to prevent.
#
# The stub `getent` below answers only the names it is told to, so each case
# forces one side of that condition and watches the branch fire.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/services/agent/fleet_health_check.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
mkdir -p "$AGENT_DIR" "$WORK/bin"

printf '\n── Tier 1 resolver pre-check\n'

render() {
    # render <fleet_dns_domain>
    python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/sweep.sh" \
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
        agent_state_dir="$AGENT_DIR" \
        agent_sweep_healthcheck_url="" \
        fleet_dns_domain="$1" \
        agent_fleet_hosts=cobra:linux,hifipi:linux || exit 1
}
# ^ healthcheck URL deliberately empty, as in sweep_absence_test.sh: the
# sweep's "do not ping" path, which keeps this test off the network.

# Answers only the names listed in $RESOLVABLE, and records every lookup.
cat > "$WORK/bin/getent" <<'STUB'
#!/bin/sh
echo "$2" >> "$WORK/lookups"
for n in $RESOLVABLE; do
    [ "$n" = "$2" ] && { echo "10.30.40.204 $2"; exit 0; }
done
exit 2
STUB
# Healthy probe output, plus a record of which hosts were dialled.
cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
for a in "$@"; do
    case "$a" in *-agent) echo "${a%-agent}" >> "$WORK/dialled" ;; esac
done
cat >/dev/null
echo "DISK=10"
echo "FAILED=0"
echo "FAILEDUNITS="
echo "WRAPPER_LAST=$(date +%s)"
STUB
chmod +x "$WORK/bin/getent" "$WORK/bin/ssh"

export WORK
PATH="$WORK/bin:$PATH"
export PATH

sweep() {
    rm -f "$WORK/lookups" "$WORK/dialled" "$AGENT_DIR"/ssh_backoff/* 2>/dev/null
    RESOLVABLE="$1" sh "$WORK/sweep.sh" >"$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
out_has() { grep -q "$1" "$WORK/out"; }
rc() { cat "$WORK/rc"; }

render internal

# ------------------------------------------------------------------
# 1. The fully qualified name resolves: the sweep runs every host.
# ------------------------------------------------------------------
sweep "cobra.internal"
if [ "$(cat "$WORK/lookups" 2>/dev/null)" = "cobra.internal" ]; then
    pass "the pre-check looks up the FQDN ssh dials, cobra.internal"
else
    fail "the pre-check looked up '$(tr '\n' ' ' < "$WORK/lookups" 2>/dev/null)', not cobra.internal"
fi
if [ "$(rc)" -eq 0 ] && out_has 'Fleet OK' && ! out_has 'cannot resolve'; then
    pass "a resolvable FQDN gives a clean sweep with no resolver note"
else
    fail "healthy resolver did not give a clean sweep (rc=$(rc))"
    cat "$WORK/out" >&2
fi
if grep -qx cobra "$WORK/dialled" 2>/dev/null && grep -qx hifipi "$WORK/dialled"; then
    pass "every host was probed"
else
    fail "hosts were skipped despite DNS working"
fi

# ------------------------------------------------------------------
# 2. 🔴 The load-bearing case. Only the bare name and the old .local name
#    resolve — a stale search domain or legacy override still answering. The
#    pre-check must NOT pass on those: ssh would dial cobra.internal and fail.
# ------------------------------------------------------------------
sweep "cobra cobra.local"
if out_has "cannot resolve 'cobra.internal'"; then
    pass "a bare-name or .local answer does not satisfy the pre-check"
else
    fail "the pre-check passed on a name ssh never dials"
    cat "$WORK/out" >&2
fi
if out_has 'fleet names resolve as <host>.internal'; then
    pass "the resolver note names the domain from the variable"
else
    fail "the resolver note does not name the configured domain"
fi
if [ ! -s "$WORK/dialled" ]; then
    pass "SSH probes are skipped rather than reported as false failures"
else
    fail "SSH probes ran without DNS: $(tr '\n' ' ' < "$WORK/dialled")"
fi
if [ "$(rc)" -ne 0 ]; then
    pass "a resolver fault still fails the sweep — skipping is not silencing"
else
    fail "resolver fault exited 0"
fi

# ------------------------------------------------------------------
# 3. The domain comes from the variable, not the template. Rollback to
#    `local` is a one-line change only if this holds.
# ------------------------------------------------------------------
render local
sweep "cobra.local"
if [ "$(rc)" -eq 0 ] && [ "$(cat "$WORK/lookups" 2>/dev/null)" = "cobra.local" ]; then
    pass "fleet_dns_domain=local looks up cobra.local — rollback is the variable alone"
else
    fail "domain did not follow the variable (rc=$(rc), looked up '$(cat "$WORK/lookups" 2>/dev/null)')"
    cat "$WORK/out" >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ sweep resolver pre-check: all checks passed\n'
    exit 0
fi
printf '❌ sweep resolver pre-check: %s check(s) failed\n' "$failures"
exit 1
