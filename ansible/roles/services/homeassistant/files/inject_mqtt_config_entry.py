#!/usr/bin/env python3
"""Idempotently inject an MQTT config entry into Home Assistant's store.

HA removed YAML configuration of the MQTT broker connection in 2022.9; the
broker/credentials now live only in .storage/core.config_entries as a config
entry. This seeds that entry so the wiring is fully managed by Ansible.

Idempotent: if an mqtt entry already exists it makes no change. A malformed
entry cannot block HA boot — MQTT would simply report "failed to connect".

Inputs (environment, so credentials never reach argv or task logs):
  HA_STORAGE     path to core.config_entries
  MQTT_USERNAME  broker username
  MQTT_PASSWORD  broker password
  MQTT_PORT      broker port (default 1883)

Prints CHANGED or UNCHANGED for the caller's changed_when.
"""
import json
import os
import sys
import uuid
from datetime import datetime, timezone

path = os.environ["HA_STORAGE"]
username = os.environ["MQTT_USERNAME"]
password = os.environ["MQTT_PASSWORD"]
port = int(os.environ.get("MQTT_PORT", "1883"))

with open(path, encoding="utf-8") as fh:
    store = json.load(fh)

entries = store["data"]["entries"]
if any(e.get("domain") == "mqtt" for e in entries):
    print("UNCHANGED")
    sys.exit(0)

now = datetime.now(timezone.utc).isoformat()
entries.append(
    {
        "created_at": now,
        "modified_at": now,
        "data": {
            "broker": "localhost",
            "port": port,
            "username": username,
            "password": password,
        },
        "disabled_by": None,
        "discovery_keys": {},
        "domain": "mqtt",
        "entry_id": uuid.uuid4().hex,
        "minor_version": 1,
        "options": {"discovery": True, "discovery_prefix": "homeassistant"},
        "pref_disable_new_entities": False,
        "pref_disable_polling": False,
        "source": "user",
        "subentries": [],
        "title": "localhost",
        "unique_id": None,
        "version": 2,
    }
)

# Back up, then write atomically so a crash can't leave a half-written store.
with open(path + ".pre-mqtt.bak", "w", encoding="utf-8") as fh:
    json.dump(store, fh, indent=2)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(store, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("CHANGED")
