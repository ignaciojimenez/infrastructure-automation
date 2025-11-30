# Home Automation Brain Architecture

*Action Plan: Home Assistant as Central Brain*

## Executive Summary

This document outlines the plan to establish Home Assistant as the central "brain" for all home automation logic, with Apple HomeKit serving as the voice/remote frontend via Siri.

## Current State Analysis

### Infrastructure
- **Host**: dockassist (Raspberry Pi 4, Debian Bookworm)
- **HA Version**: 2025.11.1
- **Deployment**: Docker container (NOT Home Assistant OS)
- **Network**: IPv4 (10.30.100.100) + IPv6 enabled (ULA + link-local)

### Current Integrations
| Integration | Status | Entities |
|-------------|--------|----------|
| **Wyze** (HACS) | ✅ Active | 4 lights (floor_lamp, floor_lamp_new, book_floor_lamp, table_lamp) |
| **Tado** | ✅ Active | 5 climate zones, hot water, 6+ device trackers |
| **Shelly** | ✅ Active | 2 lights (luz_outdoor, luz_salon) |
| **HomeKit Bridge** | ✅ Active | Exposing climate, lights, sensors |
| **Thread** | ✅ Dataset exists | From iOS app |
| **Matter** | ❌ NOT CONFIGURED | Required for Eve sensors |
| **HACS** | ✅ Active | Custom integrations |

### Eve Sensors (Currently HomeKit-only)
- **Eve-Balcony** (Door sensor, Serial: QV17M1M04044)
- **Eve-FrontDoor** (Door sensor, Serial: QV22M1M04789)
- Model: Eve Door 20EBN9901, Firmware: 3.2.1
- Connected via Thread to HomePod Mini border router

### Existing Automations
1. **Sunset lights** - Turn on "Chill" scene at sunset when someone home
2. **Lights off (weekday)** - 00:30
3. **Lights off (weekend)** - 02:30
4. **Daily backups** - 03:00
5. **Tado Away/Home schedules** - Mon-Thu triggers
6. **Integration health alerts** - Tado/Wyze online status to Slack

### Existing Scenes
- **Chill** - Dim warm lights (brightness 1-15%)
- **Cena** - Brighter warm lights (brightness 15-40%)
- **Chill_new** - Similar to Chill (seems duplicate)

---

## Task 1: Matter/Eve Integration

### Problem
Eve sensors are paired to Apple HomeKit via Thread (HomePod Mini as border router). They're invisible to Home Assistant.

### Solution: Matter Multi-Admin Pairing

Since HA runs in Docker (not HAOS), we need:
1. **Matter Server** as separate Docker container
2. **Home Assistant Matter integration** connecting to the server
3. **Multi-Admin pairing** from Apple Home app

### Implementation Steps

#### Step 1.1: Deploy Matter Server Container
```yaml
# docker-compose addition for matter-server
services:
  matter-server:
    container_name: matter-server
    image: ghcr.io/home-assistant-libs/python-matter-server:stable
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor=unconfined
    volumes:
      - /home/choco/matter-server:/data
      - /run/dbus:/run/dbus:ro
```

#### Step 1.2: Configure HA Matter Integration
Add Matter integration via UI:
- Settings → Devices & Services → Add Integration → Matter
- Connect to: `ws://localhost:5580/ws`

#### Step 1.3: Multi-Admin Pairing Process
For each Eve sensor:
1. Open Apple Home app
2. Long-press the Eve sensor → Settings gear
3. Tap "Turn On Pairing Mode" 
4. A pairing code will be generated (11-digit or QR)
5. In Home Assistant: Settings → Devices & Services → Matter → Commission Device
6. Enter the pairing code
7. Sensor appears in both HomeKit AND Home Assistant

### Expected Entities After Pairing
- `binary_sensor.eve_balcony_contact`
- `binary_sensor.eve_frontdoor_contact`

---

## Task 2: Migration of Logic (The "Brain" Shift)

