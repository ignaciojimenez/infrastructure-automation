#!/bin/sh
# Regression test: the Tier 1 sweep must describe HOW a host failed to answer,
# and must report a fleet-wide absence as one event rather than N faults.
#
# Runs on the laptop — no container, no fleet, no network, no spend. The
# template is rendered with test values and driven against a stubbed `ssh`
# that can play each way a host declines to give us probe output.
#
#   tests/unit/sweep_absence_test.sh
#
# Two bugs are pinned here, and they are the same bug at two scales.
#
# 1. `opnsense: UNREACHABLE (no response as read_agent)` is what a POWERED-OFF
#    host looks like. It was also what opnsense said while it was up, running,
#    routing the house's traffic, and authenticating this container perfectly
#    — its read_agent account merely had /usr/sbin/nologin as a shell, which
#    OPNsense restores from config.xml on every account regeneration. The
#    detection was right and the wording sent you to look for a dead firewall.
#
#    The discriminator was MEASURED from agent-lxc on 2026-08-13, and the
#    measurement corrected the plan's guess:
#
#        SSH_RC=1   STDERR=[]   STDOUT=[This account is currently not available.]
#
#    Not the exit status (1, not the predicted 0) and not stderr (empty) — the
#    signal is that the far side answered with something that was not probe
#    output. The stubs below reproduce exactly that shape.
#
# 2. The power events of 2026-07-26 and 2026-08-09 took six hosts down inside a
#    15-second window. Six `UNREACHABLE` findings is the alert flood again, and
#    it is also the wrong diagnosis: it is one external event, not six faults.
#
# ⚠️ What must NOT happen is a quieter sweep. Every case below asserts that the
# sweep still FAILS and still names every affected host; only the wording and
# the grouping change. Case 5 exists solely to prove the collapse cannot
# swallow a single dead host.

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
STUB_DIR="$WORK/stub"
mkdir -p "$AGENT_DIR" "$STUB_DIR" "$WORK/bin"

printf '\n── Tier 1 absence reporting\n'

python3 "$REPO_ROOT/tests/lib/render_j2.py" "$TEMPLATE" "$WORK/sweep.sh" \
    agent_disk_threshold=85 \
    agent_wrapper_max_age_hours=26 \
    agent_ssh_timeout=5 \
    agent_ssh_backoff_base_seconds=3600 \
    agent_ssh_backoff_max_seconds=21600 \
    agent_fleet_wide_threshold=3 \
    agent_state_dir="$AGENT_DIR" \
    agent_sweep_healthcheck_url="" \
    agent_fleet_hosts=cobra:linux,hifipi:linux,dockassist:linux,vinylstreamer:linux,opnsense:linux || exit 1
# ^ healthcheck URL deliberately empty: that is the sweep's "do not ping" path,
# which keeps this test off the network. The ping is covered separately by
# tests/unit/sweep_healthcheck_test.sh.

# Per-host behaviour, selected by $STUB_DIR/<host>. The three failure modes are
# reproduced at the level the sweep actually observes them: what lands on
# stdout, what lands on stderr, and the exit status.
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
    silent)
        # Powered off / off the network: nothing on either stream.
        exit 255
        ;;
    noshell)
        # Authenticated fine, then refused to run anything. Message on STDOUT,
        # empty stderr, rc=1 — measured against the real opnsense.
        echo "This account is currently not available."
        exit 1
        ;;
    rejected)
        # Credentials refused. This is the only mode that must trip the back-off.
        echo "read_agent@${host}: Permission denied (publickey)." >&2
        exit 255
        ;;
    *)
        echo "DISK=10"
        echo "FAILED=0"
        echo "FAILEDUNITS="
        echo "WRAPPER_LAST=$(date +%s)"
        ;;
esac
STUB
# The sweep's DNS pre-check; getent does not exist on macOS.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/getent"
chmod +x "$WORK/bin/ssh" "$WORK/bin/getent"

export STUB_DIR
PATH="$WORK/bin:$PATH"
export PATH

