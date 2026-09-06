#!/usr/bin/env python3
"""Backtest: replay every alert of the last N days through the router.

Answers the only question that matters before switching email off:
how many of the things Ignacio was actually notified about would the
router have escalated to him?

A router that suppresses everything scores perfectly here and is useless.
So this also prints what it would have swallowed, by severity — that list
is the thing to argue with.
"""

import json
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from security_sweep_prototype import gh, repos, route, exposure_of  # noqa: E402

DAYS = int(sys.argv[2]) if len(sys.argv) > 2 else 90


def main():
    owner = sys.argv[1] if len(sys.argv) > 1 else "ignaciojimenez"
    cutoff = datetime.now(timezone.utc) - timedelta(days=DAYS)
    rows = []

    for repo in repos(owner):
        for a in gh(f"repos/{owner}/{repo}/dependabot/alerts?per_page=100"):
            created = a.get("created_at") or ""
            if not created or datetime.fromisoformat(created.replace("Z", "+00:00")) < cutoff:
                continue
            adv = a.get("security_advisory", {})
            fixed = a.get("fixed_at") or a.get("dismissed_at")
            item = {
                "kind": "dependabot", "repo": repo, "id": a.get("number"),
                "title": (adv.get("summary") or "")[:60],
                "pkg": a.get("security_vulnerability", {}).get("package", {}).get("name"),
                "severity": adv.get("severity"),
                "scope": (a.get("dependency") or {}).get("scope"),
                "exposure": exposure_of(
                    repo, (a.get("dependency") or {}).get("manifest_path")),
                "epss_percentile": (adv.get("epss") or {}).get("percentile"),
                "created": created[:16].replace("T", " "),
                "fixed": (fixed or "")[:16].replace("T", " "),
                "state": a.get("state"),
            }
            lane, reason = route(item)
            item["lane"], item["reason"] = lane, reason
            # How long was it actually open?
            if fixed:
                lived = (datetime.fromisoformat(fixed.replace("Z", "+00:00"))
                         - datetime.fromisoformat(created.replace("Z", "+00:00")))
                item["lived_h"] = round(lived.total_seconds() / 3600, 1)
            rows.append(item)

    rows.sort(key=lambda r: r["created"])
    lanes = Counter(r["lane"] for r in rows)
    sev = Counter(r["severity"] for r in rows)

    print(f"\n=== {DAYS}-day backtest · {len(rows)} alerts opened ===")
    print(f"severity as GitHub emailed it: {dict(sev)}")
    print(f"router lanes: {dict(lanes)}\n")

    print(f"{'opened':17} {'repo':28} {'pkg':22} {'sev':9} {'scope':12} "
          f"{'EPSS%ile':9} {'openfor':9} lane")
    print("-" * 128)
    for r in rows:
        ep = r.get("epss_percentile")
        lived = f"{r.get('lived_h', '?')}h" if r.get("lived_h") is not None else "still open"
        print(f"{r['created']:17} {r['repo'][:27]:28} {str(r['pkg'])[:21]:22} "
              f"{str(r['severity']):9} {str(r.get('scope')):12} "
              f"{(f'{ep:.0%}' if ep is not None else '-'):9} {lived:9} {r['lane']}")

    print("\n--- what the router would have SUPPRESSED (argue with this list) ---")
    for r in rows:
        if r["lane"] == "silent":
            print(f"  {r['repo']}#{r['id']} {r['pkg']} ({r['severity']}) — {r['reason']}")

    escalated = [r for r in rows if r["lane"] in ("page", "plan")]
    # One package generates one alert PER CVE (Pillow: 8 in one minute).
    # The fix is identical for all of them, so the unit of human attention
    # is (repo, package), not the alert.
    actions = sorted({(r["repo"], str(r["pkg"]).lower()) for r in escalated})
    print(f"\nWould have reached Ignacio: {len(escalated)} of {len(rows)} alerts "
          f"({len(escalated) / max(len(rows), 1):.0%})")
    print(f"...collapsed to {len(actions)} distinct ACTIONS "
          f"over {DAYS} days:")
    for repo, pkg in actions:
        print(f"    {repo} → bump {pkg}")

    # The stale-notification metric: alerts fixed before a human plausibly acted.
    quick = [r for r in rows if r.get("lived_h") is not None and r["lived_h"] < 24]
    print(f"Alerts that opened and closed within 24h (i.e. the email was "
          f"stale on arrival): {len(quick)} of {len(rows)}")


if __name__ == "__main__":
    main()
