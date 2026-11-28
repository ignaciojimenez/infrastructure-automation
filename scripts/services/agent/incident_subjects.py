"""incident_subjects — the one definition of "what is failing" (managed by Ansible).

Shared by investigate.sh (both the Slack watch and anomaly mode) and
fleet_linear_sync.sh, so the incident a Tier 2 run explains and the Linear
issue the sweep files for it are always the same key. Deployed root-owned and
read-only: the root-run filer must never execute anything the agent account
can rewrite.

Loaded as a prefix to an inline parser (python3 -c "$SUBJECT_PY" plus its own block), so it
defines functions and runs nothing on import.

    subjects(host, script, title, body) -> ["raspotify", ...]
    finding_rows(findings) -> [(raw_key, host, finding), ...]

  0. An alert whose TITLE states "Subject: <name>" is taken at its word. This
     is for senders with no check script to be named after (Home Assistant
     automations), so they can join the incident the matching check opens
     instead of being guessed at (see automations.yaml.j2). The tag ends its
     line, "(... Subject: <name>)", and the name runs to that last
     parenthesis, so a device name that holds one survives. It is slugged
     here, so a sender states the name as HA spells it. Title only: the body
     is a check output, and openssl, for one, prints "Subject:".
  1. A specific check script names its subject: check_raspotify.sh ->
     raspotify. Generic multi-check scripts are NOT a subject. A check that
     watches many independent things says which one failed in its output, and
     is keyed by that instead (BODY_KEYED below).
  2. Otherwise, the failing lines of the output: "Service X: not running", a
     "- X.service" failed-unit line, "N failed systemd unit(s): X.service"
     (Tier 1 wording) -> X; a reachability failure -> "reachability"; any
     other failing line -> its normalised signature.
  3. Otherwise the title: reachability, else its signature, else
     "unspecified" — never empty, so every alert keys somewhere.

Lines cut off by the wrapper 1500-char output limit ("- raspo...") are
ignored rather than keyed as a bogus subject.

NOTE: no apostrophes anywhere in this file. Older callers embedded it in a
single-quoted shell string, and the habit is cheap insurance.
"""
import hashlib
import re
GENERIC_SCRIPTS = ("system_health_check", "fleet_health_check")
ANSI = re.compile(r"\x1b\[[0-9;]*m|\[[0-9;]*m")
UNIT = r"[A-Za-z0-9@_.-]+?\.(?:service|timer|socket|mount|path)"
REACH = re.compile(r"unreachable|\boffline\b|no response|not responding|\bis down\b|went down")
HEADERS = re.compile(r":[a-z_]+:|alert:|still failing|script failed|script execution|unchanged failure.*", re.I)
STOP = ("on", "the", "is", "at", "of", "and", "to", "for", "in", "not")

def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40]

def name_slug(s):
    """slug() for a stated name, where a plain cut could merge two of them.

    tado heads are named "...Radiator Thermostat VA<serial>", and the serial
    falls past the 40 chars slug() keeps. A long name keeps a readable head
    plus a hash of the whole, so it stays unique and stable. A short one is
    slug() without the cut.
    """
    full = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    if len(full) <= 48:
        return full
    return full[:39].rstrip("-") + "-" + hashlib.sha1(full.encode()).hexdigest()[:8]

def unit_name(u):
    return slug(re.sub(r"\.(?:service|timer|socket|mount|path)$", "", u))

def signature(line, host):
    s = HEADERS.sub(" ", ANSI.sub("", line).lower())
    if host:
        s = re.sub(r"(?<![a-z0-9-])" + re.escape(host) + r"(?![a-z0-9-])", " ", s)
    words = [w for w in re.sub(r"[^a-z]+", " ", s).split() if len(w) > 1 and w not in STOP]
    return slug("-".join(words[:6]))

