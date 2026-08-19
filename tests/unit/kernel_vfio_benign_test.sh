#!/bin/sh
# Regression test: check_kernel_errors.sh must ignore benign vfio-pci reset
# lines and must still alert on every other VFIO-shaped message.
#
# Runs on the laptop — no container, no fleet, no network. `sudo`, `dmesg` and
# `md5sum` are stubbed; the script under test is the real one.
#
#   tests/unit/kernel_vfio_benign_test.sh
#
# The bug this pins (docs/TODO.md item 1b, verified end to end 2026-08-19):
# WARNING_PATTERNS contains "VFIO", matched case-insensitively against
# `dmesg -T`. Every start/stop of the OPNsense VM resets its two passthrough
# NICs and logs `vfio-pci 0000:0X:00.0: resetting` / `reset done`. The `-T`
# timestamp makes every line a fresh md5, so the seen-before dedup never
# suppressed them and cwwk paged "Script Failed" on every VM restart — twice at
# real cost, once via a $0.2980 Tier 2 investigation.
#
# Case 2 is the point of this file. Deleting "VFIO" from WARNING_PATTERNS also
# makes case 1 pass, and would leave a check that can never report a
# passthrough fault. The DMESG_BENIGN fixture is copied verbatim from cwwk's
# dmesg on 2026-08-19 (VM 100 restart at 20:13), not hand-written.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/services/proxmox/check_kernel_errors.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
pass() { printf '   ✓ %s\n' "$1"; }
fail() { printf '   ✗ %s\n' "$1"; failures=$((failures + 1)); }

# ------------------------------------------------------------------
# Stub the three commands that reach outside this machine
# ------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# `sudo dmesg -T` → run the stubbed dmesg, dropping any sudo flags.
cat > "$STUB_DIR/sudo" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -*) shift ;;
        *)  break ;;
    esac
done
exec "$@"
STUB

# dmesg prints whatever fixture the case put in $DMESG_FIXTURE.
cat > "$STUB_DIR/dmesg" <<'STUB'
#!/bin/sh
cat "$DMESG_FIXTURE"
STUB

# macOS has `md5`, not `md5sum`; stub it so the dedup path behaves identically
# on the laptop and on cwwk.
cat > "$STUB_DIR/md5sum" <<'STUB'
#!/bin/sh
if command -v /sbin/md5 >/dev/null 2>&1; then
    printf '%s  -\n' "$(/sbin/md5 -q)"
else
    printf '%s  -\n' "$(cksum | cut -d' ' -f1)"
fi
STUB

chmod +x "$STUB_DIR"/sudo "$STUB_DIR"/dmesg "$STUB_DIR"/md5sum
PATH="$STUB_DIR:$PATH"
export PATH

# ------------------------------------------------------------------
# Fixtures — captured from cwwk 2026-08-19, VM 100 restart at 20:13
# ------------------------------------------------------------------
BENIGN="$WORK/dmesg_benign.txt"
cat > "$BENIGN" <<'LOG'
[Wed Aug 19 20:13:28 2026] vfio-pci 0000:01:00.0: resetting
[Wed Aug 19 20:13:28 2026] vfio-pci 0000:01:00.0: reset done
[Wed Aug 19 20:13:28 2026] vfio-pci 0000:03:00.0: resetting
[Wed Aug 19 20:13:29 2026] vfio-pci 0000:03:00.0: reset done
[Wed Aug 19 20:13:30 2026] vfio-pci 0000:01:00.0: resetting
[Wed Aug 19 20:13:30 2026] vfio-pci 0000:01:00.0: reset done
LOG

# Run the check against a fixture with a fresh state dir, so each case
# exercises the first-sighting path the cron hits after a VM restart.
run_check() {
    fixture=$1
    state=$(mktemp -d "$WORK/state.XXXXXX")
    DMESG_FIXTURE="$fixture" KERNEL_ERRORS_STATE_DIR="$state" \
        bash "$SCRIPT" > "$WORK/out.txt" 2>&1
    rc=$?
    return $rc
}

printf '\n── check_kernel_errors.sh · benign vfio-pci resets\n'

# ------------------------------------------------------------------
# 1. The lines that actually paged must now exit OK
# ------------------------------------------------------------------
if run_check "$BENIGN"; then
    pass "VM-restart reset lines exit 0 (was 1 = WARNING → Script Failed)"
else
    fail "VM-restart reset lines still exit $? — $(cat "$WORK/out.txt")"
fi

# ------------------------------------------------------------------
# 2. The check must NOT have been lobotomised — every other VFIO line fires
#
# Each of these is VFIO-shaped and benign-adjacent; none is a plain reset.
# If any exits 0, the exclusion is too broad or the pattern was dropped.
# ------------------------------------------------------------------
i=0
while IFS= read -r fault; do
    [ -n "$fault" ] || continue
    i=$((i + 1))
    probe="$WORK/dmesg_fault_$i.txt"
    cp "$BENIGN" "$probe"
    printf '%s\n' "$fault" >> "$probe"

    if run_check "$probe"; then
        fail "SILENT on: $fault"
    elif grep -qF "$fault" "$WORK/out.txt"; then
        pass "alerts on: $fault"
    else
        fail "non-zero exit but line not reported: $fault"
    fi
done <<'FAULTS'
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:01:00.0: Failed to reset device
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:01:00.0: reset failed
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:01:00.0: resetting failed
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:03:00.0: reset done, device unusable
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:03:00.0: BAR 0: can't reserve
[Wed Aug 19 20:14:01 2026] vfio-pci 0000:03:00.0: DMAR: DMA fault
[Wed Aug 19 20:14:01 2026] vfio_bar_restore: 0000:01:00.0 reset recovery
FAULTS

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '── PASS (%s assertions)\n\n' "$((i + 1))"
    exit 0
fi
printf '── FAIL (%s of %s assertions)\n\n' "$failures" "$((i + 1))"
exit 1
