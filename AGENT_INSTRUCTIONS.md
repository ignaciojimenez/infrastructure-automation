# Agent Instructions — Infrastructure Automation Framework

Ansible-based homelab automation framework for Raspberry Pis, LXC containers,
Proxmox hypervisors, and OPNsense firewalls.

## Repository Layout

```
ansible/
  inventory/
    hosts.yml                        # Your inventory (copy from hosts.yml.example)
    group_vars/all/main.yml          # Global defaults
    group_vars/all/vault.yml         # Encrypted secrets (Ansible Vault, AES256)
    group_vars/{function}.yml        # Per-function variables (loaded by primary_function)
  playbooks/
    site.yml                         # Full orchestration — 8 phases
    services.yml                     # Service deployment (auto-discovers roles)
    deploy_monitoring.yml            # Deploy monitoring scripts to all hosts
    bootstrap.yml                    # First-run bootstrap
    system/                          # preflight, baseline, updates, validation
    platform/                        # Per-platform config (debian, freebsd, raspberrypi, lxc, proxmox)
    tasks/                           # Reusable task files (ssh_hardening, media_storage, etc.)
  roles/
    _skeleton/                       # Template role — copy this when adding a new service
    services/{service}/              # One role per service
    platform/{platform}/             # Platform monitoring and platform-specific config
scripts/
  common/                            # Shared monitoring scripts (POSIX sh, FreeBSD-compatible)
  services/{service}/                # Per-service scripts
templates/
  debian/                            # Shared Debian templates (sshd_config, unattended-upgrades)
```

## Creating a New Service Role

1. **Copy the skeleton:**
   ```bash
   cp -r ansible/roles/_skeleton ansible/roles/services/my_service
   ```

2. **Fill in `defaults/main.yml`** — document every variable with its type and purpose.

3. **Implement `tasks/main.yml`** — follow the rules below.

4. **Add the host to inventory** (`ansible/inventory/hosts.yml`):
   ```yaml
   my_new_host:
     primary_function: my_service
   ```
   The role is auto-discovered via `primary_function` — no edits to `services.yml` needed.

5. **Optionally create `group_vars/my_service.yml`** for function-level variable overrides.

6. **Validate before deploying:**
   ```bash
   ansible-lint
   ansible-playbook ansible/playbooks/services.yml --syntax-check
   ansible-playbook ansible/playbooks/services.yml --limit my_new_host --check --diff
   ```

## Ansible Coding Rules

| Rule | Example |
|------|---------|
| FQCN for all modules | `ansible.builtin.apt`, NOT `apt` |
| Booleans | `true`/`false`, NEVER `yes`/`no` |
| Tags on every task | `tags: [service_name, category]` |
| `become: true` per-task | NOT globally on the play |
| Guard hardware tasks | `when: not (is_test_environment \| default(false))` |
| Variable defaults | `{{ var \| default('sane_default') }}` |
| No dead code | Delete disabled tasks; git has history |

## Variable Conventions

| Pattern | Purpose | Example |
|---------|---------|---------|
| `enable_*` | Feature toggles | `enable_monitoring: true` |
| `*_dir` | Directory paths | `scripts_dir`, `logs_dir` |
| `{service}_*` | Service config | `icecast_port: 8000` |
| `install_*` | Explicit additional role | `install_docker: true` |
| `vault_*` | Secrets (vault.yml only) | `vault_alert_token` |
| `is_test_environment` | Skip hardware-dependent tasks in CI/test | `is_test_environment: true` |

## Variable Loading Order (highest precedence last)

1. `group_vars/all/main.yml` — global defaults
2. `group_vars/all/vault.yml` — encrypted secrets
3. `group_vars/{primary_function}.yml` — function-level config
4. `hosts.yml` host vars — rare host-specific overrides only

## Idempotency Rules