### Current Logic Fragmentation
| Location | Logic Type |
|----------|------------|
| Wyze App | "Descanso" scene, "Cena" scene |
| Tado App | Per-room heating schedules |
| Apple Home | "Last person leaves" automation |
| HA | Sunset lights, lights off schedules |

### Target State
All logic in Home Assistant. Apps become dumb displays.

### Wyze Scenes → HA Scenes

#### Descanso (Rest/Sleep) Scene
From screenshots: All Salón lights at very low brightness, warm color
```yaml
# scenes.yaml addition
- id: 'descanso'
  name: Descanso
  icon: mdi:sleep
  entities:
    light.floor_lamp:
      state: 'on'
      brightness: 3
      color_temp: 500
    light.book_floor_lamp:
      state: 'on'
      brightness: 3
      color_temp: 500
    light.table_lamp:
      state: 'on'
      brightness: 3
      color_temp: 500
    light.floor_lamp_new:
      state: 'on'
      brightness: 3
      color_temp: 500
    light.shelly_luz_outdoor:
      state: 'off'
    light.shelly_luz_salon:
      state: 'off'
```

#### Cena Scene Already Exists
Current "Cena" scene in HA matches Wyze version. ✅

### Tado Schedules Analysis

From screenshots:

| Room | Mon-Fri | Saturday | Sunday |
|------|---------|----------|--------|
| **Salón** | 18°→22° @8am | 18°→22° @8am | 18°→22° @8am |
| **Master Bedroom** | 20°→21.5° @8am | 20°→21.5° @8am | 20°→21.5° @8am |
| **Office** | 18°→22.5° @8am, Off @4pm | 18°→21° @8am, Off @4pm | 18°→21° @8am, Off @4pm |
| **Upstairs Aisle** | 18°→21° @8am (all days) |
| **Bathroom** | Complex 4-period schedule (varies by day) |

### Recommendation: Keep Tado Schedules
Tado's native schedules should remain for:
- **Reliability**: Local device scheduling survives HA downtime
- **Efficiency**: Tado optimizes based on weather/insulation
- **Complexity**: Bathroom's multi-period schedule is tedious in HA

**HA should handle**: 
- Away/Home mode switching (geofencing)
- Manual overrides
- Integration with presence detection

### Away Mode Automation (Replaces Apple Home Automation)
```yaml
# automations.yaml addition
- id: 'away_mode_all_left'
  alias: "Away Mode - Everyone Left"
  trigger:
    - platform: state
      entity_id: group.persons
      to: 'not_home'
      for:
        minutes: 10
  condition: []
  action:
    - service: climate.set_preset_mode
      target:
        entity_id:
          - climate.salon
          - climate.master_bedroom
          - climate.office
          - climate.upstairs_aisle
          - climate.bathroom
      data:
        preset_mode: away
    - service: light.turn_off
      target:
        entity_id: light.all_lights
    - service: rest_command.slack_notify
      data:
        message: "🏠 Away mode activated - everyone left home"

- id: 'home_mode_first_arrives'
  alias: "Home Mode - First Person Arrives"
  trigger:
    - platform: state
      entity_id: group.persons
      to: 'home'
  condition:
    - condition: state
      entity_id: climate.salon
      attribute: preset_mode
      state: 'away'
  action:
    - service: climate.set_preset_mode
      target:
        entity_id:
          - climate.salon
          - climate.master_bedroom
          - climate.office
          - climate.upstairs_aisle
          - climate.bathroom
      data:
        preset_mode: home
    - service: rest_command.slack_notify
      data:
        message: "🏠 Welcome home! Heating restored."
```

---

## Task 3: HomeKit Bridge Cleanup

### Current State
- **HASS Bridge:21064** - Main bridge exposing many domains
- **Cobi TV:21065** - Single accessory (remote)
- **Cobi TV:21066** - Single accessory (media_player)

### Issues
1. Bridge exposes too many entities (all domains)
2. Sensitive entities exposed (device_tracker, automation)
3. Eve sensors not exposed (not in HA yet)

