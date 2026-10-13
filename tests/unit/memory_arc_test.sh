#!/bin/sh
# Regression test: check_memory must add back reclaimable ZFS ARC on the
# hypervisor, and must NOT do it inside a container.
#
#   tests/unit/memory_arc_test.sh
#
# The bug this pins (2026-10-13): workbench-lxc reported "Memory: -214% used
# (8 GiB of it reclaimable ZFS ARC)". arcstats is not virtualised, so an LXC
# reads the HOST's ARC, while lxcfs gives it its own small MemTotal. Adding the
# first to the second's MemAvailable drove usage negative, so the memory check
# on every LXC could never fire, however full the container got.
#
# Case 2 is the load-bearing one: a container that really is out of memory
# must alert. Before the fix it read healthy.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/common/system_health_check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

printf '\n── check_memory and the ZFS ARC\n'

# systemd-detect-virt answers from $IN_CONTAINER, so each case picks its side.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/systemd-detect-virt" <<'STUB'
#!/bin/sh
[ "${IN_CONTAINER:-0}" = 1 ]
STUB
chmod +x "$BIN/systemd-detect-virt"
PATH="$BIN:$PATH"
export PATH

# The host's ARC: 9 GiB held, 1 GiB floor, so 8 GiB reclaimable (in bytes).
cat > "$WORK/arcstats" <<'EOF'
size                            4    9663676416
c_min                           4    1073741824
EOF

export OS_TYPE=debian THRESHOLD_MEM=90 ARCSTATS_FILE="$WORK/arcstats"
export NETWORK_PROBE_ATTEMPTS=1 NETWORK_PROBE_TIMEOUT=1 NETWORK_PROBE_RETRY_DELAY=0
export HEALTH_CHECK_CONF=/nonexistent MAINTENANCE_DIR="$WORK/no-windows"

# meminfo <total_kb> <available_kb>
meminfo() {
    printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$WORK/meminfo"
}
run_case() {
    IN_CONTAINER="$1" MEMINFO_FILE="$WORK/meminfo" sh "$SCRIPT" > "$WORK/out" 2>&1
}
# Built with printf: BSD sed has no \x1b, and under dash the colours are real
# escape bytes, so a \x1b pattern passes on Linux and fails on the laptop.
ESC=$(printf '\033')
mem_line() {
    sed -n '/Memory Usage/,/^$/p' "$WORK/out" | sed "s/${ESC}\[[0-9;]*m//g" | grep 'Memory:'
}

# ------------------------------------------------------------------
# 1. The reported bug: a 4 GiB container with 3 GiB available, on a host
#    with 8 GiB of reclaimable ARC. Must read 25%, not negative.
# ------------------------------------------------------------------
meminfo 4194304 3145728
run_case 1
if mem_line | grep -q '✅ Memory: 25% used$'; then
    pass "a container reports its own usage, without the host's ARC"
else
    fail "container usage wrong"; mem_line >&2
fi

# ------------------------------------------------------------------
# 2. 🔴 A container that really is full (≈95%) must alert.
# ------------------------------------------------------------------
meminfo 4194304 209715
run_case 1
if mem_line | grep -q '❌ Memory: 95% used (above 90%)'; then
    pass "a full container is reported, which it never could be before"
else
    fail "a full container was not reported"; mem_line >&2
fi

# ------------------------------------------------------------------
# 3. The hypervisor keeps the ARC adjustment (cwwk, 2026-08-06): 16 GiB,
#    3 GiB available + 8 GiB reclaimable ARC = 31% used, with the note.
# ------------------------------------------------------------------
meminfo 16777216 3145728
run_case 0
if mem_line | grep -q '✅ Memory: 31% used (8 GiB of it reclaimable ZFS ARC)'; then
    pass "the hypervisor still counts reclaimable ARC as available"
else
    fail "hypervisor ARC adjustment changed"; mem_line >&2
fi

if [ "$failures" -gt 0 ]; then
    printf '\n%s failure(s)\n' "$failures"
    exit 1
fi
printf '\nall passed\n'
