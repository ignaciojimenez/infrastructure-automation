#!/usr/bin/env python3
"""Parse-check every *.j2 template in the repo.

Catches Jinja2 syntax errors that ansible-lint and --syntax-check miss —
e.g. unescaped Docker --format strings ({{.Names}}) inside templates that
are actually rendered (not just copied).

Run locally:  scripts/ci/check_jinja_syntax.py
"""
from __future__ import annotations

import pathlib
import sys

import jinja2


def main() -> int:
    env = jinja2.Environment()
    root = pathlib.Path(__file__).resolve().parents[2]
    failures: list[str] = []

    for path in root.rglob("*.j2"):
        if any(part.startswith(".") for part in path.relative_to(root).parts):
            continue
        try:
            env.parse(path.read_text())
        except jinja2.TemplateSyntaxError as exc:
            rel = path.relative_to(root)
            failures.append(f"{rel}:{exc.lineno}: {exc.message}")

    if failures:
        print("Jinja2 syntax errors:", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        return 1

    print("All .j2 templates parse cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
