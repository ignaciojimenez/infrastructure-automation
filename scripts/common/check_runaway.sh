#!/bin/sh
# check_runaway.sh — one process holding about a full core, sample after sample
# (PER-10, docs/TODO.md item 9)
#
# Every CPU check in this fleet divides load by core count, so one pegged core
# of eight reads "16%, healthy". On 2026-08-07 a stuck `grep` on the OPNsense
# guest held cwwk at ~95 °C for ten hours, and the only alert was a thermal
# side effect, which the fan has since removed. This check looks at the
# process instead: it samples each process's accumulated CPU time and fails
# when one has used at least RUNAWAY_THRESHOLD_PCT of a core in each of the
# last RUNAWAY_SAMPLES consecutive intervals. The counter-delta idiom is the
# one check_thermal.sh uses.
#
# Runs under enhanced_monitoring_wrapper, from cron, on the host where the
# process runs (Linux and FreeBSD). Names in the ignore file (one per line,
# exactly as ps prints them) are never flagged: kvm on the hypervisor is
# sometimes busy by design.
#
# Exit: 0 healthy (or nothing to compare yet), 1 a runaway process.
#
# Test seams, never set in production: RUNAWAY_PS (a command printing
# "pid<sp>cpu<sp>comm" lines), RUNAWAY_NOW (epoch), RUNAWAY_STATE,
# RUNAWAY_IGNORE_FILE.

set -u

THRESHOLD_PCT=${RUNAWAY_THRESHOLD_PCT:-90}
SAMPLES=${RUNAWAY_SAMPLES:-3}
# A rerun sooner than this measures noise, not a sustained load.
MIN_INTERVAL=60
STATE=${RUNAWAY_STATE:-$HOME/.log/runaway_check.state}
NOW=${RUNAWAY_NOW:-$(date +%s)}

case "$(uname -s)" in
    FreeBSD)
        CONF_DIR=/usr/local/etc/monitoring
        # FreeBSD has no `times`; `time` is accumulated CPU as [MM...]:SS.ss
        PS_DEFAULT='ps -axo pid=,time=,comm='
        ;;
    *)
        CONF_DIR=/etc/monitoring
        # `times` is accumulated CPU in whole seconds
        PS_DEFAULT='ps -eo pid=,times=,comm='
        ;;
esac
IGNORE_FILE=${RUNAWAY_IGNORE_FILE:-$CONF_DIR/runaway_ignore}
PS_CMD=${RUNAWAY_PS:-$PS_DEFAULT}

mkdir -p "$(dirname "$STATE")" || { echo "❌ cannot create $(dirname "$STATE")"; exit 1; }

CURRENT=$($PS_CMD) || { echo "❌ ps failed: $PS_CMD"; exit 1; }
[ -n "$CURRENT" ] || { echo "❌ ps returned no processes: $PS_CMD"; exit 1; }

prev_ts=$(head -1 "$STATE" 2>/dev/null)
case "$prev_ts" in ''|*[!0-9]*) prev_ts="" ;; esac

if [ -n "$prev_ts" ] && [ $((NOW - prev_ts)) -lt "$MIN_INTERVAL" ]; then
    echo "✅ runaway check: last sample $((NOW - prev_ts))s ago, under ${MIN_INTERVAL}s; not resampled"
    exit 0
fi

# State: line 1 is the sample epoch; then "pid<TAB>cpu seconds<TAB>streak<TAB>comm".
# A process is matched by pid AND name, so a recycled pid starts over.
NEW="$STATE.new.$$"
printf '%s\n' "$CURRENT" | awk -v now="$NOW" -v prev_ts="$prev_ts" \
    -v thr="$THRESHOLD_PCT" -v need="$SAMPLES" -v state="$STATE" \
    -v ignore="$IGNORE_FILE" -v out="$NEW" '
    function cpusecs(t,   d, n, i, p, s) {
        # "123" (Linux times) or "[[DD-]HH:]MM:SS[.ss]" (FreeBSD time)
        d = 0
        if (index(t, "-")) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
        n = split(t, p, ":")
        s = 0
        for (i = 1; i <= n; i++) s = s * 60 + p[i]
        return d * 86400 + s
    }
    BEGIN {
        FS = "\t"
        while ((getline line < ignore) > 0) if (line != "" && substr(line, 1, 1) != "#") skip[line] = 1
        if (prev_ts != "") {
            getline line < state   # the epoch line
            while ((getline line < state) > 0) {
                split(line, f, "\t")
                pcpu[f[1] SUBSEP f[4]] = f[2]; pstreak[f[1] SUBSEP f[4]] = f[3]
            }
        }
        dt = (prev_ts == "") ? 0 : now - prev_ts
        print now > out
        FS = " "
    }
    {
        pid = $1; cpu = cpusecs($2)
        comm = $3; for (i = 4; i <= NF; i++) comm = comm " " $i
        k = pid SUBSEP comm
        streak = 0
        if (dt > 0 && (k in pcpu)) {
            pct = (cpu - pcpu[k]) * 100 / dt
            if (pct >= thr && !(comm in skip)) streak = pstreak[k] + 1
            if (pct > top_pct) { top_pct = pct; top = comm }
            if (streak >= need)
                printf "❌ runaway process: %s (pid %s) used %d%% of a core in each of the last %d samples (~%d min)\n", \
                    comm, pid, pct, streak, streak * dt / 60
        }
        printf "%s\t%s\t%s\t%s\n", pid, cpu, streak, comm > out
    }
    END {
        if (dt == 0) print "✅ runaway check: first sample recorded; nothing to compare yet"
        else if (top != "") printf "✅ runaway check: busiest process %s at %d%% of a core over %ds\n", top, top_pct, dt
        else printf "✅ runaway check: no process used CPU over the last %ds\n", dt
    }' > "$STATE.out.$$"
rc=$?
mv -f "$NEW" "$STATE" 2>/dev/null
out=$(cat "$STATE.out.$$"); rm -f "$STATE.out.$$" "$NEW"
[ "$rc" -eq 0 ] || { echo "❌ runaway check: awk failed (rc $rc)"; exit 1; }

# Findings first, so the wrapper's alert leads with them.
found=$(printf '%s\n' "$out" | grep -c '^❌')
printf '%s\n' "$out" | grep '^❌'
printf '%s\n' "$out" | grep -v '^❌'
[ "$found" -eq 0 ]