### Optimized Filter Configuration
```yaml
# Update via UI: Settings → Devices & Services → HomeKit → Configure
filter:
  include_domains:
    - light
    - climate
    - scene
    - binary_sensor
  include_entities:
    - binary_sensor.eve_balcony_contact  # After Matter pairing
    - binary_sensor.eve_frontdoor_contact
  exclude_entities:
    - binary_sensor.tado_online
    - binary_sensor.wyze_online
    # Exclude internal sensors
```

### Entities to Expose via HomeKit
| Entity Type | Entities | Siri Command |
|-------------|----------|--------------|
| **Lights** | All 6 lights + groups | "Turn off living room lights" |
| **Scenes** | Chill, Cena, Descanso | "Hey Siri, Goodnight" → Descanso |
| **Climate** | All 5 zones | "Set bedroom to 20 degrees" |
| **Door Sensors** | Eve Balcony, Eve FrontDoor | "Is the front door open?" |

---

## Task 4A: Presence Detection

### Current Device Trackers
From Tado integration:
- `device_tracker.choco_iphone`
- `device_tracker.candelin`
- `device_tracker.candelin_iphone`
- `device_tracker.iphone13mini`
- `device_tracker.choco13mini`
- `device_tracker.candelaiphone12mini`

### Create Binary Sensor Group
```yaml
# configuration.yaml addition
template:
  - binary_sensor:
      - name: "Anyone Home"
        unique_id: anyone_home
        device_class: presence
        state: >
          {{ is_state('group.persons', 'home') }}
        
      - name: "Home Occupied"
        unique_id: home_occupied
        device_class: occupancy
        state: >
          {{ is_state('device_tracker.choco_iphone', 'home')
             or is_state('device_tracker.candelin_iphone', 'home')
             or is_state('device_tracker.choco13mini', 'home')
             or is_state('device_tracker.candelaiphone12mini', 'home') }}
```

### Persons Group Already Exists
```yaml
# groups.yaml (current)
persons:
  name: persons
  entities:
    - person.candela
    - person.choco
```

---

## Task 4B: Mobile Dashboard

### Design Principles
- **Big buttons** - Easy tap targets
- **High contrast** - Quick visual scan
- **Minimal** - Only essential controls

### Dashboard YAML
```yaml
# lovelace dashboard: mobile_control
title: Control
views:
  - title: Home
    path: home
    icon: mdi:home
    cards:
      # Status Row
      - type: horizontal-stack
        cards:
          - type: entity
            entity: binary_sensor.anyone_home
            name: Presence
            icon: mdi:home-account
          - type: entity
            entity: binary_sensor.eve_frontdoor_contact
            name: Front Door
          - type: entity
            entity: binary_sensor.eve_balcony_contact
            name: Balcony

      # Scene Buttons
      - type: horizontal-stack
        cards:
          - type: button
            entity: scene.chill
            name: Relax
            icon: mdi:flower-tulip
            tap_action:
              action: call-service
              service: scene.turn_on
              service_data:
                entity_id: scene.chill
            hold_action:
              action: none
          - type: button
            entity: scene.cena
            name: Dinner
            icon: mdi:food
            tap_action:
              action: call-service
              service: scene.turn_on
              service_data:
                entity_id: scene.cena
          - type: button
            entity: scene.descanso
            name: Sleep
            icon: mdi:sleep
            tap_action:
              action: call-service
              service: scene.turn_on
              service_data:
                entity_id: scene.descanso

      # Quick Actions
      - type: horizontal-stack
        cards:
          - type: button
            name: All Lights Off
            icon: mdi:lightbulb-off
            tap_action:
              action: call-service
              service: light.turn_off
              target:
                entity_id: light.all_lights
          - type: button
            entity: input_boolean.guest_mode
            name: Guest Mode
            icon: mdi:account-multiple
            show_state: true

      # Climate Summary
      - type: thermostat
        entity: climate.salon
        name: Living Room

      # Heating Status
      - type: glance
        title: Heating
        entities:
          - entity: sensor.salon_temperature
            name: Salón
          - entity: sensor.master_bedroom_temperature
            name: Bedroom
          - entity: sensor.office_temperature
            name: Office
```

