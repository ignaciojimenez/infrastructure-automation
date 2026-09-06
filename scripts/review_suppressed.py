#!/usr/bin/env python3
"""Print what the router would SWALLOW, grouped by severity.

The escalation count is not the interesting number — a router that suppresses
everything scores perfectly on it. This list is the thing to argue with.

Collapses to (repo, package) because that is the unit of a fix: one bump
closes every CVE the package raised.
"""

import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from security_sweep_prototype import gh, repos, route, exposure_of  # noqa: E402

SEV_ORDER = ["critical", "high", "medium", "low"]


def main():
    owner = sys.argv[1] if len(sys.argv) > 1 else "ignaciojimenez"
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    suppressed = defaultdict(list)
    escalated = 0
    for repo in repos(owner):
        for a in gh(f"repos/{owner}/{repo}/dependabot/alerts?per_page=100"):
            created = a.get("created_at") or ""
            if not created:
                continue
            if datetime.fromisoformat(created.replace("Z", "+00:00")) < cutoff:
                continue
            adv = a.get("security_advisory", {})
            dep = a.get("dependency") or {}
            item = {
                "kind": "dependabot", "repo": repo, "id": a.get("number"),
                "pkg": a.get("security_vulnerability", {})
                       .get("package", {}).get("name"),
                "severity": adv.get("severity"),
                "scope": dep.get("scope"),
                "epss_percentile": (adv.get("epss") or {}).get("percentile"),
                "exposure": exposure_of(repo, dep.get("manifest_path")),
                "manifest": dep.get("manifest_path"),
            }
            lane, _ = route(item)
            if lane == "silent":
                suppressed[item["severity"]].append(item)
            else:
                escalated += 1

    total = sum(len(v) for v in suppressed.values())
    print(f"\nSUPPRESSED over {days} days: {total} alerts "
          f"(escalated: {escalated})\n")

    for sev in SEV_ORDER:
        rows = suppressed.get(sev, [])
        if not rows:
            continue
        groups = defaultdict(list)
        for r in rows:
            # casefold: "Pillow" and "pillow" are one package and one fix
            groups[(r["repo"], str(r["pkg"]).casefold())].append(r)
        print(f"── {sev.upper()}  ({len(rows)} alerts → {len(groups)} packages)")
        for (repo, pkg), rs in sorted(groups.items()):
            eps = [r["epss_percentile"] for r in rs
                   if r["epss_percentile"] is not None]
            if len(eps) > 1:
                erange = f"{min(eps):.0%}-{max(eps):.0%}"
            elif eps:
                erange = f"{eps[0]:.0%}"
            else:
                erange = "-"
            scopes = "/".join(sorted({str(r["scope"]) for r in rs}))
            exps = "/".join(sorted({r["exposure"] for r in rs}))
            mans = sorted({str(r["manifest"]) for r in rs})
            print(f"   {str(pkg)[:23]:24} x{len(rs):<3} {repo[:27]:28} "
                  f"scope={scopes:12} exposure={exps:6} EPSS={erange}")
            for m in mans:
                print(f"   {'':24}     {m}")
        print()


if __name__ == "__main__":
    main()
