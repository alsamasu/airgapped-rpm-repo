# Host Onboarding Role

Onboards managed hosts to the airgapped RPM infrastructure.

## What This Role Does

1. **Pre-flight Validation**
   - Validates `airgap_host_id` is set
   - Checks OS compatibility (RHEL/AlmaLinux 8+)
   - Verifies network connectivity
   - Checks available disk space

2. **Host Identity Configuration**
   - Creates `/etc/airgap/host-identity` file
   - Sets unique host identifier for tracking

3. **Repository Configuration**
   - Disables external repositories (optional)
   - Configures internal HTTPS repository
   - Imports GPG signing key
   - Sets lifecycle environment (testing/stable)

4. **Syslog TLS Forwarding**
   - Installs rsyslog-gnutls
   - Configures TLS forwarding (server-auth only)
   - Adds host identity to log messages

5. **Manifest Collection**
   - Collects installed package list
   - Records system information
   - Saves to controller for processing

6. **Verification**
   - Tests repository connectivity
   - Verifies configuration files
   - Checks service status

## Requirements

- `airgap_host_id` must be defined for each host
- Target hosts must be RHEL/AlmaLinux/Rocky 8.x or 9.x
- Network connectivity to internal repository server
- SSH access (key-based preferred)

## Role Variables

```yaml
# Host identity
airgap_host_id: ""  # REQUIRED - unique host identifier

# Pre-flight checks
preflight_check_connectivity: true
preflight_check_dns: true
preflight_check_disk_space_mb: 500

# Repository configuration
onboard_configure_repo: true
onboard_disable_external_repos: true
repo_lifecycle_env: stable  # or 'testing'

# Syslog configuration
onboard_configure_syslog: true
syslog_tls_target_host: syslog-sink
syslog_tls_target_port: 6514

# Manifest collection
onboard_collect_manifest: true
manifest_dir: "{{ playbook_dir }}/../artifacts/manifests"

# Verification
onboard_verify_connectivity: true
onboard_verify_packages: true
```

## Example Inventory

```yaml
all:
  vars:
    internal_repo_url: "https://rpm-publisher:8443"
    syslog_tls_target_host: syslog-sink
    repo_lifecycle_env: stable
    
  children:
    managed_hosts:
      hosts:
        webserver1:
          airgap_host_id: webserver1-prod-01
        dbserver1:
          airgap_host_id: dbserver1-prod-01
```

## Example Playbook

```yaml
- name: Onboard hosts
  hosts: managed_hosts
  become: true
  roles:
    - role: host_onboarding
```

## Usage

```bash
# Onboard all managed hosts
ansible-playbook playbooks/onboard_hosts.yml

# Onboard specific host
ansible-playbook playbooks/onboard_hosts.yml --limit webserver1

# Use testing lifecycle
ansible-playbook playbooks/onboard_hosts.yml -e repo_lifecycle_env=testing

# Skip syslog configuration
ansible-playbook playbooks/onboard_hosts.yml -e onboard_configure_syslog=false

# Run only verification
ansible-playbook playbooks/onboard_hosts.yml --tags verify

# Dry run
ansible-playbook playbooks/onboard_hosts.yml --check
```

## Tags

| Tag | Description |
|-----|-------------|
| `preflight` | Pre-flight validation only |
| `identity` | Host identity configuration |
| `repository` | Repository configuration |
| `syslog` | Syslog TLS configuration |
| `manifest` | Manifest collection |
| `verify` | Verification checks |
| `onboard` | Full onboarding (all above) |

## Files Created on Target

| Path | Description |
|------|-------------|
| `/etc/airgap/host-identity` | Host identity configuration |
| `/etc/yum.repos.d/internal.repo` | Repository configuration |
| `/etc/rsyslog.d/60-tls-forward.conf` | Syslog TLS forwarding |
| `/etc/rsyslog.d/50-host-identity.conf` | Host identity in logs |
| `/etc/pki/rpm-gpg/RPM-GPG-KEY-internal` | GPG signing key |

## Troubleshooting

### Repository connectivity fails
```bash
# Test HTTPS access
curl -k https://rpm-publisher:8443/

# Check DNS resolution
getent hosts rpm-publisher

# Verify firewall
firewall-cmd --list-all
```

### Syslog forwarding fails
```bash
# Check rsyslog status
systemctl status rsyslog

# Test TLS connection
openssl s_client -connect syslog-sink:6514

# Check rsyslog logs
journalctl -u rsyslog -n 50
```

### GPG key import fails
```bash
# Manual import
curl -k https://rpm-publisher:8443/keys/RPM-GPG-KEY-internal \
  -o /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
```
