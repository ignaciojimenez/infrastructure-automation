#!/bin/sh
# check_homekit_advertise.sh — does Home Assistant publish an address the
# house can actually reach?
# Managed by Ansible — do not edit manually.
#
# THE OUTAGE THIS EXISTS FOR (2026-09-01 to 2026-09-03, ~2 days, found by a
# human noticing the Apple Home app was dead):
#
#   dockassist rebooted. NetworkManager reported "startup complete" at
#   19:22:58 while eth0 was still carrier-down, so network-online.target
#   fired early, Docker started at 19:23:05, and Home Assistant enumerated
#   network adapters at 19:23:37 — 19 seconds before eth0's DHCP lease
#   arrived at 19:23:56. The only IPv4 on the box at that instant was
#   docker0's 172.17.0.1, so HA published all three of its HomeKit bridges
#   at that address. Nothing ever re-bound them. Apple Home resolved the
#   bridges to an unroutable address and every accessory went "No Response".
#
# WHY NOTHING CAUGHT IT. Seven checks run on this host and all seven were
# green for the full two days: the Docker daemon was up, the container was
# up, `curl http://localhost:8123` answered, entities had valid states,
# trackers were fresh, the NIC was fine. Every one of them asks "is Home
# Assistant alive, as seen from the machine Home Assistant runs on?" The
# failure was entirely in what HA *publishes to the rest of the house*, so
# the whole suite was structurally blind to it.
#
# There was already an avahi check in this repo — check_avahi.sh, on the
# audio hosts — and it asserts `systemctl is-active avahi-daemon`. During
# this outage avahi was running perfectly, faithfully publishing the wrong
# address. Liveness is not correctness. That check would have been green too.
#
# THE INVARIANT THIS ASSERTS, and it is deliberately a local one:
#
#   Every _hap._tcp record advertising a TCP port this host is listening on
#   must resolve to an address this host currently holds on an interface
#   whose operstate is up.
#
# Two local facts compared against each other. No ping, no TCP connect, no
# probe of a remote host. That is on purpose: wifi_reconnect.sh was gated on
# pinging a gateway that answers no ICMP, so it reloaded the wifi driver
# every 2 minutes against a healthy radio and took the host off the network.
# A check whose healthy path depends on something answering is a check that
# invents outages. This one cannot: if the two local facts agree, it is green.
#
# ⚠️  OPERSTATE, NOT IFF_UP — the detail that decides whether this works.
# When docker0 has no containers on it the kernel reports:
#
#   3: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> ... state DOWN ...
#
# IFF_UP is set. `ip link show up` and `ip addr show up` both MATCH it, and
# `ip addr show scope global` lists 172.17.0.1 regardless. Any of those as the
# truth set would have called the Sep 1 state healthy — the check would have
# been green through the entire outage it was written to catch. Only the
# `state UP` operstate field separates a live interface from a carcass that
# still owns an address. Verified against real `ip -o link show` output from
# two hosts on 2026-09-04 before this was written.
#
# WHAT "OURS" MEANS. A _hap._tcp record is treated as published by this host
# when its advertised port is a TCP port this host is listening on. On
# dockassist that selects HA's bridges (21064-21066) and excludes the HomePod
# (62946) and the Tado bridge (80), neither of which we listen on. The
# assumption this trades on: no remote HomeKit accessory happens to advertise
# a port that this host also listens on. If one ever did, this would compare
# that device's address against our local set and alert wrongly. Cheap to
# recognise from the message, which names the record.
#
# WHAT THIS DOES NOT ALERT ON, and why. Finding NO records of our own is
# reported but exits 0. A browse is a 15-second observation of a lossy
# multicast medium, and "HA is advertising nothing at all" needs a measured
# baseline of how often a healthy host briefly shows zero before it earns a
# threshold — check_presence_health.sh had to measure 7 days of history to
# learn its healthy gaps reach 721 minutes. Guessing here would buy a check
# that pages on multicast luck. The present-but-wrong case is what this
# alerts on, and it is the case that actually happened.
set -eu

SERVICE_TYPE="_hap._tcp"
BROWSE_TIMEOUT=15

if ! command -v avahi-browse >/dev/null 2>&1; then
    echo "❌ avahi-browse not found — install avahi-utils; this check cannot run"
    exit 1
fi

# mDNS being down is its own unambiguous fault: HomeKit cannot work at all.
# Cheap to assert here rather than mis-reporting it as "no records found".
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet avahi-daemon; then
    echo "❌ avahi-daemon is not running — mDNS is down, HomeKit cannot work"
    exit 1
fi

# ------------------------------------------------------------------
# Collectors. One thin wrapper per external command so the unit test can
# stub `ip`, `ss` and `avahi-browse` on PATH and drive the whole comparison
# from captured fixtures.
# ------------------------------------------------------------------

# Interfaces whose operstate is up. Parses the `state UP` field, NOT the
# IFF_UP flag in the angle brackets — see the operstate note above.
up_interfaces() {
    ip -o link show 2>/dev/null \
        | sed -n 's/^[0-9]*: \([^:@]*\)[@:].*state UP .*/\1/p'
}

# Global-scope addresses held on those interfaces. This is the truth set:
# what the host can actually be reached at right now.
routable_addresses() {
    for iface in $(up_interfaces); do
        ip -o addr show dev "$iface" scope global 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "inet" || $i == "inet6") {
                        split($(i + 1), a, "/")
                        print a[1]
                    }
                }
            }'
    done
}

