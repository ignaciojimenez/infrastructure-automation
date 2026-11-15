#!/bin/sh
# bin/opnsense-validate: the diff is the upgrade's pass/fail, so it is the part
# that has to be forced, both ways.
#
#   tests/unit/opnsense_validate_test.sh
#
# A diff that always says "no behavioural changes" passes the unchanged case
# alone, so every kind of change is planted and must come back as exactly its
# own id: no more, no fewer. The parsers are fed output captured from the live
# firewall, laptop and agent log on 2026-11-15 (MACs and public addresses
# replaced), and the test checks the values they return, not only that the
# pattern matched.

set -u

CDPATH=''
REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)

printf '\n── opnsense-validate diff + parsers\n'

python3 -I - "$REPO_ROOT/bin/opnsense-validate" <<'EOF'
import copy, importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("ov", sys.argv[1])
spec = importlib.util.spec_from_loader("ov", loader)
ov = importlib.util.module_from_spec(spec)
loader.exec_module(ov)

failures = 0
def check(name, ok, detail=""):
    global failures
    print(f"   {'✓' if ok else '✗'} {name}" + ("" if ok else f": {detail}"))
    failures += not ok

def c(cid, status, value, observed=None):
    return {"id": cid, "command": "x", "observed": observed if observed is not None else value,
            "expected": "x", "status": status, "diff_value": value}

pre = [c("A.version", "INFO", "26.7.7"), c("A.uptime", "INFO", None, "3.9 days"),
       c("A.gw.WG_MULLVAD_GW_NL1", "PASS", "none"), c("A.wg.wg0_mullvad_nl1", "PASS", [1, True], "84 s ago"),
       c("B.reservation.cobra", "PASS", "10.30.40.204 02:00:00:00:00:01"), c("E.mdns.raop", "INFO", ["a", "b"])]

def ids(post):
    return [i for i, _, _ in ov.diff_runs(pre, post)]

check("unchanged run: no changes", ids(copy.deepcopy(pre)) == [])

noise = copy.deepcopy(pre)
noise[0]["observed"] = noise[0]["diff_value"] = "26.7.9"
noise[1]["observed"] = "0.1 days"
noise[3]["observed"] = "12 s ago"
check("version, uptime, handshake age: not changes", ids(noise) == [], ids(noise))

for name, mutate, want in (
    ("gateway down", lambda p: p[2].update(status="FAIL", diff_value="down"), ["A.gw.WG_MULLVAD_GW_NL1"]),
    ("handshake gone stale, status unchanged", lambda p: p[3].update(diff_value=[1, False]), ["A.wg.wg0_mullvad_nl1"]),
    ("reservation MAC changed", lambda p: p[4].update(diff_value="10.30.40.204 02:00:00:00:00:02"), ["B.reservation.cobra"]),
    ("mDNS name vanished", lambda p: p[5].update(diff_value=["a"]), ["E.mdns.raop"]),
    ("check disappeared", lambda p: p.pop(2), ["A.gw.WG_MULLVAD_GW_NL1"]),
    ("check appeared", lambda p: p.append(c("A.gw.WG_MULLVAD_GW_NL4", "PASS", "none")), ["A.gw.WG_MULLVAD_GW_NL4"]),
):
    post = copy.deepcopy(pre)
    mutate(post)
    got = ids(post)
    check(f"{name}: exactly its own id", got == want, got)

run = ov.Run("post")
run.add("C.upstream.via_mullvad", "x", {}, "x", "PASS", sorted({"10.64.0.1": "wg0"}.items()))
reread = [c("C.upstream.via_mullvad", "PASS", [["10.64.0.1", "wg0"]])]
check("tuple value equals its JSON re-read: not a change", ov.diff_runs(reread, run.checks) == [],
      ov.diff_runs(reread, run.checks))

base = [c("A.gw.WG_MULLVAD_GW_NL3", "FAIL", "down"), c("E.sweep.fresh", "PASS", None)]
same = copy.deepcopy(base)
check("post, nothing changed, old FAIL kept: UPGRADE OK",
      ov.verdict("post", base, same, []).startswith("UPGRADE OK"), ov.verdict("post", base, same, []))
stale = copy.deepcopy(base)
stale[1]["status"] = "FAIL"
check("post with a stale sweep: INVESTIGATE although the diff is empty",
      ov.diff_runs(base, stale) == [] and ov.verdict("post", base, stale, []).startswith("INVESTIGATE"),
      ov.verdict("post", base, stale, []))
check("pre with a FAIL: not SAFE", ov.verdict("pre", [], base, []).startswith("INVESTIGATE"))

