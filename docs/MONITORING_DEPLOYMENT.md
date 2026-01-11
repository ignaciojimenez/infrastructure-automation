# Monitoring Script Deployment

Quick reference for the most common operation: deploying monitoring script updates to all hosts.

## Active Debian Hosts

**Raspberry Pi:**
- cobra (media)
- dockassist (homeassistant)
- hifipi (audio_playback)
- vinylstreamer (audio_streaming)

**LXC Containers:**
- unifi-lxc (network_controller)

**Proxmox:**
- proxmox/cwwk (hypervisor)

**FreeBSD:**
- opnsense (firewall)

**Note:** devpi is unreachable (DNS resolution issue)

## The Workflow

```bash
# 1. Edit scripts in scripts/common/
vim scripts/common/system_health_check.sh

# 2. Test on one host first
ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit testpi

# 3. Deploy to all hosts
ansible-playbook ansible/playbooks/deploy_monitoring.yml
```

## One-Liner (Deploy to All)

```bash
ansible-playbook ansible/playbooks/deploy_monitoring.yml
```

## Scripts Managed

**All scripts** in `scripts/common/` are automatically deployed:
- **enhanced_monitoring_wrapper** - Wrapper for all monitoring tasks
- **system_health_check.sh** - System health diagnostics
- **do_backup** - Backup orchestration
- **Any new scripts you add** - Automatically included!

The playbook scans `scripts/common/` and deploys everything it finds. Just add a new script to that directory and run the playbook.

## Why This Matters

Generic scripts must be deployed to all hosts consistently to prevent configuration drift. This dedicated playbook makes that operation simple and fast.

## Advanced Options

```bash
# Deploy to specific host group
ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit raspberrypi

# Deploy to multiple specific hosts
ansible-playbook ansible/playbooks/deploy_monitoring.yml --limit vinylstreamer,hifipi,cobra

# Dry run (check what would change)
ansible-playbook ansible/playbooks/deploy_monitoring.yml --check

# Verbose output
ansible-playbook ansible/playbooks/deploy_monitoring.yml -v
```

## Integration with Full Deployment

Monitoring scripts are also deployed as part of the full site deployment:

```bash
# Full deployment includes monitoring scripts
ansible-playbook ansible/playbooks/site.yml

# Or just update scripts across everything
ansible-playbook ansible/playbooks/site.yml --tags scripts
```

But the dedicated `deploy_monitoring.yml` playbook is faster and clearer for this common operation.