### Guest Mode Input Boolean
```yaml
# configuration.yaml addition
input_boolean:
  guest_mode:
    name: Guest Mode
    icon: mdi:account-multiple
```

### Guest Mode Automation
```yaml
# automations.yaml addition
- id: 'guest_mode_disable_away'
  alias: "Guest Mode - Disable Auto Away"
  trigger:
    - platform: state
      entity_id: input_boolean.guest_mode
      to: 'on'
  action:
    - service: automation.turn_off
      target:
        entity_id: automation.away_mode_all_left
    - service: rest_command.slack_notify
      data:
        message: "👥 Guest mode enabled - away automation disabled"

- id: 'guest_mode_enable_away'
  alias: "Guest Mode Off - Enable Auto Away"
  trigger:
    - platform: state
      entity_id: input_boolean.guest_mode
      to: 'off'
  action:
    - service: automation.turn_on
      target:
        entity_id: automation.away_mode_all_left
    - service: rest_command.slack_notify
      data:
        message: "👥 Guest mode disabled - away automation restored"
```

---

## Implementation Order

### Phase 1: Matter Server (Prerequisites)
1. [ ] Create Matter Server data directory
2. [ ] Deploy Matter Server container
3. [ ] Verify container running and accessible
4. [ ] Add Matter integration in HA

### Phase 2: Eve Sensor Pairing
5. [ ] Put Eve-FrontDoor in pairing mode (Apple Home)
6. [ ] Commission in HA Matter integration
7. [ ] Verify entity appears
8. [ ] Repeat for Eve-Balcony

### Phase 3: Logic Migration
9. [ ] Add Descanso scene
10. [ ] Add Away/Home automations
11. [ ] Add Guest Mode input_boolean
12. [ ] Add Guest Mode automations
13. [ ] Test all automations

### Phase 4: HomeKit Cleanup
14. [ ] Update HomeKit Bridge filter
15. [ ] Re-pair HomeKit Bridge if needed
16. [ ] Verify Siri commands work
17. [ ] Delete old Apple Home automation

### Phase 5: Dashboard
18. [ ] Create mobile dashboard
19. [ ] Test on iOS

### Phase 6: Ansible Port
20. [ ] Create HA config files in ansible role
21. [ ] Add Matter Server to docker-compose template
22. [ ] Test deployment

---

## Files to Create/Modify

### New Files
- `ansible/roles/services/homeassistant/files/matter-server-compose.yml`
- `ansible/roles/services/homeassistant/templates/configuration.yaml.j2`
- `ansible/roles/services/homeassistant/templates/automations.yaml.j2`
- `ansible/roles/services/homeassistant/templates/scenes.yaml.j2`
- `ansible/roles/services/homeassistant/files/lovelace-mobile.yaml`

### Modified Files
- `ansible/roles/services/homeassistant/tasks/main.yml` (add Matter Server)
- `ansible/inventory/group_vars/homeassistant.yml` (Matter config vars)

---

## Validation Checklist

### After Phase 2
- [ ] `binary_sensor.eve_frontdoor_contact` exists
- [ ] `binary_sensor.eve_balcony_contact` exists
- [ ] Both show correct open/closed state

### After Phase 3
- [ ] Scene "Descanso" activates correctly
- [ ] Away mode triggers when both leave
- [ ] Home mode triggers when first arrives
- [ ] Guest mode disables away automation

### After Phase 4
- [ ] "Hey Siri, turn on Descanso" works
- [ ] "Hey Siri, is the front door open?" returns correct state
- [ ] All lights controllable via Siri

### After Phase 5
- [ ] Dashboard loads on mobile
- [ ] All buttons functional
- [ ] Temperature readings accurate
