# Administration Guide

## Overview

This guide covers day-to-day operations and maintenance of the airgapped RPM repository infrastructure. It assumes:

- RHEL 9.6 internal server deployed per the Deployment Guide
- Rootless Podman running under the `rpmops` service user
- Repository served over HTTPS on port 8443
- Managed hosts onboarded and consuming packages from the internal repository

---

## Windows 11 Laptop Operations

All administrative operations can be performed from a Windows 11 laptop using PowerShell and SSH.

### Prerequisites

Ensure you have:
- PowerShell 7+ installed
- SSH client (built into Windows 11)
- Server IP addresses from initial deployment

### Quick Reference

```powershell
# Validate current configuration
.\scripts\operator.ps1 validate-spec

# Get server status and IPs
.\scripts\operator.ps1 report-servers

# Validate operator guides
.\scripts\operator.ps1 guide-validate

# Run E2E tests
.\scripts\operator.ps1 e2e
```

---

## System Components

### Key File Locations

| Path | Server | Purpose |
|------|--------|---------|
| `/srv/airgap/data/` | Internal | Repository content root |
| `/srv/airgap/certs/` | Internal | TLS certificates |
| `/srv/airgap/data/import/` | Internal | Bundle import staging |
| `/data/export/` | External | Bundle export staging |
| `/data/repos/` | External | Synced repository mirror |

---

## Routine Operations

### Check Service Status

```powershell
# From Windows laptop
ssh admin@<internal-ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"
```

### Restart Repository Service

```powershell
ssh admin@<internal-ip> "systemctl --user -M rpmops@ restart airgap-rpm-publisher.service"
```

### View Service Logs

```powershell
ssh admin@<internal-ip> "journalctl --user -M rpmops@ -u airgap-rpm-publisher.service -n 50"
```

---

## Host Onboarding

### Run Onboarding Playbook

SSH to a management host (or the internal server) with Ansible installed:

```powershell
ssh admin@<management-host> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/onboard_hosts.yml"
```

> **Note:** Per guardrails, WSL is NOT REQUIRED on the Windows 11 operator laptop. Use SSH to run Ansible commands on the internal server or a dedicated management host.

### Onboarding Tags

| Tag | Purpose |
|-----|---------|
| preflight | Pre-flight checks |
| identity | Configure host identity |
| repository | Configure DNF repositories |
| syslog | Configure syslog TLS forwarding |
| manifest | Collect host manifest |
| verify | Validate onboarding success |

---

## Manifest Collection

```powershell
ssh admin@<internal-ip> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/collect_manifests.yml"
```

---

## RPM Lifecycle Management

### Lifecycle Environments

| Environment | Path | Purpose |
|-------------|------|---------|
| testing | `/srv/airgap/data/lifecycle/testing/` | Newly imported packages |
| stable | `/srv/airgap/data/lifecycle/stable/` | Production-ready packages |

### Sync Repositories (External Server)

```powershell
ssh admin@<external-ip> "sudo /opt/airgap-rpm/scripts/external/sync_repos.sh"
```

### Export Bundle for Hand-Carry

```powershell
ssh admin@<external-ip> "sudo /opt/airgap-rpm/scripts/external/export_bundle.sh"
```

### Import Bundle (Internal Server)

```powershell
# Copy bundle to internal server
scp /path/to/bundle-YYYYMMDD.tar.gz admin@<internal-ip>:/srv/airgap/data/import/

# Import the bundle
ssh admin@<internal-ip> "sudo /opt/airgap-rpm/scripts/internal/import_bundle.sh /srv/airgap/data/import/bundle-YYYYMMDD.tar.gz"
```

### Promote from Testing to Stable

```powershell
ssh admin@<internal-ip> "sudo /opt/airgap-rpm/scripts/internal/promote_lifecycle.sh testing stable"
```

---

## Monthly Patch Cycle

```powershell
# Run from management host via SSH
ssh admin@<management-host> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/patch_hosts.yml"
```

---

## TLS and Certificates

### Check Certificate Expiration

```powershell
ssh admin@<internal-ip> "openssl x509 -in /srv/airgap/certs/server.crt -noout -dates"
```

### Replace TLS Certificate

1. Copy new certificates to the server:

```powershell
scp new-server.crt admin@<internal-ip>:/tmp/
scp new-server.key admin@<internal-ip>:/tmp/
```

2. Run the replacement playbook:

