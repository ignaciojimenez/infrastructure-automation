# Infrastructure Automation

Ansible automation for Raspberry Pis, LXC, Proxmox, and OPNsense.

## Quick Start

```bash
# Deploy to host
ansible-playbook ansible/playbooks/site.yml --limit hostname

# Test first with a test host (recommended)
ansible-playbook -i ansible/inventory/test_hosts.yml ansible/playbooks/site.yml
```

**Auto-bootstraps** from fresh install (detects user, creates infrastructure user, hardens security).

## Configuration

**Inventory:** `ansible/inventory/hosts.yml`
```yaml
newhost:
  ansible_host: hostname
  primary_function: audio_streaming  # auto-loads features from group_vars
```

**Secrets:** Configure your own vault
```bash
# 1. Copy the example vault
cp ansible/inventory/group_vars/all/vault.yml.example ansible/inventory/group_vars/all/vault.yml

# 2. Edit with your values
ansible-vault edit ansible/inventory/group_vars/all/vault.yml

# 3. Store vault password locally (not in repo)
```

> **Note:** This repo includes MY encrypted `vault.yml` for personal backup. 

## Services by Function

- **audio_playback** → MPD, Shairport, Raspotify
- **audio_streaming** → Icecast, Liquidsoap, detect_audio
- **media** → Plex, Transmission, Samba
- **homeassistant** → Docker, Home Assistant
- **dns** → Pi-hole
- **network_controller** → UniFi Network application using GleenR script

## Common Commands

```bash
# Deploy everything
ansible-playbook ansible/playbooks/site.yml --limit hostname

# Update specific service
ansible-playbook ansible/playbooks/services.yml --limit hostname --tags audio

# Deploy monitoring scripts to all hosts (common workflow)
ansible-playbook ansible/playbooks/deploy_monitoring.yml
```

## Monitoring Script Development Workflow

1. **Edit/add scripts** in `scripts/common/` (any script you add is auto-deployed!)
2. **Deploy to all hosts:**
   ```bash
   ansible-playbook ansible/playbooks/deploy_monitoring.yml
   ```
3. **Test on one host first (recommended):**
   ```bash
   ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit testpi
   ```

The playbook automatically deploys **all scripts** in `scripts/common/` - no configuration needed!

## Documentation

- **[docs/ARCHITECTURE_DECISIONS.md](docs/ARCHITECTURE_DECISIONS.md)** - Key technical decisions and patterns
- **[docs/CONFIGURATION_STRATEGY.md](docs/CONFIGURATION_STRATEGY.md)** - Configuration patterns and best practices
- **[docs/MONITORING_DEPLOYMENT.md](docs/MONITORING_DEPLOYMENT.md)** - Deploy monitoring script updates
