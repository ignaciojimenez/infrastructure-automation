#!/bin/sh
# Regression test: neither tier may keep re-authenticating against a host that
# is rejecting its SSH key.
#
# Runs on the laptop — no container, no fleet, no network, no spend. Both
# templates are rendered with test values and driven against stubs.
#
#   tests/unit/ssh_backoff_test.sh
#
# The incident this pins (2026-08-03): a genuine read_agent key failure on
# opnsense was found by the Tier 1 sweep, Tier 2 investigated that finding the
# only way it can — by SSHing at the host — and the burst of failed publickey
# auth read to CrowdSec as a brute-force. CrowdSec runs on the firewall, the
# firewall is the gateway, so it banned agent-lxc off its own network. One
# broken key became total loss of fleet visibility, caused by the monitoring
# rather than found by it. It then re-banned every hour, because the loop had
# no back-off anywhere in it.
#
# Two properties are load-bearing and easy to get half-right:
#   * back-off applies to REJECTED auth, not to an unreachable host. A host
#     that is merely down logs no failed auth and trips no IPS; backing off
#     from it would blind the sweep for no benefit.
#   * the finding's wording must be identical on every sweep, or it defeats the
#     snapshot dedup in anomaly_dedup_test.sh and Tier 2 re-bills hourly again.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SWEEP_TMPL="$REPO_ROOT/scripts/services/agent/fleet_health_check.sh.j2"
INVESTIGATE_TMPL="$REPO_ROOT/scripts/services/agent/investigate.sh.j2"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

AGENT_DIR="$WORK/agent"
BACKOFF_DIR="$AGENT_DIR/ssh_backoff"
ANOMALY="$AGENT_DIR/last_anomaly.json"
MARKER="$AGENT_DIR/.last_investigated"
STUB_DIR="$WORK/stub"
CALLS="$STUB_DIR/calls"
PROMPT_RECORD="$WORK/prompt.txt"
mkdir -p "$AGENT_DIR" "$STUB_DIR" "$WORK/bin" "$WORK/plans"

# ------------------------------------------------------------------
# Render both templates
# ------------------------------------------------------------------
python3 "$REPO_ROOT/tests/lib/render_j2.py" "$SWEEP_TMPL" "$WORK/sweep.sh" \
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
    agent_fleet_hosts=cobra:linux,opnsense:linux || exit 1
# ^ deliberately empty: an unconfigured URL is the sweep's "do not ping" path,
# which keeps this test off the network. The ping itself is covered by
# tests/unit/sweep_healthcheck_test.sh.

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$INVESTIGATE_TMPL" "$WORK/investigate.sh" \
    agent_env_file="$WORK/agent.env" \
    agent_state_dir="$AGENT_DIR" \
    agent_plans_dir="$WORK/plans" \
    agent_failure_alert_cooldown_seconds=21600 \
    agent_run_timeout_seconds=600 \
    agent_slack_channel=C_TEST \
    agent_slack_dedup_days=7 \
    agent_slack_max_per_run=3 \
    opencode_bin="$WORK/bin/opencode" || exit 1

# ------------------------------------------------------------------
# Stubs.
#
# `ssh` is the unit under test's only contact with the world. `flock` and
# `timeout` are stubbed because macOS ships neither and neither is what this
# file is testing; stubbing them unconditionally also keeps the run identical
# on Linux. `opencode` records the prompt it was handed and returns a minimal
# well-formed response — whether it was called AT ALL is the assertion.
# ------------------------------------------------------------------
cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
host=""
for a in "$@"; do
    case "$a" in *-agent) host="${a%-agent}" ;; esac
done
cat >/dev/null   # swallow the probe script
printf '%s\n' "$host" >> "$CALLS"
mode=ok
[ -f "$STUB_DIR/$host" ] && mode=$(cat "$STUB_DIR/$host")
case "$mode" in
    authfail)
        echo "read_agent@$host: Permission denied (publickey)." >&2
        exit 255 ;;
    down)
        echo "ssh: connect to host $host port 22: Operation timed out" >&2
        exit 255 ;;
    diskfull) echo "DISK=99" ;;
    *)        echo "DISK=10" ;;
esac
echo "FAILED=0"
echo "FAILEDUNITS="
echo "WRAPPER_LAST=$(date +%s)"
STUB

printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/getent"
printf '#!/bin/sh\nshift $#\nexit 0\n' > "$WORK/bin/flock"

cat > "$WORK/bin/timeout" <<'STUB'
#!/bin/sh
# Drop `-k <n> <duration>` and exec the rest.
while [ $# -gt 0 ]; do
    case "$1" in
        -*) shift 2 ;;
        [0-9]*) shift ;;
        *) break ;;
    esac
done
exec "$@"
STUB

cat > "$WORK/bin/opencode" <<'STUB'
#!/bin/sh
for a in "$@"; do last="$a"; done
printf '%s' "$last" > "$PROMPT_RECORD"
# printf, not echo: `echo` expands the \n on some shells, which puts real
# newlines inside a JSON string and makes the event unparseable — the agent
# then looks like it produced nothing and the whole run reports failure.
printf '%s\n' '{"type":"text","part":{"messageID":"m1","text":"===PLAN===\n# stub plan\n===SUMMARY===\nstub summary\n"}}'
printf '%s\n' '{"type":"step_finish","part":{"cost":0}}'
STUB

