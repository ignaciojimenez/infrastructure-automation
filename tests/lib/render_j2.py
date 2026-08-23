#!/usr/bin/env python3
"""Render an Ansible template far enough to run it, with no jinja2 installed.

    tests/lib/render_j2.py <template> <out> KEY=VALUE ...

The agent's shell scripts are `.j2` templates, so a test that wants to *run*
one has to render it first. Ansible's own jinja2 is not importable from the
system python3 on macOS, and pulling a dependency into a shell test suite to
substitute four variables is a poor trade — so this handles the small subset of
Jinja these templates actually use:

  * ``{{ name }}`` — replaced from the KEY=VALUE arguments.
  * ``{% for h in agent_fleet_hosts %}…{% endfor %}`` — expanded once per entry
    of ``agent_fleet_hosts=cobra:linux,opnsense:freebsd``, with ``h.name`` and
    ``h.kind`` available inside the body.
  * ``{% for x in some_list %}…{% endfor %}`` — the general case, expanded once
    per comma-separated entry of ``some_list=a,b,c`` with ``x`` bound in the
    body. A trailing ``| default([])`` filter is accepted and ignored, and a
    list that was never supplied renders as zero iterations — which is what
    ``default([])`` means and is itself worth being able to test.

Anything left unrendered is a hard error rather than a silent pass. That is the
point: when a template grows a construct this does not understand, the test
fails loudly instead of exercising a script full of literal ``{{ … }}``.
"""

import re
import sys


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)

    template, out = sys.argv[1], sys.argv[2]
    values = dict(a.split("=", 1) for a in sys.argv[3:])
    fleet = [
        {"name": e.split(":")[0], "kind": e.split(":")[1]}
        for e in values.pop("agent_fleet_hosts", "").split(",")
        if ":" in e
    ]

    src = open(template).read()

    def subst(text, ctx):
        def one(m):
            key = m.group(1).strip()
            if key in ctx:
                return str(ctx[key])
            sys.exit("render_j2: no value supplied for {{ %s }}" % key)

        return re.sub(r"\{\{\s*([a-z_0-9.]+?)\s*\}\}", one, text)

    def loop(m):
        body = m.group(1)
        return "".join(
            subst(body, {"h.name": h["name"], "h.kind": h["kind"]}) for h in fleet
        )

    src = re.sub(
        r"\{%\s*for h in agent_fleet_hosts\s*%\}(.*?)\{%\s*endfor\s*%\}",
        loop,
        src,
        flags=re.S,
    )

    # The general loop. Runs after the fleet case above so that one keeps its
    # dotted h.name/h.kind binding and stays byte-for-byte as it was.
    def generic_loop(m):
        var, listname, body = m.group(1), m.group(2), m.group(3)
        raw = values.get(listname, "")
        items = [e for e in raw.split(",") if e]
        return "".join(subst(body, {var: item}) for item in items)

    src = re.sub(
        r"\{%\s*for\s+([a-z_0-9]+)\s+in\s+([a-z_0-9]+)"
        r"(?:\s*\|\s*default\(\[\]\))?\s*%\}(.*?)\{%\s*endfor\s*%\}",
        generic_loop,
        src,
        flags=re.S,
    )

    src = subst(src, values)

    leftover = re.search(r"\{\{|\{%", src)
    if leftover:
        line = src.count("\n", 0, leftover.start()) + 1
        sys.exit(
            "render_j2: unrendered Jinja at %s:%d — teach this renderer the new "
            "construct rather than letting the test run against it" % (template, line)
        )

    open(out, "w").write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main())
