# Configuration Strategy

## Core Principles

### 1. **Variables Over Groups**
**Always use variables** for feature toggles, never inventory groups.

❌ **Bad (Inconsistent):**
```yaml
when: "'feature_enabled' in group_names"
```

✅ **Good (Consistent):**
```yaml
when: enable_feature | default(false)
```

**Why:** Variables can be set globally, per-role, or per-host. Groups require inventory changes and are harder to override.

### 2. **Global Defaults in `group_vars/all/main.yml`**
Define all toggles in one place with sensible defaults:

```yaml
# System configuration
enable_unattended_upgrades: true  # Security updates for all hosts
enable_monitoring: true            # Monitoring for all hosts
```

Override per-host only when needed:
```yaml
hosts:
  testhost:
    enable_monitoring: false  # Disable for this specific host
```

### 3. **No Dead Code**
- ❌ Never use `when: false` - delete the task instead
- ❌ Never create unused templates or files
- ❌ Remove disabled features completely, don't comment them out

If you need to preserve logic for future reference, move it to docs, not code.

### 4. **Consistent Variable Naming**
```yaml
# Feature toggles - use enable_ prefix
enable_monitoring: true
enable_unattended_upgrades: true
enable_audio_detection: true

# Paths - use _dir suffix  
scripts_dir: "/home/{{ primary_user }}/.scripts"
logs_dir: "/home/{{ primary_user }}/.logs"
home_dir: "/home/{{ primary_user }}"

# Services - use service name
icecast_source_password: "..."
liquidsoap_sample_rate: 48000
```

### 5. **Configuration Loading Order**
1. `group_vars/all/main.yml` - Global defaults for ALL hosts
2. `group_vars/{platform}.yml` - Platform-specific (raspberrypi, lxc, freebsd)
3. `group_vars/{primary_function}.yml` - Role-specific (audio_streaming, dns, etc.)
4. `hosts.yml` host-specific overrides - Only when truly unique
5. `host_vars/{hostname}.yml` - Rarely used, for complex host-specific config

## Examples

### Feature Toggle Pattern
```yaml
# In playbook
- name: Install monitoring
  ansible.builtin.include_tasks: monitoring.yml
  when: enable_monitoring | default(true)
```

### Service-Specific Config
```yaml
# In group_vars/audio_streaming.yml
enable_icecast: true
enable_liquidsoap: true
enable_audio_detection: true
liquidsoap_sample_rate: 48000
```

### Per-Host Override
```yaml
# In hosts.yml
vinylstreamer:
  primary_function: audio_streaming
  liquidsoap_sample_rate: 96000  # Override for better quality
```

## Anti-Patterns to Avoid

1. ❌ Using inventory groups for features (`auto_updates_enabled`, `monitoring_enabled`)
2. ❌ Disabled tasks (`when: false`)
3. ❌ Unused variables defined but never checked
4. ❌ Inconsistent variable names (`log_dir` vs `logs_dir`)
5. ❌ Complex nested group hierarchies
6. ❌ Duplicate configuration in multiple places

## Migration Checklist

When refactoring configuration:

- [ ] Replace all `in group_names` checks with variable checks
- [ ] Remove all `when: false` tasks
- [ ] Delete unused templates and files
- [ ] Verify all variables in `group_vars` are actually used
- [ ] Ensure consistent naming conventions
- [ ] Update documentation
- [ ] Test on devpi before production deployment
