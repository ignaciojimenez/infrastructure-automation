#!/bin/sh
# Regression test: compare_speed_paths.sh must catch a tunnel that has silently
# stopped tunnelling, and must NOT invent a ratio alert it has no baseline for.
#
# Runs on the laptop — no network, no peer. `ssh` is stubbed on PATH and fed the
# peer's speed_last.json as a fixture.
#
#   tests/unit/speed_path_compare_test.sh
#
# ── The case that matters is 2 ────────────────────────────────────────────────
# If the Mullvad tunnel drops, agent-lxc keeps measuring — it just measures the
# direct line instead. Throughput goes UP and the VPN/direct ratio moves toward
# 1.0, so every speed-based check reads a VANISHED tunnel as a perfectly healthy
# one. That is the same shape as the 2026-09-01 HomeKit outage: seven checks
# green because every one of them asked the wrong question.
#
# The egress address is the only signal that separates those two states, and it
# needs no baseline. If case 2 ever goes green, this check has become decoration.
#
# ── Cases 5 and 6 pin the deferral ────────────────────────────────────────────
# The ratio is deliberately recorded and NOT alerted on until there is enough
# data to know the noise floor (~3% within a single 3-test run, measured
# 2026-09-05). Case 5 proves a terrible ratio stays silent by default; case 6
# proves turning it on is a config change rather than a code change. Both matter:
# a deferral nobody can switch on is just a missing feature.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/network/compare_speed_paths.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── compare_speed_paths: egress identity and deferred ratio\n'