check("gateway: loss alarm is INFO and still 'up'; down is FAIL",
      [ov.gateway_state(x) for x in ("none", "loss", "down")] == [("PASS", "up"), ("INFO", "up"), ("FAIL", "down")])

drill = """;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 63117
;; flags: qr aa rd ra ; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; 204.40.30.10.in-addr.arpa.	IN	PTR

;; ANSWER SECTION:
204.40.30.10.in-addr.arpa.	1	IN	PTR	cobra.internal.
"""
check("drill PTR: rcode and name", ov.parse_dns(drill)[0::2] == ("NOERROR", [("PTR", "cobra.internal.")]),
      ov.parse_dns(drill))
dig = """;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 60194
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
; EDNS: version: 0, flags: do; udp: 1232
isc.org.		60	IN	A	151.101.3.42
isc.org.		60	IN	RRSIG	A 13 2 60 20261201000000 20261110000000 27566 isc.org. abc=
"""
rcode, flags, ans = ov.parse_dns(dig)
check("dig: ad flag, A kept, RRSIG typed apart", (rcode, "ad" in flags, [a for a in ans if a[0] == "A"])
      == ("NOERROR", True, [("A", "151.101.3.42")]), (rcode, flags, ans))
check("NXDOMAIN with no answer", ov.parse_dns(";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n")[0::2]
      == ("NXDOMAIN", []))

check("mullvad connected: server, no address",
      ov.parse_mullvad("You are connected to Mullvad (server nl-ams-wg-301). Your IP address is 192.0.2.7\n")
      == (True, "nl-ams-wg-301"))
check("mullvad not connected: address dropped",
      ov.parse_mullvad("You are not connected to Mullvad. Your IP address is 192.0.2.8\n") == (False, None))
check("mullvad unreachable: unknown, not 'not connected'", ov.parse_mullvad("")[0] is None)

log = """[2026-11-15 20:37:01] Starting execution of: /home/choco/.scripts/fleet_health_check.sh
[2026-11-15 20:37:16]   Started: 2026-11-15 20:37:01
    Fleet OK — 8/8 hosts reachable, no findings
[2026-11-15 21:37:01] Starting execution of: /home/choco/.scripts/fleet_health_check.sh
[2026-11-15 21:37:17]   Started: 2026-11-15 21:37:01
    resolver: cobra.internal did not resolve
    Fleet OK — 8/8 hosts reachable, no findings
[2026-11-15 22:37:01] Starting execution of: /home/choco/.scripts/fleet_health_check.sh
"""
started, lines = ov.parse_sweep(log)
check("sweep: last COMPLETED run, not the one in progress", str(started) == "2026-11-15 21:37:01", started)
check("sweep: its resolver line is visible", any("resolver:" in l for l in lines))

ifc = """vlan0.40: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
	description: VLAN40_Native (opt2)
	inet 10.30.40.254 netmask 0xffffff00 broadcast 10.30.40.255
	status: active
wg3: flags=10080c1<UP,RUNNING,NOARP,MULTICAST,LOWER_UP> metric 0 mtu 1420
	description: wg0_mullvad_nl3 (opt6)
"""
i = ov.parse_ifconfig(ifc)
check("ifconfig: descr, /24, status", (i["vlan0.40"]["descr"], i["vlan0.40"]["inet"], i["vlan0.40"]["status"])
      == ("VLAN40_Native", ["10.30.40.254/24"], "active"), i["vlan0.40"])
check("ifconfig: tunnel with no address", i["wg3"]["descr"] == "wg0_mullvad_nl3" and i["wg3"]["inet"] == [])

conf = ov.parse_dnsmasq_conf("""dhcp-range=tag:vlan0.40,10.30.40.160,10.30.40.199,86400
domain=internal,10.30.40.160,10.30.40.199
dhcp-host=02:00:00:00:00:01,10.30.40.204,cobra
dhcp-option=tag:vlan0.40,6,10.30.40.254
dhcp-option=6,0.0.0.0
""")
check("dnsmasq: reservation, DNS per tag, untagged option ignored",
      (conf["hosts"]["cobra"], conf["dns"]) == ({"ip": "10.30.40.204", "mac": "02:00:00:00:00:01"},
                                                {"vlan0.40": "10.30.40.254"}), conf)

zones = ov.parse_forward_zones("""forward-zone:
  name: "."
  forward-addr: 10.64.0.1@53
forward-zone:
  name: "internal"
  forward-addr: 127.0.0.1@53053
""")
check("unbound forward zones", zones == {".": ["10.64.0.1@53"], "internal": ["127.0.0.1@53053"]}, zones)

sys.exit(1 if failures else 0)
EOF
