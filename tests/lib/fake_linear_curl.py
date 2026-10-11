#!/usr/bin/env python3
"""A stateful stand-in for `curl` talking to Linear's GraphQL API.

Installed as `curl` on PATH by tests/unit/fleet_linear_sync_test.sh (the
filer, read + write) and tests/unit/fleet_builder_poll_test.sh (the builder's
poller, read only: a `todo` variable narrows to that state). It reads
the request body from `--data-binary @file` and the credential from
`-H @file`, answers the handful of operations fleet_linear_sync.sh uses, and
keeps the workspace in a JSON file so consecutive runs see each other's
writes — which is the whole point: "no second issue on the next sweep" can
only be tested against something that remembers the first.

    FAKE_LINEAR_DB    workspace state (JSON), created if missing
    FAKE_LINEAR_LOG   one line per operation: "<op> <detail>"
    FAKE_LINEAR_ARGV  every argv, one per line — to prove the key is not in it
    FAKE_LINEAR_FAIL  operation name to answer with a GraphQL error
    FAKE_LINEAR_MORE  if set, the issues query reports hasNextPage
"""

import json
import os
import re
import sys

DONE = "state-done"
CLOSED_TYPES = {"completed", "canceled"}


def main() -> int:
    args = sys.argv[1:]
    with open(os.environ["FAKE_LINEAR_ARGV"], "a") as f:
        f.write(" ".join(args) + "\n")

    body = headers = None
    for i, a in enumerate(args):
        if a == "--data-binary" and args[i + 1].startswith("@"):
            body = json.load(open(args[i + 1][1:]))
        if a == "-H" and args[i + 1].startswith("@"):
            headers = open(args[i + 1][1:]).read()
    if not headers or not headers.startswith("Authorization: "):
        print(json.dumps({"errors": [{"message": "not authenticated"}]}))
        return 0

    path = os.environ["FAKE_LINEAR_DB"]
    db = json.load(open(path)) if os.path.exists(path) else {"issues": [], "n": 0}
    q, v = body["query"], body.get("variables") or {}
    op = re.search(r"\b(issues|issueCreate|attachmentCreate|commentCreate|issueUpdate)\b", q).group(1)

    def log(detail):
        with open(os.environ["FAKE_LINEAR_LOG"], "a") as f:
            f.write(f"{op} {detail}\n")

    if os.environ.get("FAKE_LINEAR_FAIL") == op:
        log("FAILED")
        print(json.dumps({"errors": [{"message": f"forced failure of {op}"}]}))
        return 0

    def find(issue_id):
        return next(i for i in db["issues"] if i["id"] == issue_id)

    if op == "issues":
        def comment(c, n):
            # The filer stores bodies; a seeded issue may carry createdAt.
            return c if isinstance(c, dict) else {"body": c, "createdAt": f"2026-10-11T00:00:{n:02d}Z"}

        nodes = [
            {
                "id": i["id"],
                "identifier": i["identifier"],
                "title": i.get("title", ""),
                "description": i.get("description", ""),
                "url": f"https://linear.invalid/issue/{i['identifier']}",
                "createdAt": i.get("createdAt", f"2026-10-11T00:{n:02d}:00Z"),
                "attachments": {"nodes": i["attachments"]},
                "comments": {"nodes": [comment(c, k) for k, c in enumerate(i.get("comments", []))]},
            }
            for n, i in enumerate(db["issues"])
            if i["state_type"] not in CLOSED_TYPES
            and v["label"] in i["labelIds"]
            and i["teamId"] == v["team"]
            and ("todo" not in v or i.get("stateId") == v["todo"])
        ]
        log(f"{len(nodes)} open")
        data = {
            "issues": {
                "pageInfo": {"hasNextPage": bool(os.environ.get("FAKE_LINEAR_MORE"))},
                "nodes": nodes,
            }
        }
    elif op == "issueCreate":
        inp = v["i"]
        db["n"] += 1
        issue = dict(
            inp,
            id=f"iss-{db['n']}",
            identifier=f"PER-{900 + db['n']}",
            state_type="unstarted",
            attachments=[],
            comments=[],
        )
        db["issues"].append(issue)
        log(f"{issue['identifier']} {inp['title']}")
        data = {"issueCreate": {"success": True, "issue": {"id": issue["id"], "identifier": issue["identifier"]}}}
    elif op == "attachmentCreate":
        inp = v["i"]
        issue = find(inp["issueId"])
        # Linear deduplicates attachments by URL on an issue: same URL updates.
        issue["attachments"] = [a for a in issue["attachments"] if a["url"] != inp["url"]]
        issue["attachments"].append({k: inp[k] for k in ("url", "subtitle", "metadata")})
        log(f"{issue['identifier']} {json.dumps(inp['metadata'], sort_keys=True)}")
        data = {"attachmentCreate": {"success": True}}
    elif op == "commentCreate":
        issue = find(v["i"]["issueId"])
        issue["comments"].append(v["i"]["body"])
        log(f"{issue['identifier']} {v['i']['body'].splitlines()[0]}")
        data = {"commentCreate": {"success": True}}
    else:  # issueUpdate
        issue = find(v["id"])
        if v["i"].get("stateId") == DONE:
            issue["state_type"] = "completed"
        log(f"{issue['identifier']} {json.dumps(v['i'], sort_keys=True)}")
        data = {"issueUpdate": {"success": True}}

    json.dump(db, open(path, "w"))
    print(json.dumps({"data": data}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