# TCP ports this host is listening on, any bind address.
listening_ports() {
    ss -ltn 2>/dev/null | awk 'NR > 1 { n = split($4, a, ":"); print a[n] }' | sort -u
}

# Resolved _hap._tcp records, one per line: name<TAB>address<TAB>port
#
# `avahi-browse -rpt` emits ';'-delimited fields:
#   =;iface;proto;name;type;domain;hostname;address;port;txt
#
# ⚠️  The proto column (IPv4/IPv6) is the BROWSE family, not the family of the
# resolved address: rows marked IPv6 carry the A record's IPv4 address. Real
# captured output from dockassist, 2026-09-04:
#
#   =;eth0;IPv6;HASS\032Bridge\0326B911B;_hap._tcp;local;<host>;10.30.100.100;21064;"..."
#
# Splitting on that column, as the field name invites, yields nonsense. Every
# row is deduped by name+address+port instead, which collapses the pair.
hap_records() {
    timeout "$BROWSE_TIMEOUT" avahi-browse -rpt "$SERVICE_TYPE" 2>/dev/null \
        | awk -F';' '$1 == "=" && $8 != "" && $9 != "" {
              gsub(/\\032/, " ", $4)
              print $4 "\t" $8 "\t" $9
          }' \
        | sort -u
}

# ------------------------------------------------------------------
# Bounded recheck, mirroring check_services in system_health_check.sh.
#
# A HomeKit bridge that has just restarted can briefly be represented in
# avahi's cache by the record it published before the restart. On ONE sample
# a stale cache entry and a real misbinding are the same observation, exactly
# as `systemctl is-active` cannot tell a restart from an outage on one sample.
#
# ⚠️ The dangerous direction is the same one service_recheck warns about:
# "retry until it looks fine" is how a monitoring system stops reporting
# outages. So the retry is bounded, it applies ONLY when the check already
# looks BAD, and a bridge still advertising a wrong address at the end fails
# exactly as it would have on the first sample. A healthy result never
# retries, so the common path costs one browse.
HAP_RECHECK_ATTEMPTS="${HAP_RECHECK_ATTEMPTS:-3}"
HAP_RECHECK_DELAY="${HAP_RECHECK_DELAY:-15}"

# Sets OURS, BAD, BAD_DETAIL, OK_DETAIL, ADDRESSES. Always returns 0 so that
# `set -e` cannot turn a finding into a silent exit.
evaluate() {
    OURS=0
    BAD=0
    BAD_DETAIL=''
    OK_DETAIL=''

    ADDRESSES=$(routable_addresses)
    [ -n "$ADDRESSES" ] || return 0

    _ports=$(listening_ports)

    # A pipeline would run the loop in a subshell and lose the counters, so
    # the records go through a temp file.
    hap_records > "$RECORDS_FILE"

    while IFS="$(printf '\t')" read -r _name _addr _port; do
        [ -n "${_port:-}" ] || continue

        # Ours only if the advertised port is a port we are listening on.
        echo "$_ports" | grep -qx "$_port" || continue
        OURS=$((OURS + 1))

        if echo "$ADDRESSES" | grep -qx "$_addr"; then
            OK_DETAIL="${OK_DETAIL}   ✅ $_name -> $_addr:$_port
"
        else
            BAD=$((BAD + 1))
            BAD_DETAIL="${BAD_DETAIL}   $_name -> $_addr:$_port
"
        fi
    done < "$RECORDS_FILE"

    return 0
}

RECORDS_FILE=$(mktemp)
trap 'rm -f "$RECORDS_FILE"' EXIT

attempt=1
while [ "$attempt" -le "$HAP_RECHECK_ATTEMPTS" ]; do
    evaluate
    [ "$BAD" -eq 0 ] && break
    if [ "$attempt" -lt "$HAP_RECHECK_ATTEMPTS" ]; then
        sleep "$HAP_RECHECK_DELAY"
    fi
    attempt=$((attempt + 1))
done

if [ -z "$ADDRESSES" ]; then
    echo "❌ no global-scope address on any interface that is up — cannot judge"
    exit 1
fi

if [ "$BAD" -gt 0 ]; then
    _window=$(( (HAP_RECHECK_ATTEMPTS - 1) * HAP_RECHECK_DELAY ))
    echo "❌ $BAD HomeKit bridge(s) advertising an address this host does not hold"
    echo "   (${HAP_RECHECK_ATTEMPTS} checks over ${_window}s — not a restart window):"
    printf '%s' "$BAD_DETAIL"
    echo "   this host is reachable at: $(echo "$ADDRESSES" | tr '\n' ' ')"
    echo "   Apple Home will show these accessories as 'No Response'."
    echo "   Remedy: restart the Home Assistant container so it re-binds."
    exit 1
fi

if [ "$OURS" -eq 0 ]; then
    # Reported, not alerted — see the header. Visible in the log and in the
    # daily heartbeat; deliberately not a page until a baseline says what
    # "normal" looks like for an empty browse on a healthy host.
    echo "⚠️  no _hap._tcp records found on a port this host listens on"
    echo "   (not treated as a fault: a 15s multicast browse can legitimately"
    echo "   come back empty; see the header before giving this a threshold)"
    exit 0
fi

printf '%s' "$OK_DETAIL"
if [ "$attempt" -gt 1 ]; then
    echo "✅ $OURS HomeKit bridge(s) advertising a routable address (settled after ${attempt} checks — restart window?)"
else
    echo "✅ $OURS HomeKit bridge(s) advertising a routable address"
fi
exit 0