[ -r "$SCRIPT" ] || { printf '   ✗ cannot read %s\n' "$SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '   ✗ jq required to run this test\n'; exit 1; }

mkdir -p "$WORK/bin" "$WORK/state"
export PATH="$WORK/bin:$PATH"
PEER_FIXTURE="$WORK/peer.json"

# Stub ssh: ignores its arguments and returns whatever the current peer fixture
# holds. An empty fixture stands in for an unreachable peer.
cat > "$WORK/bin/ssh" <<STUB
#!/bin/sh
cat "$PEER_FIXTURE" 2>/dev/null
STUB
chmod +x "$WORK/bin/ssh"

now_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
old_ts() {
    date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || date -u -v-3H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

# $1 down  $2 up  $3 external_ip  $4 isp  $5 timestamp  -> stdout
record() {
    printf '{"timestamp":"%s","host":"h","status":"PASS","download_mbps":%s,"upload_mbps":%s,"ping_ms":5.0,"server_id":52365,"isp":"%s","external_ip":"%s"}\n' \
        "$5" "$1" "$2" "$4" "$3"
}

reset_state() { rm -f "$WORK/state"/*; }

run_cmp() { "$SCRIPT" --state-dir="$WORK/state" --peer=peer-stub "$@" 2>&1; }

# ==================================================================
# CASE 1 — healthy: different egress, comparable speeds
# ==================================================================
reset_state
record 930.58 935.32 193.32.249.134 "31173 Services AB" "$(now_ts)" > "$WORK/state/speed_last.json"
record 940.94 940.11 87.210.114.214 "Odido Netherlands" "$(now_ts)" > "$PEER_FIXTURE"

out=$(run_cmp); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "different egress + healthy ratio → exit 0"
else
    fail "expected exit 0, got $rc: $(printf '%s' "$out" | tail -2)"
fi

# Assert the VALUE the ratio computation yields, not merely that a row appeared.
# 930.58 / 940.94 = 0.9890
got=$(tail -1 "$WORK/state/speed_ratio_history.csv" | cut -d, -f6)
if [ "$got" = "0.9890" ]; then
    pass "ratio recorded as 0.9890 (930.58/940.94)"
else
    fail "expected ratio 0.9890, CSV says '$got'"
fi

if head -1 "$WORK/state/speed_ratio_history.csv" | grep -q '^timestamp,local_label,peer_label,'; then
    pass "CSV carries a header row"
else
    fail "CSV header missing or wrong"
fi

# ==================================================================
# CASE 2 — THE ONE THAT MATTERS: tunnel down, same egress as direct
# ==================================================================
# Speeds are deliberately EXCELLENT and the ratio deliberately ~1.0 — exactly
# what a dropped tunnel looks like. Anything that reasons about throughput alone
# calls this healthy.
reset_state
record 941.10 940.522 87.210.114.214 "Odido Netherlands" "$(now_ts)" > "$WORK/state/speed_last.json"
record 940.94 940.110 87.210.114.214 "Odido Netherlands" "$(now_ts)" > "$PEER_FIXTURE"

out=$(run_cmp); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "identical egress → exit 1 (tunnel not carrying traffic)"
else
    fail "TUNNEL-DOWN NOT DETECTED: expected exit 1, got $rc"
fi

if printf '%s' "$out" | grep -q "SAME address"; then
    pass "says the paths share an egress address"
else
    fail "message does not name the actual fault: $(printf '%s' "$out" | tail -2)"
fi

# The fault must not depend on the speeds being bad — prove they were fine.
got=$(tail -1 "$WORK/state/speed_ratio_history.csv" | cut -d, -f6)
ok=$(awk -v r="$got" 'BEGIN{ print (r+0 > 0.99) ? "yes" : "no" }')
if [ "$ok" = "yes" ]; then
    pass "fired while the ratio was $got — speed alone would have said healthy"
else
    fail "fixture wrong: ratio $got is not the ~1.0 a dropped tunnel produces"
fi

# ==================================================================
# CASE 3 — stale data must REFUSE, not report green
# ==================================================================
reset_state
record 930.58 935.32 193.32.249.134 "31173 Services AB" "$(now_ts)" > "$WORK/state/speed_last.json"
record 940.94 940.11 87.210.114.214 "Odido Netherlands" "$(old_ts)" > "$PEER_FIXTURE"

out=$(run_cmp); rc=$?
if [ "$rc" -eq 2 ]; then
    pass "stale peer record → exit 2 (refuses to compare)"
else
    fail "expected exit 2 for stale data, got $rc"
fi

if [ ! -f "$WORK/state/speed_ratio_history.csv" ]; then
    pass "no ratio row written from stale inputs"
else
    fail "wrote a ratio row from stale data — that number would be meaningless"
fi

# ==================================================================
# CASE 4 — unreachable peer must REFUSE, not assume
# ==================================================================
reset_state
record 930.58 935.32 193.32.249.134 "31173 Services AB" "$(now_ts)" > "$WORK/state/speed_last.json"
: > "$PEER_FIXTURE"

out=$(run_cmp); rc=$?
if [ "$rc" -eq 2 ]; then
    pass "unreachable peer → exit 2"
else
    fail "expected exit 2 for unreachable peer, got $rc"
fi

# ==================================================================
# CASE 5 — the ratio alert is OFF by default, even for a terrible ratio
# ==================================================================
reset_state
record 300.00 310.00 193.32.249.134 "31173 Services AB" "$(now_ts)" > "$WORK/state/speed_last.json"
record 940.94 940.11 87.210.114.214 "Odido Netherlands" "$(now_ts)" > "$PEER_FIXTURE"

out=$(run_cmp); rc=$?
if [ "$rc" -eq 0 ]; then
    pass "ratio 0.32 does NOT alert while --min-ratio is unset (deferred on purpose)"
else
    fail "expected exit 0 with no --min-ratio, got $rc — the deferral is not real"
fi

got=$(tail -1 "$WORK/state/speed_ratio_history.csv" | cut -d, -f6)
if [ "$got" = "0.3188" ]; then
    pass "…but the bad ratio IS recorded (0.3188), so the data is there"
else
    fail "expected 0.3188 recorded, CSV says '$got'"
fi

# ==================================================================
# CASE 6 — and switching it on is a config change, not a code change
# ==================================================================
reset_state
record 300.00 310.00 193.32.249.134 "31173 Services AB" "$(now_ts)" > "$WORK/state/speed_last.json"
record 940.94 940.11 87.210.114.214 "Odido Netherlands" "$(now_ts)" > "$PEER_FIXTURE"

out=$(run_cmp --min-ratio=0.75); rc=$?
if [ "$rc" -eq 1 ]; then
    pass "--min-ratio=0.75 turns the same input into an alert"
else
    fail "expected exit 1 with --min-ratio=0.75, got $rc"
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '   ALL PASS\n\n'
    exit 0
fi
printf '   %d FAILED\n\n' "$failures"
exit 1
