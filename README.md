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

# 3. Store vault password locally (not in repo). On macOS, use a Keychain-backed helper script referenced by `ANSIBLE_VAULT_PASSWORD_FILE` (see docs/ARCHITECTURE_DECISIONS.md).
```

> **Note:** This repo includes MY encrypted `vault.yml` for personal backup. 

## Services by Function

- **audio_playback** → MPD, Shairport, Raspotify
- **audio_streaming** → Icecast, Liquidsoap, detect_audio
- **media** → Plex, Transmission, Samba
- **homeassistant** → Docker, Home Assistant
- **firewall** → OPNsense (Unbound DNS, WireGuard VPN, CrowdSec)
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

**Start here** — [docs/NETWORK.md](docs/NETWORK.md) is the layer that isn't in the code:
six VLANs, thirteen WireGuard tunnels, and the physical topology, read from the live
firewall rather than inferred.

| Doc | What it answers |
|---|---|
| **[NETWORK.md](docs/NETWORK.md)** | Segmentation, VPN, DNS, the physical layer, and a list of confirmed defects |
| **[ARCHITECTURE_DECISIONS.md](docs/ARCHITECTURE_DECISIONS.md)** | Standing rules — consult before designing anything new |
| **[BACKUP_AND_RECOVERY.md](docs/BACKUP_AND_RECOVERY.md)** | What is backed up, and how to rebuild each host — **including losing the laptop** |
| **[AGENT_ACCESS.md](docs/AGENT_ACCESS.md)** | The read-only `read_agent` account: threat model, sudo scope, revocation |
| **[AGENT_LXC.md](docs/AGENT_LXC.md)** | The fleet-observer container (CT 103) — operator reference |
| **[OPNSENSE_API.md](docs/OPNSENSE_API.md)** | Reading the firewall over its API instead of SSH |
| **[AUDIO_AUTOMATION.md](docs/AUDIO_AUTOMATION.md)** | Source-driven amp power + IR input routing |
| **[TESTING_GOALS.md](docs/TESTING_GOALS.md)** | What the test rig is *for* — read before test work |
| **[TEST_CONTAINER.md](docs/TEST_CONTAINER.md)** | The ephemeral LXC rig and how to drive it |
| **[TODO.md](docs/TODO.md)** | Open work, ranked, each item with a paste-ready prompt |
| **[archive/DONE.md](docs/archive/DONE.md)** | Finished work and *why* — so a conclusion is not re-derived |
| **[RESTORE_TEST_LOG.md](docs/RESTORE_TEST_LOG.md)** | Quarterly restore-test results |

> **This repo is public, and what it discloses is tiered on purpose.** Mechanisms and
> reasoning are published; correlations that would shorten the path from *"be in range"*
> to *"know which weakness to hit"* live in an untracked `docs/local/`. The rule is in
> [ARCHITECTURE_DECISIONS.md](docs/ARCHITECTURE_DECISIONS.md#disclosure-tiering--what-goes-in-a-public-repo).
