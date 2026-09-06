#!/usr/bin/env python3
"""Prototype: state-shaped security sweep across a GitHub account.

Answers "what is vulnerable right now, and does it need Ignacio?" — not
"what advisory was published". Idempotent: safe to run hourly, says nothing
until the answer changes.

Routing is driven by two fields the advisory *email* never shows:
  - dependency.scope        development | runtime
  - security_advisory.epss  probability that the CVE is being exploited

Read-only. Opens nothing, merges nothing, posts nothing.
"""

import json
import subprocess
import sys
from collections import defaultdict

# Repo-level truth is too coarse: ignaciojimenezpi.github.io ships a static
# site, but its /photography/utils manifest is a laptop-only helper. Exposure
# is a property of the MANIFEST, not the repo. This map is the one piece of
# config a human owns — it cannot be derived from any API.
#
#   key   = repo
#   value = list of (manifest_prefix, exposure) — first match wins,
#           exposure in {"public", "supplychain", "local"}
EXPOSURE = {
    "pastebin-worker": [("", "public")],                    # Cloudflare Worker
    "ignaciojimenezpi.github.io": [
        # NOT laptop-only: .github/workflows/{process,remove}_album.yml
        # pip-install these requirements and run the code, in a job with write
        # access to a public repo — and Pillow's attack surface is precisely
        # the image files it is fed. Verified 2026-09-07.
        ("photography/utils", "supplychain"),
        ("", "public"),                                     # Cloudflare Pages
    ],
    "recordsdelmundo-site-static": [("", "public")],
    "touchid-agent": [("", "supplychain")],                 # brew → laptops
    "infrastructure-automation": [("", "supplychain")],     # controls the fleet
}


def exposure_of(repo, manifest):
    for prefix, exp in EXPOSURE.get(repo, []):
        if (manifest or "").startswith(prefix):
            return exp
    return "local"

# EPSS percentile above which "someone is actually exploiting this" outweighs
# a development-only scope. 0.90 = top 10% most-exploited CVEs.
EPSS_PAGE_PERCENTILE = 0.90


def gh(path):
    """GET a paginated GitHub API path, return [] on 404/403 (feature off)."""
    r = subprocess.run(
        ["gh", "api", "--paginate", path],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return []
    try:
        out = json.loads(r.stdout) if r.stdout.strip() else []
    except json.JSONDecodeError:
        # --paginate concatenates arrays; stitch them
        out = []
        for chunk in r.stdout.replace("][", "]\x00[").split("\x00"):
            try:
                out.extend(json.loads(chunk))
            except json.JSONDecodeError:
                pass
    return out if isinstance(out, list) else []


def repos(owner):
    data = gh(f"users/{owner}/repos?per_page=100&type=owner")
    return [r["name"] for r in data if not r.get("archived")]


def route(item):
    """Return (lane, reason). Lanes: page | plan | silent."""
    if item["kind"] == "secret":
        return "page", "a live credential is exposed"

    epss_raw = item.get("epss_percentile")
    epss_pct = epss_raw or 0.0
    exp = item.get("exposure", "local")

    if item["kind"] == "dependabot":
        # A CVE published minutes ago has no EPSS score yet — which is exactly
        # when it is least safe to assume nobody is exploiting it. Absence of a
        # score is not evidence of a low one, so it never routes to silent.
        if epss_raw is None and exp != "local":
            return "plan", "no EPSS score yet (new CVE) — exploitation unknown"
        if epss_pct >= EPSS_PAGE_PERCENTILE:
            return "page", f"EPSS {epss_pct:.0%}ile — actively exploited in the wild"
        if item.get("scope") == "development":
            return "silent", (
                f"build-time only (EPSS {epss_pct:.0%}ile); not in the shipped artefact"
            )
        if exp == "public":
            return "plan", "runtime dependency of an internet-facing service"
        if exp == "supplychain":
            return "plan", "runtime dependency of something distributed to machines"
        return "silent", f"runtime dependency of a {exp}-only manifest"

    # code scanning (CodeQL / SAST)
    if item["kind"] == "code":
        if item.get("severity") in ("critical", "high") and exp != "local":
            return "plan", f"SAST finding in {exp} code"
        return "silent", "SAST finding in code that is not exposed"

    return "plan", "unclassified — defaulting to human review"


def collect(owner, repo_list=None):
    """Return findings. Pass repo_list to avoid re-listing (and to keep the
    reported repo count consistent with what was actually swept — a repo
    archived mid-run would otherwise change the number)."""
    items = []
    for repo in (repo_list if repo_list is not None else repos(owner)):
        for a in gh(f"repos/{owner}/{repo}/dependabot/alerts?state=open&per_page=100"):
            adv = a.get("security_advisory", {})
            items.append({
                "kind": "dependabot",
                "repo": repo,
                "id": a.get("number"),
                "title": adv.get("summary", "")[:70],
                "pkg": a.get("security_vulnerability", {}).get("package", {}).get("name"),
                "severity": adv.get("severity"),
                "scope": (a.get("dependency") or {}).get("scope"),
                "manifest": (a.get("dependency") or {}).get("manifest_path"),
                "exposure": exposure_of(
                    repo, (a.get("dependency") or {}).get("manifest_path")),
                "epss_percentile": ((adv.get("epss") or {}).get("percentile")),
                "created": (a.get("created_at") or "")[:10],
            })
        for a in gh(f"repos/{owner}/{repo}/code-scanning/alerts?state=open&per_page=100"):
            rule = a.get("rule", {})
            items.append({
                "kind": "code",
                "repo": repo,
                "id": a.get("number"),
                "title": rule.get("id", ""),
                "pkg": (a.get("most_recent_instance") or {})
                       .get("location", {}).get("path", ""),
                "severity": rule.get("security_severity_level") or rule.get("severity"),
                "exposure": exposure_of(repo, (a.get("most_recent_instance") or {})
                                        .get("location", {}).get("path", "")),
                "created": (a.get("created_at") or "")[:10],
            })
        for a in gh(f"repos/{owner}/{repo}/secret-scanning/alerts?state=open&per_page=100"):
            items.append({
                "kind": "secret",
                "repo": repo,
                "id": a.get("number"),
                "title": a.get("secret_type_display_name", "secret"),
                "severity": "critical",
                "created": (a.get("created_at") or "")[:10],
            })
    return items


def main():
    owner = sys.argv[1] if len(sys.argv) > 1 else "ignaciojimenez"
    repo_list = repos(owner)
    items = collect(owner, repo_list)
    lanes = defaultdict(list)
    for it in items:
        lane, reason = route(it)
        it["reason"] = reason
        lanes[lane].append(it)

    print(f"\nswept: {len(repo_list)} repos · found: {len(items)} open findings")
    print(f"page: {len(lanes['page'])} · plan: {len(lanes['plan'])} "
          f"· silent: {len(lanes['silent'])}\n")

    for lane, label in (("page", "🔴 PAGE — #home-alerts"),
                        ("plan", "🟠 PLAN — investigate, digest"),
                        ("silent", "⚪ SILENT — auto-handled, audit only")):
        if not lanes[lane]:
            continue
        print(f"{label}")
        for it in sorted(lanes[lane], key=lambda x: x["created"]):
            print(f"  [{it['created']}] {it['repo']}#{it['id']} "
                  f"({it['kind']}/{it.get('severity')}) "
                  f"{it.get('pkg') or ''} {it['title']}".rstrip())
            print(f"      → {it['reason']}")
        print()

    if not items:
        print("nothing open. (heartbeat still fires — silence must be "
              "distinguishable from a dead sweep)")


if __name__ == "__main__":
    main()
