# Living Room Audio Automation

Home Assistant powers and routes a vintage Pioneer SA-508 amplifier based on which
audio/video source is active. The amp has no remote control of any kind: power is
switched at the mains by a Shelly plug, and its single input is fed by a 4-way RCA
switcher driven over IR by a Broadlink blaster.

Everything below `Home Assistant` in the diagram is config-managed in this repo
(`ansible/roles/services/homeassistant/`); deploy with
`ansible-playbook ansible/playbooks/services.yml --limit dockassist --tags config`.

## Architecture

```mermaid
flowchart TD
    %% Audio Sources (Physical Layer)
    TV[Smart TV] -->|Optical| DAC[JDS Labs DAC]
    Vinyl[Vinyl Turntable] -->|Phono| VinylPi[vinylstreamer RPi<br/>detect_audio + Liquidsoap → Icecast]
    VinylPi -.->|Icecast stream| HifiPi[hifipi RPi 4 + DAC2 HD<br/>MPD / Shairport / Raspotify]
    Spotify[Spotify Connect] -.-> HifiPi
    AirPlay[AirPlay] -.-> HifiPi

    %% Physical Routing Layer
    DAC -->|RCA → Input 1| Switch[ATNEDCVH 4-Way IR Switcher]
    HifiPi -->|RCA → Input 2| Switch

    %% Power, Amp & Output Layer
    Switch -->|RCA Out to AUX IN| Pioneer[Pioneer SA-508]
    Shelly[Shelly Plug S Gen3] -->|Mains power| Pioneer
    Pioneer -->|Tape Loop| Karaoke[Karaoke Mixer]
    Pioneer --> Speakers[Tannoy Speakers]

    %% Home Assistant (The Brain)
    subgraph HA[Home Assistant: dockassist]
        subgraph Entities[Live Source Entities]
            E_TV[media_player.cobi_tv_3]
            E_AP[binary_sensor.shairport_sync_hifipi_playing]
            E_SP[binary_sensor.raspotify_hifipi_playing]
            E_VINYL[binary_sensor.vinyl_vinylstreamer_playing<br/>MQTT push, ~1-2s]
            E_MPD[media_player.music_player_daemon<br/>~10s poll fallback]
        end

        subgraph Templates[Template Logic]
            TS_Active[binary_sensor.amp_source_active<br/>OR of all sources]
            TS_Source[sensor.amp_active_source<br/>pi / tv / none — Pi wins over TV]
        end

        subgraph Automations[Automations]
            A_Power[amp_power_on / amp_power_off<br/>on: instant · off: 5-min grace]
            A_Input[amp_input_select<br/>source change: 3s debounce<br/>plug-on: instant re-align]
            A_Reconcile[amp_reconcile_on_start<br/>HA restart → plug = source state]
            A_Watchdog[amp_plug_cycling_watchdog<br/>plug on >3×/h → Slack alert]
        end
    end

    %% Source → template mapping
    E_TV -.-> TS_Active
    E_AP -.-> TS_Active
    E_SP -.-> TS_Active
    E_VINYL -.-> TS_Active
    E_MPD -.-> TS_Active

    E_TV -.-> TS_Source
    E_AP -.-> TS_Source
    E_SP -.-> TS_Source
    E_VINYL -.-> TS_Source
    E_MPD -.-> TS_Source

    %% Vinyl signal path into HA
    VinylPi -.->|MQTT vinyl/vinylstreamer/playing| E_VINYL

    %% Automation triggers
    TS_Active -->|Drives power| A_Power
    TS_Active --> A_Reconcile
    TS_Source -->|Drives routing| A_Input
    Shelly -.->|plug turns on| A_Input

    %% Physical actions (Control Layer)
    A_Power -.->|Local RPC| Shelly
    Shelly -.->|history_stats: on-count 1h| A_Watchdog
    A_Watchdog -.->|>3 on/hour| Slack[Slack #home-alerts]
    A_Input -.->|Local API| Broadlink[Broadlink RM4 Mini]
    Broadlink -.->|IR: rca_switcher/input_tv → 1<br/>rca_switcher/input_pi → 2| Switch
```

## Behavior

- **Power on** is instant: any source going active (AirPlay/Spotify/vinyl playing,
  or the TV powering on) switches the plug on. Debounce against phantom vinyl
  starts lives in `detect_audio` on vinylstreamer, not in HA.
- **Power off** waits a 5-minute idle grace so track gaps and short pauses don't
  cut the amp.
- **Input selection**: `sensor.amp_active_source` picks `pi`/`tv` (active Pi
  playback beats a merely-on TV). On change, the RM4 fires the matching learned
  IR code at the switcher (3s debounce); when the plug turns on, the input is
  re-aligned instantly. Learned codes are checked into the role and seeded to
  `.storage` only-if-missing (see ARCHITECTURE_DECISIONS).
- **Resilience**: an HA restart reconciles the plug against source state; a
  watchdog pages `#home-alerts` if the plug starts cycling (>3 on-events/hour).

Verified end-to-end with the amp under power 2026-07-18: instant on (~12W idle
draw), three 5-min-grace auto-offs, and IR input switching on real source changes.
