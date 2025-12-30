# Internal Architecture Guide

## Overview

The internal architecture runs on a single RHEL 9.6 VM in the airgapped environment using rootless Podman. It provides:

- **HTTPS RPM Repository** - Serves packages with TLS encryption
- **Lifecycle Environments** - Testing and Stable channels
- **Ansible Automation** - Host configuration and patching
- **Syslog TLS Forwarding** - Centralized logging with encryption

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         RHEL 9.6 Internal VM                            │
│                         (Rootless Podman)                               │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                      Container Network                            │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐  │  │
│  │  │  rpm-publisher  │  │ ansible-control │  │   syslog-sink    │  │  │
│  │  │   (HTTPS:8443)  │  │  (Ansible EE)   │  │   (TLS:6514)     │  │  │
│  │  │   (HTTP:8080)   │  │                 │  │                  │  │  │
│  │  └────────┬────────┘  └────────┬────────┘  └────────┬─────────┘  │  │
│  │           │                    │                    │            │  │
│  └───────────┼────────────────────┼────────────────────┼────────────┘  │
│              │                    │                    │               │
│  ┌───────────┴────────────────────┴────────────────────┴───────────┐   │
│  │                        /home/rpmops                              │   │
│  │  ├── data/                                                       │   │
│  │  │   ├── repos/          # Repository content                    │   │
│  │  │   ├── lifecycle/      # testing/ and stable/                  │   │
│  │  │   ├── bundles/        # Imported bundles                      │   │
│  │  │   ├── certs/          # TLS certificates                      │   │
│  │  │   └── keys/           # GPG keys                              │   │
│  │  └── ansible/                                                    │   │
│  │      ├── inventory/      # Host inventory                        │   │
│  │      └── artifacts/      # Collected manifests                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
            │  RHEL 8 Host │ │  RHEL 9 Host │ │  RHEL 9 Host │
            │  (managed)   │ │  (managed)   │ │  (managed)   │
            └──────────────┘ └──────────────┘ └──────────────┘
```

## Quick Start

### 1. Development/Testing Environment

```bash
# Start all containers
make internal-up

# Validate the architecture
make internal-validate

# Open Ansible shell
make ansible-shell

# Stop and clean up
make internal-down
```

### 2. Production Deployment

See `deployment/systemd/README.md` for full production deployment instructions.

```bash
# 1. Set up the rpmops user
sudo ./deployment/setup-rpmops-user.sh

# 2. Build container images
sudo -u rpmops podman build -t airgap-rpm-publisher:latest \
    -f containers/rpm-publisher/Containerfile containers/rpm-publisher/

# 3. Enable and start services
sudo -u rpmops systemctl --user enable --now airgap-rpm-publisher
```

## Container Details

### rpm-publisher

**Purpose:** Serves RPM repositories over HTTPS

**Ports:**
- 8080: HTTP (redirects to HTTPS in production)
- 8443: HTTPS with TLS

**Volumes:**
- `/data/repos` - Repository content
- `/data/lifecycle` - Testing/Stable environments
- `/data/certs` - TLS certificates
- `/data/keys` - GPG keys

**Certificate Management:**
1. Self-signed certificate generated on first start
2. To use CA-signed certificate:
   ```bash
   cp your-cert.crt /home/rpmops/data/certs/server.crt
   cp your-key.key /home/rpmops/data/certs/server.key
   systemctl --user restart airgap-rpm-publisher
   ```

### ansible-control

**Purpose:** Ansible Execution Environment for automation

**Volumes:**
- `/runner/project` - Ansible playbooks and roles
- `/runner/inventory` - Host inventory
- `/runner/artifacts` - Output files
- `/runner/.ssh` - SSH keys

**Available Playbooks:**
| Playbook | Purpose |
|----------|---------|
| `bootstrap_ssh_keys.yml` | Deploy SSH keys to hosts |
| `configure_internal_repo.yml` | Configure repo clients |
| `collect_manifests.yml` | Gather package manifests |
| `patch_monthly_security.yml` | Apply security updates |
| `stig_harden_internal_vm.yml` | STIG hardening with syslog |

## Lifecycle Environments

### Overview

Packages flow through lifecycle environments:

```
Bundle Import → Testing → Validation → Stable
```

### Workflow

1. **Import to Testing:**
   ```bash
   podman exec rpm-publisher /opt/rpmserver/import-bundle.sh /data/bundles/incoming/bundle.tar.gz
   ```

2. **Validate:**
   ```bash
   podman exec rpm-publisher /opt/rpmserver/validate-repos.sh --env testing
   ```

3. **Promote to Stable:**
   ```bash
   podman exec rpm-publisher /opt/rpmserver/promote-to-stable.sh
   ```

### Client Configuration

Configure managed hosts to use the internal repository:

```ini
# /etc/yum.repos.d/internal.repo
[internal-stable-baseos]
name=Internal Stable - BaseOS
baseurl=https://rpm-publisher:8443/lifecycle/stable/rhel9/$basearch/baseos
enabled=1
gpgcheck=1
gpgkey=https://rpm-publisher:8443/keys/RPM-GPG-KEY-internal
sslverify=1
sslcacert=/etc/pki/tls/certs/internal-ca.crt
```

## Syslog TLS Configuration

### Overview

Logs are forwarded to a central syslog server using TLS with **server authentication only** (no client certificates/mTLS).

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `syslog_tls_target_host` | (required) | Syslog server hostname/IP |
| `syslog_tls_target_port` | 6514 | TLS syslog port |
| `syslog_tls_ca_bundle_path` | `/etc/pki/tls/certs/syslog-ca.crt` | CA certificate path |

### Deployment

1. **Deploy CA certificate:**
   ```bash
   # Copy syslog server's CA certificate to managed hosts
   ansible -m copy -a "src=syslog-ca.crt dest=/etc/pki/tls/certs/syslog-ca.crt" managed_hosts
   ```

2. **Configure rsyslog:**
   ```bash
   ansible-playbook playbooks/stig_harden_internal_vm.yml \
       -e syslog_tls_target_host=syslog.example.com
   ```

3. **Verify:**
   ```bash
   # Check TLS connectivity
   openssl s_client -connect syslog.example.com:6514 \
       -CAfile /etc/pki/tls/certs/syslog-ca.crt
   
   # Send test message
   logger -t test "TLS syslog test message"
   ```

## Host Identity

### airgap_host_id Variable

Each managed host is identified by the `airgap_host_id` inventory variable:

```yaml
# ansible/inventories/hosts.yml
rhel9_hosts:
  hosts:
    webserver1:
      ansible_host: 10.0.1.10
      airgap_host_id: webserver1-prod
    dbserver1:
      ansible_host: 10.0.1.20
      airgap_host_id: dbserver1-prod