```powershell
ssh admin@<management-host> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/replace_repo_tls_cert.yml -e 'cert_path=/tmp/new-server.crt key_path=/tmp/new-server.key'"
```

---

## Backup, Recovery, and Rollback

### Backup Repository Content

```powershell
ssh admin@<internal-ip> "sudo tar -czf /srv/airgap/backups/repo-$(date +%Y%m%d).tar.gz -C /srv/airgap data/"
```

### Restore from Backup

1. Stop service:
   ```powershell
   ssh admin@<internal-ip> "systemctl --user -M rpmops@ stop airgap-rpm-publisher.service"
   ```

2. Extract backup:
   ```powershell
   ssh admin@<internal-ip> "sudo tar -xzf /srv/airgap/backups/repo-YYYYMMDD.tar.gz -C /srv/airgap"
   ```

3. Fix ownership:
   ```powershell
   ssh admin@<internal-ip> "sudo chown -R rpmops:rpmops /srv/airgap/data/"
   ```

4. Start service:
   ```powershell
   ssh admin@<internal-ip> "systemctl --user -M rpmops@ start airgap-rpm-publisher.service"
   ```

---

## Server Management

### Destroy Servers

> **WARNING**: This permanently deletes all VMs and data.

```powershell
.\scripts\operator.ps1 destroy-servers
```

### Build OVA Appliances

Export running VMs as OVA templates:

```powershell
.\scripts\operator.ps1 build-ovas
```

---

## Decommissioning

### Remove Managed Host

1. Collect final manifest:
   ```powershell
   ssh admin@<internal-ip> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/collect_manifests.yml --limit <host>"
   ```

2. Remove from inventory file

3. Optionally restore original repo configuration on the host

### Decommission Server

1. Backup repository and certificates:
   ```powershell
   ssh admin@<internal-ip> "sudo tar -czf /srv/airgap/final-backup.tar.gz -C /srv/airgap data/ certs/"
   scp admin@<internal-ip>:/srv/airgap/final-backup.tar.gz ./
   ```

2. Destroy VMs:
   ```powershell
   .\scripts\operator.ps1 destroy-servers -Force
   ```

---

## Troubleshooting Reference

### Repository Service Won't Start

```powershell
# Check logs
ssh admin@<internal-ip> "journalctl --user -M rpmops@ -u airgap-rpm-publisher.service -n 100"

# Verify TLS certificate validity
ssh admin@<internal-ip> "openssl x509 -in /srv/airgap/certs/server.crt -noout -checkend 0"

# Check port conflicts
ssh admin@<internal-ip> "ss -tlnp | grep -E ':8080|:8443'"
```

### Managed Host Cannot Access Repository

```powershell
# Check firewall on internal server
ssh admin@<internal-ip> "sudo firewall-cmd --list-ports"

# Verify repository URL in client config
ssh admin@<managed-host> "cat /etc/yum.repos.d/airgap-*.repo"

# Test connectivity
ssh admin@<managed-host> "curl -vk https://<internal-ip>:8443/repo/stable/"
```

### Package Import Fails

```powershell
# Verify bundle structure
ssh admin@<internal-ip> "tar -tzf /srv/airgap/data/import/bundle.tar.gz | head -20"

# Check disk space
ssh admin@<internal-ip> "df -h /srv/airgap"

# Review import log
ssh admin@<internal-ip> "cat /var/log/airgap-import.log"
```

### Ansible Playbook Fails

```powershell
# Run with verbose output
ssh admin@<management-host> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/onboard_hosts.yml -vvv"

# Check SSH connectivity
ssh admin@<managed-host> "echo 'SSH OK'"

# Verify Python interpreter
ssh admin@<managed-host> "python3 --version"
```

### Validate System Configuration

```powershell
# Validate spec.yaml
.\scripts\operator.ps1 validate-spec

# Validate operator guides
.\scripts\operator.ps1 guide-validate

# Run full E2E tests
.\scripts\operator.ps1 e2e
```

---

## Appendix: Linux/macOS Administration

For administrators using Linux or macOS, all operations can be performed using:

1. **PowerShell Core**: Install and use the same `operator.ps1` commands
2. **Makefile targets**: Use `make` commands as an alternative
3. **Direct SSH**: All remote operations work identically

### Example: Using Makefile on Linux

```bash
# Validate configuration
make validate-spec

# Run E2E tests
make e2e

# Validate guides
make guide-validate
```