reset_stubs() { rm -f "$STUB_DIR"/* "$AGENT_DIR"/ssh_backoff/* 2>/dev/null; }
sweep() { sh "$WORK/sweep.sh" >"$WORK/out" 2>&1; echo $? > "$WORK/rc"; }
out_has() { grep -q "$1" "$WORK/out"; }
rc() { cat "$WORK/rc"; }

# ------------------------------------------------------------------
# 1. A host that answers with a banner instead of probe data is described as
#    UP, and is NOT called unreachable.
# ------------------------------------------------------------------
reset_stubs
echo noshell > "$STUB_DIR/opnsense"
sweep
if out_has 'opnsense: UP but no usable shell'; then
    pass "a nologin host is reported as UP, not UNREACHABLE"
else
    fail "nologin host not distinguished"
    cat "$WORK/out" >&2
fi
if out_has 'This account is currently not available'; then
    pass "the reminder carries what the host actually said"
else
    fail "the host's own response was dropped from the finding"
fi
if ! out_has 'opnsense: UNREACHABLE'; then
    pass "the misleading UNREACHABLE wording is gone for this case"
else
    fail "still reporting a live host as UNREACHABLE"
fi
if [ "$(rc)" -eq 1 ]; then
    pass "it is still a finding — the sweep still fails"
else
    fail "rewording silenced the finding (rc=$(rc))"
fi

# ------------------------------------------------------------------
# 2. A genuinely silent host still says UNREACHABLE, and says why in terms
#    that fit a dead box.
# ------------------------------------------------------------------
reset_stubs
echo silent > "$STUB_DIR/hifipi"
sweep
if out_has 'hifipi: UNREACHABLE'; then
    pass "a silent host is still reported UNREACHABLE"
else
    fail "silent host lost its finding"
    cat "$WORK/out" >&2
fi
if [ "$(rc)" -eq 1 ]; then
    pass "a single dead host still fails the sweep"
else
    fail "single dead host did not fail the sweep (rc=$(rc))"
fi

# ------------------------------------------------------------------
# 3. Auth rejection is unchanged — it must still be its own branch, and must
#    still be the ONLY one that trips the back-off. That scoping is what keeps
#    the sweep from re-authenticating against an IPS-protected firewall until
#    it bans the container off its own network, which is how this went wrong
#    on 2026-08-03.
# ------------------------------------------------------------------
reset_stubs
echo rejected > "$STUB_DIR/opnsense"
sweep
if out_has 'SSH auth rejected'; then
    pass "auth rejection keeps its own distinct finding"
else
    fail "auth rejection branch broken"
    cat "$WORK/out" >&2
fi
if [ -f "$AGENT_DIR/ssh_backoff/opnsense" ]; then
    pass "auth rejection still records back-off"
else
    fail "back-off no longer recorded on rejection"
fi

reset_stubs
echo noshell > "$STUB_DIR/opnsense"
sweep
if [ ! -f "$AGENT_DIR/ssh_backoff/opnsense" ]; then
    pass "a nologin host does NOT trip the back-off (it is not a failed auth)"
else
    fail "nologin wrongly treated as an auth failure"
fi

# ------------------------------------------------------------------
# 4. 🔴 Fleet-wide absence collapses to ONE finding that names every host.
#    Four silent hosts, threshold 3.
# ------------------------------------------------------------------
reset_stubs
for h in cobra hifipi dockassist vinylstreamer; do echo silent > "$STUB_DIR/$h"; done
sweep
if out_has 'FLEET-WIDE: 4/5 hosts silent'; then
    pass "four simultaneous absences collapse into one fleet-wide finding"
else
    fail "fleet-wide absence not collapsed"
    cat "$WORK/out" >&2
fi
if [ "$(grep -c 'UNREACHABLE' "$WORK/out")" -eq 0 ]; then
    pass "it does not also emit one UNREACHABLE per host"
else
    fail "collapsed AND emitted per-host findings"
fi
for h in cobra hifipi dockassist vinylstreamer; do
    out_has "$h" || fail "collapsed finding dropped the name '$h'"
done
if out_has 'cobra' && out_has 'vinylstreamer'; then
    pass "every affected host is still named in the collapsed finding"
fi
if [ "$(rc)" -eq 1 ]; then
    pass "a fleet-wide event still fails the sweep — collapsing is not silencing"
else
    fail "fleet-wide collapse silenced the sweep (rc=$(rc))"
fi

# ------------------------------------------------------------------
# 5. 🔴 The load-bearing negative. Below the threshold, hosts are still named
#    individually. If this ever collapses, one dead Pi becomes "a fleet event"
#    and stops being chased.
# ------------------------------------------------------------------
reset_stubs
echo silent > "$STUB_DIR/cobra"
echo silent > "$STUB_DIR/hifipi"
sweep
if out_has 'cobra: UNREACHABLE' && out_has 'hifipi: UNREACHABLE'; then
    pass "two absences stay individual findings (below threshold)"
else
    fail "sub-threshold absences were wrongly collapsed"
    cat "$WORK/out" >&2
fi
if ! out_has 'FLEET-WIDE'; then
    pass "no fleet-wide claim is made below the threshold"
else
    fail "claimed a fleet-wide event for two hosts"
fi

# ------------------------------------------------------------------
# 6. 🔴 Findings are ❌-marked, and this is not decoration.
#
#    enhanced_monitoring_wrapper scopes its repeat-detection signature to the
#    ❌-marked lines when any exist, and to the whole output when none do.
#    Unmarked, the sweep's signature covered its own bookkeeping line
#    "(findings unchanged since the last sweep …)" — which appears only from
#    the SECOND identical run onward — so the first repeat of every fault read
#    as a new fault and paged again. Measured on agent-lxc 2026-08-14.
#
#    If this assertion ever fails, the wrapper's dedup silently degrades to
#    two pages per fault. Nothing else would notice.
# ------------------------------------------------------------------
reset_stubs
echo silent > "$STUB_DIR/hifipi"
sweep
if out_has '^❌ hifipi: UNREACHABLE'; then
    pass "findings are ❌-marked, so the wrapper can scope its signature"
else
    fail "findings lost the ❌ marker — wrapper dedup will degrade silently"
    cat "$WORK/out" >&2
fi
if ! grep -q '^❌.*findings unchanged' "$WORK/out"; then
    pass "the bookkeeping line is NOT marked, and so stays out of the signature"
else
    fail "bookkeeping line was marked as a finding"
fi

# ------------------------------------------------------------------
# 7. A healthy fleet is still clean, and still exits 0. Without this the whole
#    file could pass while the sweep alerted on everything forever.
# ------------------------------------------------------------------
reset_stubs
sweep
if [ "$(rc)" -eq 0 ] && out_has 'Fleet OK'; then
    pass "a healthy fleet still reports OK and exits 0"
else
    fail "healthy fleet no longer clean (rc=$(rc))"
    cat "$WORK/out" >&2
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '✅ sweep absence reporting: all checks passed\n'
    exit 0
fi
printf '❌ sweep absence reporting: %s check(s) failed\n' "$failures"
exit 1