- Every task must be safe to run repeatedly with no side effects.
- `shell`/`command` tasks: use `changed_when: false` or a `creates:` guard.
- Package installs: `state: present` (not `latest`, unless updating is intentional).
- Service management: `enabled: true` + `state: started`, NEVER `state: restarted` directly.
- Use handlers for service restarts triggered by config changes.

## Monitoring Pattern

Every service role that deploys monitoring follows this pattern:

```yaml
- name: Deploy check script
  ansible.builtin.copy:
    src: "{{ inventory_dir }}/../../scripts/services/{service}/check_{service}.sh"
    dest: "{{ scripts_dir }}/check_{service}.sh"
    mode: '0755'
  tags: [{service}, monitoring]

- name: Configure monitoring cron
  ansible.builtin.cron:
    name: "{service} service check"
    special_time: "hourly"
    job: >
      {{ scripts_dir }}/enhanced_monitoring_wrapper
      --heartbeat-interval=daily
      --notify-fixed=true
      {{ logging_token }}
      {{ alert_token }}
      {{ scripts_dir }}/check_{service}.sh
      >> {{ logs_dir }}/{service}_check.log 2>&1
    user: "{{ ansible_user }}"
  when:
    - logging_token is defined and logging_token != ''
    - alert_token is defined and alert_token != ''
  tags: [{service}, monitoring, cron]
```

## Agent Access Role

The `agent_access` role deploys a read-only `read_agent` SSH user to every host. It runs
automatically as **Phase 4b** in `site.yml` (after baseline, before platform config).

| What it does | Detail |
|---|---|
| Creates `read_agent` user | No password, key-only auth, shell `/bin/sh` |
| Deploys `authorized_keys` | IP-restricted via `from=` to the control machine IP |
| Deploys sudoers rules | Read-only diagnostics only (`systemctl status`, `journalctl`, etc.) |
| Platform-aware | Separate sudoers templates for Debian and FreeBSD |
| Removes legacy `claude_agent` | Cleans up prior naming if present |

**Required vault variables** (add to `vault.yml`):

```yaml
vault_agent_control_ip: "192.168.1.x"   # IP of your control machine
vault_agent_ssh_pubkey: "ssh-ed25519 AAAA..."  # Public key for the agent SSH key
vault_agent_ssh_passphrase: "..."        # Passphrase for the private key
```

The private key lives at `~/.ssh/read_agent_ed25519` on the control machine (outside any
hardware security key), so agents can use it unattended. See `docs/AGENT_ACCESS.md` for
the full design and SSH config setup.

## Testing Strategy

**Tier 1 — Static analysis (run before every commit):**
```bash
ansible-lint
ansible-playbook ansible/playbooks/services.yml --syntax-check
```

**Tier 2 — Dry run (before applying to a real host):**
```bash
ansible-playbook ansible/playbooks/services.yml --limit hostname --check --diff
```

**Tier 3 — Test host (optional integration test):**
```bash
cp ansible/inventory/test_hosts.yml.example ansible/inventory/test_hosts.yml
# Edit test_hosts.yml: set ansible_host to your test machine's IP
ansible-playbook -i ansible/inventory/test_hosts.yml ansible/playbooks/site.yml
```
The `is_test_environment: true` flag in the test inventory gates hardware-specific tasks.

## Platform Reference

| Platform | `os_family` | Service manager | Package manager |
|----------|-------------|----------------|-----------------|
| `raspberrypi` | `debian` | systemd | apt |
| `lxc` | `debian` | systemd | apt |
| `proxmox` | `debian` | systemd | apt |
| `opnsense` | `freebsd` | rc | pkg |

## Do Not

- Edit remote files directly — all config is managed from this repo.
- Commit plaintext secrets — use `vault.yml` (Ansible Vault, AES256).
- Hardcode IP addresses, hostnames, or usernames — use inventory variables.
- Add `yes`/`no` booleans — use `true`/`false`.
- Use bare module names — always use FQCN (`ansible.builtin.*`).
- Comment out code — delete it; git preserves history.
- Edit `services.yml` to add a new role — set `primary_function` in inventory instead.
