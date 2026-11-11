#!/usr/bin/env python3
"""unifi-state — the UniFi controller's state as sorted lines, for a before/after diff.

The check half of the upgrade procedure (PER-128, ansible/roles/services/unifi/
README.md). Deployed to unifi-lxc as /usr/local/bin/unifi-state and run there
against the loopback API, by any user, read_agent included. It reads the
read-only controller account as JSON on stdin,

    {"username": "...", "password": "..."}

so the password is never in argv, the environment or a file. bin/unifi-state
wraps this from the laptop.

One line per object, fields in a fixed order, the lines sorted: two captures
of an unchanged controller are byte-identical, and a change shows up in a plain
`diff -u` as exactly the lines it touched. What is captured is what an upgrade
must not change: sites, devices (adopted, state, firmware), networks and VLANs,
WLANs. Counters, uptimes, IPs and clients are left out on purpose; they move
on their own and would put noise in every diff.

The controller's own version goes to stderr, not the snapshot. It is the one
thing an upgrade is supposed to change.

    unifi-state                      standalone Network Application (unifi-lxc)
    unifi-state --unifi-os [URL]     UniFi OS Server (PER-178), default URL below

The same snapshot from both is the migration's pass/fail (PER-127): old
controller against new. Only the login and the path prefix differ; the paths
are aiounifi's (Home Assistant's UniFi library), read 2026-11-11. ⚠️ The UniFi
OS mode has not yet run against a real UniFi OS Server.
"""
import http.cookiejar
import json
import ssl
import sys
import urllib.error
import urllib.request

STANDALONE = {"base": "https://127.0.0.1:8443", "login": "/api/login",
              "logout": "/api/logout", "prefix": ""}
# UniFi OS logs in at its own layer and proxies the Network application under
# /proxy/network. 11443 is UniFi OS Server's web port per community guides,
# not yet seen on ours: pass the URL if it differs.
UNIFI_OS = {"base": "https://127.0.0.1:11443", "login": "/api/auth/login",
            "logout": "/api/auth/logout", "prefix": "/proxy/network"}


def line(kind, *keys, **fields):
    """kind "key"... field=value...; values JSON-encoded so spaces cannot blur a field."""
    parts = [kind] + [json.dumps(k) for k in keys]
    parts += ["%s=%s" % (k, json.dumps(v)) for k, v in fields.items()]
    return " ".join(parts)


def render(sites):
    """Sorted lines from [{name, desc, devices, networks, wlans}], the API's raw dicts."""
    lines = []
    for s in sites:
        site = s["name"]
        net_names = {n.get("_id"): n.get("name") for n in s["networks"]}
        lines.append(line("site", site, desc=s.get("desc"), devices=len(s["devices"]),
                          networks=len(s["networks"]), wlans=len(s["wlans"])))
        for d in s["devices"]:
            # state 1 is connected: all four APs read 1 while online (2026-11-10).
            lines.append(line("device", site, d.get("mac"), name=d.get("name"),
                              model=d.get("model"), type=d.get("type"),
                              adopted=d.get("adopted"), state=d.get("state"),
                              firmware=d.get("version")))
        for n in s["networks"]:
            lines.append(line("network", site, n.get("name"), purpose=n.get("purpose"),
                              vlan_enabled=n.get("vlan_enabled"), vlan=n.get("vlan"),
                              subnet=n.get("ip_subnet"), enabled=n.get("enabled")))
        for w in s["wlans"]:
            lines.append(line("wlan", site, w.get("name"), enabled=w.get("enabled"),
                              network=net_names.get(w.get("networkconf_id")),
                              security=w.get("security"), wpa_mode=w.get("wpa_mode"),
                              hidden=w.get("hide_ssid"), guest=w.get("is_guest")))
    return sorted(lines)


def _get(opener, api, path):
    req = urllib.request.Request(api["base"] + api["prefix"] + path, headers=api["headers"])
    with opener.open(req, timeout=30) as r:
        body = json.load(r)
    if body.get("meta", {}).get("rc") != "ok":
        raise SystemExit("unifi-state: %s: %s" % (path, body.get("meta")))
    return body["data"]


def capture(creds, api):
    # Loopback only, and the controller's certificate is self-signed: there is
    # no hostname to verify and no network path to intercept.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    api = dict(api, headers={})
    login = urllib.request.Request(api["base"] + api["login"], data=json.dumps(creds).encode(),
                                   headers={"Content-Type": "application/json"})
    with opener.open(login, timeout=30) as r:
        # UniFi OS hands out a CSRF token at login and wants it back on every
        # request after; the standalone application sends none.
        if r.headers.get("x-csrf-token"):
            api["headers"]["x-csrf-token"] = r.headers["x-csrf-token"]
    try:
        sites = []
        for s in _get(opener, api, "/api/self/sites"):
            site = "/api/s/%s/" % s["name"]
            sites.append({"name": s["name"], "desc": s.get("desc"),
                          "devices": _get(opener, api, site + "stat/device"),
                          "networks": _get(opener, api, site + "rest/networkconf"),
                          "wlans": _get(opener, api, site + "rest/wlanconf")})
        version = _get(opener, api, "/api/s/%s/stat/sysinfo" % sites[0]["name"])[0].get("version") if sites else None
    finally:
        # Best effort: a failed logout must neither mask the real error nor
        # fail a capture that succeeded. The session expires on its own.
        try:
            opener.open(urllib.request.Request(api["base"] + api["logout"], data=b"",
                                               headers=api["headers"]), timeout=30).close()
        except urllib.error.URLError:
            pass
    return sites, version


def main(argv):
    api = dict(STANDALONE)
    if argv[:1] == ["--unifi-os"]:
        api = dict(UNIFI_OS)
        argv = argv[1:]
    if len(argv) > 1:
        raise SystemExit("usage: unifi-state [--unifi-os] [URL]  (credentials as JSON on stdin)")
    if argv:
        api["base"] = argv[0].rstrip("/")
    try:
        sites, version = capture(json.load(sys.stdin), api)
    except urllib.error.HTTPError as e:
        raise SystemExit("unifi-state: %s: HTTP %s" % (e.url, e.code))
    except urllib.error.URLError as e:
        raise SystemExit("unifi-state: controller unreachable: %s" % e.reason)
    # An empty capture must not become a baseline that later diffs as
    # "everything vanished" or, worse, as two matching empties.
    if not sites:
        raise SystemExit("unifi-state: the controller listed no sites")
    print("controller %s" % version, file=sys.stderr)
    sys.stdout.write("\n".join(render(sites)) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
