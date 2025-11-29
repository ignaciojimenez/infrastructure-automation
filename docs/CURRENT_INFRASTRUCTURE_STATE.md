# Current Infrastructure State
*Updated: November 29, 2025*

## Architecture Overview

### Network Topology
```
Internet
    ↓
OPNsense (10.30.40.254)
├── WAN: Mullvad VPN (WireGuard)
├── DNS: Unbound (with blocklists)
│   ├── Primary: VPN resolver (10.64.0.1)
│   └── Fallback: Mullvad public (194.242.2.3)
└── LAN: All internal hosts
```

### Host Inventory

#### Proxmox Host (cwwk)
- **Hardware**: CWWK Mini PC
- **Role**: Hypervisor
- **VMs/Containers**:
  - VM 100: OPNsense (firewall/router)
  - LXC 101: UniFi Controller

#### Raspberry Pi Fleet
1. **cobra** - Media server (Plex - currently inactive)
2. **hifipi** - Audio playback (local DAC)
3. **vinylstreamer** - Audio streaming
4. **dockassist** - Home Assistant (Docker)

#### Network Services
- **OPNsense**: Firewall, VPN gateway, routing, DNS filtering, ad blocking,
- **UniFi**: Network controller for APs and switches

## Service Distribution

### Virtualized (Proxmox)
- All network-critical services
- DNS, firewall, network controller
- Centralized for reliability

### Physical (Raspberry Pi)
- Media services (proximity to storage/devices)
- Audio services (USB DAC requirements)
- Home automation (distributed sensors)

## Monitoring Status

### External Heartbeats (healthchecks.io)
✅ All active and reporting:
- Proxmox health (every 10 min)
- OPNsense DNS (every 5 min) - replaced PiHole
- OPNsense WAN (every 5 min)

### Internal Monitoring
- Platform-specific scripts deployed
- Slack notifications configured
- State tracking prevents alert fatigue
- DNS failover monitoring (every 1 min) - auto-switches on VPN outage

## Backup Strategy

### Current
- Config backups via GPG to curlbin.ignacio.systems
- Proxmox local vzdump (not offsite)
- No automated OPNsense backups

### Issues
- GPG dependency on laptop
- No offsite for large backups
- Manual process for critical hosts

## Authentication & Access

### SSH
- Secretive (Secure Enclave) keys
- GitHub key distribution
- Infrastructure user: `choco`

### Secrets Management
- Ansible Vault (AES256)
- Vault password in macOS Keychain
- Helper script for automation

## Known Issues

### Critical
1. **Backup gaps**: Proxmox/OPNsense
2. **Encryption portability**: GPG laptop-locked

### Operational
1. **Proxmox user**: Using root instead of choco
2. **VPN switching**: Manual process (script exists but needs UUID fix)
3. **Testing**: No automated framework

## Recent Changes

### November 29, 2025
- ✅ Migrated DNS from PiHole to OPNsense Unbound with blocklists
- ✅ Implemented VPN-based DNS failover (primary: 10.64.0.1, fallback: 194.242.2.3)
- ✅ Added DNS heartbeat monitoring to OPNsense

### November 16, 2025
- ✅ Ansible sudo timeout (hostname resolution)
- ✅ Monitoring deployment to all hosts
- ✅ Kernel error duplicate alerts

### Pending
- See TODO.md for prioritized task list