chmod +x "$WORK"/bin/*
printf 'ANTHROPIC_API_KEY=test\n' > "$WORK/agent.env"

export STUB_DIR CALLS PROMPT_RECORD
PATH="$WORK/bin:$PATH"
export PATH

sweep() { : > "$CALLS"; sh "$WORK/sweep.sh" >"$WORK/out" 2>&1; }
called()  { grep -qx "$1" "$CALLS"; }

# ==================================================================
printf '\n── Tier 1: back off a host that rejects our key\n'
# ==================================================================

echo authfail > "$STUB_DIR/opnsense"
sweep
if called opnsense; then
    pass "the first rejection is a real connection attempt"
else
    fail "opnsense was never probed at all"
fi
if [ -f "$BACKOFF_DIR/opnsense" ]; then
    pass "a rejection records back-off state"
else
    fail "no back-off recorded — the next sweep re-authenticates"
fi
if grep -q 'SSH auth rejected as read_agent' "$WORK/out"; then
    pass "the rejection is still reported"
else
    fail "the rejection was not reported — silence is not a fix"
fi
first_note=$(grep 'opnsense:' "$WORK/out")

# --- second sweep: report, do not connect --------------------------
sweep
if called opnsense; then
    fail "opnsense was re-authenticated while backed off — this is the ban loop"
else
    pass "no SSH attempt while backed off"
fi
if called cobra; then
    pass "healthy hosts are still probed"
else
    fail "back-off on one host suppressed the whole sweep"
fi
if [ "$(grep 'opnsense:' "$WORK/out")" = "$first_note" ]; then
    pass "the finding text is unchanged between sweeps (composes with snapshot dedup)"
else
    fail "the finding text changed — the snapshot would churn and Tier 2 re-bill hourly"
fi

# --- a host that is merely DOWN must still be retried --------------
rm -f "$BACKOFF_DIR"/*
echo down > "$STUB_DIR/opnsense"
sweep
if [ -f "$BACKOFF_DIR/opnsense" ]; then
    fail "an unreachable host was backed off — it trips no IPS and this blinds the sweep"
else
    pass "an unreachable host is not backed off"
fi
if grep -q 'UNREACHABLE' "$WORK/out"; then
    pass "an unreachable host is reported as unreachable, not as rejected"
else
    fail "unreachable and rejected are being conflated"
fi
sweep
if called opnsense; then
    pass "an unreachable host is retried on the next sweep"
else
    fail "an unreachable host stopped being probed"
fi

# --- expiry, then recovery ----------------------------------------
echo authfail > "$STUB_DIR/opnsense"
sweep
mkdir -p "$BACKOFF_DIR"
printf '1 1\n' > "$BACKOFF_DIR/opnsense"   # window in the past
echo ok > "$STUB_DIR/opnsense"
sweep
if called opnsense; then
    pass "an expired window is retried"
else
    fail "back-off never expires — a fixed host stays invisible forever"
fi
if [ -f "$BACKOFF_DIR/opnsense" ]; then
    fail "a successful probe did not clear the back-off"
else
    pass "a successful probe clears the back-off"
fi

# ==================================================================
printf '\n── Tier 2: do not investigate "I cannot log in" by logging in\n'
# ==================================================================

# Rebuild the exact state the incident produced: opnsense rejecting, backed
# off, and the only thing the snapshot has to say.
rm -f "$ANOMALY" "$MARKER" "$WORK/plans"/*.md
echo authfail > "$STUB_DIR/opnsense"
sweep
[ -f "$ANOMALY" ] || { fail "no snapshot to investigate"; exit 1; }

rm -f "$PROMPT_RECORD"
sh "$WORK/investigate.sh" > "$WORK/inv_out" 2>&1
inv_rc=$?
if [ -f "$PROMPT_RECORD" ]; then
    fail "the agent was launched at a host it cannot authenticate to"
else
    pass "no agent run when every finding names a backed-off host"
fi
if [ "$inv_rc" -eq 0 ]; then
    pass "the skip is a clean exit, not a failure alert"
else
    fail "skipping cost a non-zero exit (rc=$inv_rc): $(cat "$WORK/inv_out")"
fi
if grep -q 'SSH back-off' "$WORK/inv_out"; then
    pass "the skip is logged with its reason"
else
    fail "the skip is silent — indistinguishable from a broken cron"
fi

# --- a finding it CAN reach must still be investigated -------------
echo diskfull > "$STUB_DIR/cobra"
sweep
rm -f "$PROMPT_RECORD" "$WORK/plans"/*.md
sh "$WORK/investigate.sh" > "$WORK/inv_out" 2>&1
inv_rc=$?
if [ -f "$PROMPT_RECORD" ]; then
    pass "a reachable host's finding is still investigated"
else
    fail "the back-off suppressed an investigation it should not have: $(cat "$WORK/inv_out")"
fi
# Without this the whole Tier 2 half could be passing on a run that failed for
# an unrelated reason and never reached the code under test.
if [ "$inv_rc" -eq 0 ] && [ -n "$(ls "$WORK/plans")" ]; then
    pass "the investigation completed and wrote its plan"
else
    fail "the investigation did not complete (rc=$inv_rc): $(cat "$WORK/inv_out")"
fi
if grep -q 'must NOT connect' "$PROMPT_RECORD" && grep -q 'opnsense' "$PROMPT_RECORD"; then
    pass "the prompt names the host the agent must not touch"
else
    fail "the agent was not told which host to avoid — it will try, and get banned"
fi

# --- and with nothing backed off, the prompt is unchanged ----------
rm -f "$BACKOFF_DIR"/* "$STUB_DIR/opnsense" "$ANOMALY" "$MARKER"
sweep
rm -f "$PROMPT_RECORD"
sh "$WORK/investigate.sh" > "$WORK/inv_out" 2>&1
if [ -f "$PROMPT_RECORD" ] && ! grep -q 'must NOT connect' "$PROMPT_RECORD"; then
    pass "no directive is added when no host is backed off"
else
    fail "the directive leaks into the normal case"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL (%s)\n' "$failures"
exit 1
