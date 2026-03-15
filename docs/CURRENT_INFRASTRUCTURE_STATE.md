# Current Infrastructure State
*Updated: December 20, 2025*

## Architecture Overview

### Network Topology
```
Internet
    ↓
OPNsense (10.30.40.254)
├── WAN: Mullvad VPN (13 WireGuard tunnels)
├── DNS: Unbound (with blocklists)
│   ├── Primary: 4 Mullvad resolvers (10.64.0.1, .3, .7, .11)
│   └── Fallback: Cloudflare (1.1.1.1) - auto-failover
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
- Proxmox health (10 min)
- OPNsense WAN (5 min)

### OPNsense Monitoring
| Check | Frequency | Purpose |
|-------|-----------|---------|
| DNS failover | 1 min | Auto-switch to Cloudflare if all VPN resolvers fail |
| DNS health | 5 min | Verify DNS resolution working |
| WireGuard | 10 min | Tunnel health (WARN: 1-2 down, CRIT: 3+ down) |
| Gateway | 10 min | WAN connectivity |
| VPN gateway | 15 min | Track failover events |
| CrowdSec | 30 min | Security monitoring |
| System health | 30 min | CPU, memory, disk |

### Raspberry Pi Monitoring
All hosts have hourly health checks via `enhanced_monitoring_wrapper` with Slack alerts.

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

### December 19-20, 2025
- ✅ Implemented resilient DNS with 4 Mullvad resolvers (multi-tunnel failover)
- ✅ Changed fallback DNS from Quad9 to Cloudflare (avoids VPN routing issues)
- ✅ Added DNS health monitoring (`check_dns_health.sh`)
- ✅ Updated WireGuard monitoring for 4-tunnel resilience model
- ✅ Added local logging fallback when Slack unreachable

### November 29-30, 2025
- ✅ Migrated DNS from PiHole to OPNsense Unbound with blocklists
- ✅ Implemented VPN-based DNS failover
- ✅ Fixed DNS boot circular dependency

### Pending
- See TODO.md for prioritized task list