def body_subjects(body, host):
    out = []
    def add(x):
        if x and x not in out:
            out.append(x)
    for raw in body.splitlines():
        line = ANSI.sub("", raw).strip().strip("`").strip()
        if not line or line.startswith(":repeat:") or line.endswith("...") or "truncated" in line.lower():
            continue
        m = re.search(r"failed systemd unit\(s\):\s*(.+)$", line)
        if m:
            for u in re.findall(UNIT, m.group(1)):
                add(unit_name(u))
            continue
        m = re.match(r"^-\s+(" + UNIT + r")\s*$", line)
        if m:
            add(unit_name(m.group(1)))
            continue
        if "❌" not in line:
            continue
        m = re.search(r"Service ([A-Za-z0-9@_.-]+): not running", line)
        if m:
            add(unit_name(m.group(1)))
        elif re.search(r"\d+ failed unit\(s\)", line):
            continue
        elif REACH.search(line.lower()):
            add("reachability")
        else:
            add(signature(line, host))
    return out

# check_ha_entities.sh watches every Home Assistant entity, so its name says
# nothing about WHAT failed. Keyed by its name alone, the 11-11 Eve door drop
# joined the 11-10 Shelly bulb incident and was never investigated (PER-184).
#
# Its alert line names the entity and, since PER-184, the device:
#   "❌ light.floor_lamp_new = unavailable for 20 min (past its 15 min grace) — device: Floor Lamp"
# The key is the device, so one bulb losing five entities is one incident and
# the state ("unavailable" vs "unknown") never enters it. The entity id is the
# fallback for an entity with no device, or an alert from before the tail.
# Every subject starts "ha-", which is also the prefix the HA automations
# state, so the two always meet (see automations.yaml.j2).
HA_ENTITY = re.compile(r"^❌\s*([a-z0-9_]+\.[a-z0-9_]+) = \S+ for \d+ min\b.*?(?: — device: (.+))?$")
# Its other failures, each a fixed subject: their wording carries an
# error text or a path that must not leak into the key.
HA_FIXED = (("device lookup failed", "ha-device-lookup"),
            ("state file", "ha-state-file"),
            ("home assistant api", "ha-api"),
            ("/api/states", "ha-api"),
            ("ha_monitor_token", "ha-api"))

def ha_entity_subjects(body, host):
    out = []
    for raw in body.splitlines():
        line = ANSI.sub("", raw).strip().strip("`").strip()
        if "❌" not in line or line.endswith("..."):
            continue
        m = HA_ENTITY.match(line)
        if m:
            x = name_slug("ha-" + (m.group(2) or m.group(1)).strip())
        else:
            low = line.lower()
            x = next((k for w, k in HA_FIXED if w in low), "") or signature(line, host)
        if x and x not in out:
            out.append(x)
    return out

BODY_KEYED = {"ha_entities": ha_entity_subjects}

def subjects(host, script, title, body):
    m = re.search(r"\bSubject: *([^\n]+?)\)?\s*$", title, re.M)
    if m and name_slug(m.group(1)):
        return [name_slug(m.group(1))]
    base = ""
    if script:
        base = re.sub(r"\.[A-Za-z0-9]+$", "", script.split()[0].rsplit("/", 1)[-1]).lower()
        base = re.sub(r"^check_", "", base)
        if base in BODY_KEYED:
            return BODY_KEYED[base](body, host) or [slug(base)]
        if base and base not in GENERIC_SCRIPTS:
            return [slug(base)]
    found = body_subjects(body, host)
    if found:
        return found
    t = ANSI.sub("", title)
    if REACH.search(t.lower()):
        return ["reachability"]
    return [signature(t, host) or slug(base) or "unspecified"]


def finding_rows(findings):
    """Tier 1 findings ("<host>: <message>") -> (raw_key, host, finding) rows.

    The raw key still goes through the shell incident_key() normaliser, which
    is what makes it safe as a filename.
    """
    rows = []
    for f in findings:
        host, sep, msg = str(f).partition(": ")
        if not sep or not re.match(r"^[A-Za-z0-9][A-Za-z0-9.-]*$", host):
            continue
        h = host.lower().split(".")[0]
        for s in subjects(h, "", "", "❌ " + msg):
            rows.append((h + "." + s, h, " ".join(str(f).split())))
    return rows