```

**Fallback:** If `airgap_host_id` is not set, the system falls back to `/etc/machine-id`.

### Per-Host Repository Paths

Host-specific content is stored at:
```
/repos/<env>/hosts/<airgap_host_id>/<profile>/...
```

## Monthly Patching

### Process

1. **Pre-check:**
   ```bash
   ansible-playbook playbooks/patch_monthly_security.yml --check
   ```

2. **Apply patches:**
   ```bash
   ansible-playbook playbooks/patch_monthly_security.yml
   ```

3. **Verify:**
   - Check `/var/log/patching/report-*.txt` on each host
   - Review reboot status

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `security_only` | true | Only apply security updates |
| `reboot_required` | true | Reboot if needed |
| `reboot_timeout` | 300 | Reboot wait timeout (seconds) |
| `patch_serial` | 20% | Hosts patched in parallel |

## STIG Hardening

### Available Roles

| Role | Purpose |
|------|---------|
| `stig_base` | Core system hardening |
| `stig_audit` | Audit configuration |
| `stig_rsyslog_tls_forward` | TLS syslog forwarding |
| `stig_fips_validation` | FIPS mode validation |

### Running STIG Hardening

```bash
# Full STIG hardening
ansible-playbook playbooks/stig_harden_internal_vm.yml

# Just rsyslog TLS
ansible-playbook playbooks/stig_harden_internal_vm.yml --tags rsyslog

# With custom syslog target
ansible-playbook playbooks/stig_harden_internal_vm.yml \
    -e syslog_tls_target_host=10.0.0.50 \
    -e syslog_tls_target_port=6514
```

### Evidence Collection

STIG hardening automatically collects evidence to `/var/log/stig-evidence/`:
- `hardening-timestamp.txt`
- `audit-sample.txt`
- `rsyslog-config.txt`
- `fips-status.txt`

## Troubleshooting

### Container Issues

```bash
# Check container status
podman ps -a

# View container logs
podman logs rpm-publisher

# Enter container
podman exec -it rpm-publisher /bin/bash
```

### HTTPS Issues

```bash
# Check certificate
openssl s_client -connect localhost:8443 -showcerts

# Verify certificate dates
openssl x509 -in /data/certs/server.crt -noout -dates
```

### Syslog TLS Issues

```bash
# Test connectivity
openssl s_client -connect syslog-server:6514

# Check rsyslog status
systemctl status rsyslog
journalctl -u rsyslog

# Verify CA certificate
openssl verify -CAfile /etc/pki/tls/certs/syslog-ca.crt /etc/pki/tls/certs/syslog-ca.crt
```

### Ansible Issues

```bash
# Test connectivity
ansible -m ping managed_hosts

# Verbose playbook run
ansible-playbook playbooks/site.yml -vvv

# Check inventory
ansible-inventory --list
```

## Make Targets Reference

| Target | Description |
|--------|-------------|
| `internal-build` | Build internal container images |
| `internal-build-test` | Build test containers |
| `internal-up` | Start all internal containers |
| `internal-down` | Stop and remove containers |
| `internal-validate` | Validate architecture |
| `internal-logs` | View container logs |
| `internal-e2e` | Run E2E tests |
| `ansible-shell` | Open Ansible container shell |
| `ansible-bootstrap` | Bootstrap SSH keys |
| `ansible-configure-repo` | Configure repo clients |
| `ansible-collect-manifests` | Collect manifests |
| `ansible-stig` | Run STIG hardening |
