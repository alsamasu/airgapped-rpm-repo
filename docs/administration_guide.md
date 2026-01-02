# Administration Guide - Satellite + Capsule Operations

## Overview

This guide covers day-to-day operations and maintenance of the Red Hat Satellite + Capsule infrastructure. It assumes:

- External Satellite server (RHEL 9.6) deployed with internet connectivity
- Internal Capsule server (RHEL 9.6) deployed in airgapped environment
- Managed hosts configured to use the internal Capsule for updates
- Content Views with security-only errata filters

---

## Monthly Patch Cycle Runbook

The monthly security patching workflow follows this sequence:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  MONTHLY PATCH CYCLE                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. SYNC        Satellite syncs from Red Hat CDN                           │
│       ↓                                                                     │
│  2. PUBLISH     Publish new Content View versions                          │
│       ↓                                                                     │
│  3. PROMOTE     Promote to test → prod lifecycle environments              │
│       ↓                                                                     │
│  4. EXPORT      Export content bundle for hand-carry                       │
│       ↓                                                                     │
│  5. TRANSFER    Hand-carry bundle to airgapped environment                 │
│       ↓                                                                     │
│  6. IMPORT      Import bundle on Capsule                                   │
│       ↓                                                                     │
│  7. PATCH       Run Ansible patching playbook                              │
│       ↓                                                                     │
│  8. VERIFY      Collect evidence (uname -r, os-release, updateinfo)        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Windows 11 Laptop Operations

All administrative operations can be performed from a Windows 11 laptop using PowerShell and SSH.

### Prerequisites

- PowerShell 7+ installed
- SSH client (built into Windows 11)
- Server IP addresses from initial deployment

**NOT REQUIRED:** Git, Python, WSL, Windows ADK, powershell-yaml, GNU Make

---

## Step 1: Sync Content (External Satellite)

Sync the latest security updates from Red Hat CDN:

```powershell
# SSH to Satellite server
ssh admin@<satellite-ip>

# Sync RHEL repositories
sudo hammer product synchronize \
  --organization "Default Organization" \
  --name "Red Hat Enterprise Linux for x86_64" \
  --async

# Monitor sync progress
hammer task list --search "label ~ sync and state = running"

# Wait for completion (or use --sync flag in configure script)
sudo /opt/satellite-setup/satellite-configure-content.sh --org "Default Organization" --sync
```

---

## Step 2: Publish Content Views

After sync completes, publish new Content View versions:

```powershell
ssh admin@<satellite-ip>

# Publish RHEL 8 Security Content View
hammer content-view publish \
  --organization "Default Organization" \
  --name "cv_rhel8_security" \
  --description "Monthly security update $(date +%Y-%m)"

# Publish RHEL 9 Security Content View
hammer content-view publish \
  --organization "Default Organization" \
  --name "cv_rhel9_security" \
  --description "Monthly security update $(date +%Y-%m)"

# List published versions
hammer content-view version list \
  --organization "Default Organization" \
  --content-view "cv_rhel8_security"
```

---

## Step 3: Promote to Lifecycle Environments

Promote the new versions through test and prod:

```powershell
ssh admin@<satellite-ip>

# Get latest version numbers
RHEL8_VERSION=$(hammer content-view version list \
  --organization "Default Organization" \
  --content-view "cv_rhel8_security" \
  --fields="Version" | tail -1 | awk '{print $1}')

RHEL9_VERSION=$(hammer content-view version list \
  --organization "Default Organization" \
  --content-view "cv_rhel9_security" \
  --fields="Version" | tail -1 | awk '{print $1}')

# Promote to test
hammer content-view version promote \
  --organization "Default Organization" \
  --content-view "cv_rhel8_security" \
  --version "$RHEL8_VERSION" \
  --to-lifecycle-environment "test"

hammer content-view version promote \
  --organization "Default Organization" \
  --content-view "cv_rhel9_security" \
  --version "$RHEL9_VERSION" \
  --to-lifecycle-environment "test"

# After testing, promote to prod
hammer content-view version promote \
  --organization "Default Organization" \
  --content-view "cv_rhel8_security" \
  --version "$RHEL8_VERSION" \
  --to-lifecycle-environment "prod"

hammer content-view version promote \
  --organization "Default Organization" \
  --content-view "cv_rhel9_security" \
  --version "$RHEL9_VERSION" \
  --to-lifecycle-environment "prod"
```

---

## Step 4: Export Content Bundle

Export the production Content Views for hand-carry transfer:

```powershell
ssh admin@<satellite-ip>

# Run export script
sudo /opt/satellite-setup/satellite-export-bundle.sh \
  --org "Default Organization" \
  --lifecycle-env prod \
  --output-dir /var/lib/pulp/exports

# List generated bundles
ls -lh /var/lib/pulp/exports/*.tar.gz

# Copy to removable media
# (From Windows laptop)
scp admin@<satellite-ip>:/var/lib/pulp/exports/airgap-security-bundle-*.tar.gz E:\transfer\
scp admin@<satellite-ip>:/var/lib/pulp/exports/airgap-security-bundle-*.tar.gz.sha256 E:\transfer\
```

---

## Step 5: Hand-Carry Transfer

Transport the bundle to the airgapped environment via approved removable media.

**Required files:**
- `airgap-security-bundle-YYYYMMDD-HHMMSS.tar.gz` - Content bundle
- `airgap-security-bundle-YYYYMMDD-HHMMSS.tar.gz.sha256` - Checksum file

---

## Step 6: Import on Capsule

Import the bundle into the internal Capsule server:

```powershell
# Copy bundle to Capsule
scp E:\transfer\airgap-security-bundle-*.tar.gz admin@<capsule-ip>:/var/lib/pulp/imports/
scp E:\transfer\airgap-security-bundle-*.tar.gz.sha256 admin@<capsule-ip>:/var/lib/pulp/imports/

# SSH to Capsule and import
ssh admin@<capsule-ip>

# Find the latest bundle
BUNDLE=$(ls -t /var/lib/pulp/imports/airgap-security-bundle-*.tar.gz | head -1)

# Import bundle
sudo /opt/capsule-setup/capsule-import-bundle.sh \
  --bundle "$BUNDLE" \
  --org "Default Organization"

# Verify import
dnf repolist
curl -k https://localhost/content/
```

---

## Step 7: Run Ansible Patching

Apply security updates to managed hosts:

```powershell
# SSH to management host (or Capsule)
ssh admin@<management-host>

# Run monthly security patching playbook
cd /srv/airgap/ansible
ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml

# For specific host groups
ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml --limit rhel9_hosts

# With custom reboot timeout
ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml -e reboot_timeout=600
```

The patching playbook performs:
1. Pre-patching health checks (disk space, system state)
2. Logs pre-patch package state
3. Applies security-only updates
4. Reboots if kernel was updated
5. Waits for SSH to return
6. Runs post-patching validation

---

## Step 8: Verify and Collect Evidence

Verify patching success and collect evidence:

```powershell
# Evidence is automatically collected by the playbook
# Review on management host:
ssh admin@<management-host>

# Check evidence files
ls -la ./artifacts/evidence/

# Each host has:
# - evidence-YYYY-MM-DD.txt     (comprehensive report)
# - delta-YYYY-MM-DD.txt        (package changes)
```

### Evidence Report Contents

Each host's evidence report includes:

```
================================================================================
Security Patching Evidence Report
================================================================================
Host: tester-rhel9
Host ID: abc123-def456
Date: 2024-01-15T10:30:00Z

KERNEL:
  Running: 5.14.0-362.18.1.el9_3.x86_64

OS RELEASE:
  NAME="Red Hat Enterprise Linux"
  VERSION="9.3 (Plow)"
  ...

PATCH STATUS:
  Start Time: 2024-01-15T10:00:00Z
  End Time: 2024-01-15T10:30:00Z
  Updates Applied: true
  Reboot Performed: true

REMAINING SECURITY ADVISORIES:
  None

VERIFICATION STATUS:
  PASS - No outstanding security advisories

================================================================================
```

---

## Key File Locations

### Satellite Server

| Path | Purpose |
|------|---------|
| `/var/lib/pulp/` | Pulp content storage |
| `/var/lib/pulp/exports/` | Export bundles |
| `/var/log/foreman-installer/` | Installation logs |
| `/var/log/satellite-setup/` | Setup script logs |

### Capsule Server

| Path | Purpose |
|------|---------|
| `/var/lib/pulp/imports/` | Import staging |
| `/var/lib/pulp/content/` | Served content |
| `/var/lib/pulp/verified/` | Verified archives |
| `/var/log/capsule-setup/` | Import logs |

### Managed Hosts

| Path | Purpose |
|------|---------|
| `/var/log/patching/` | Patching logs and evidence |
| `/etc/yum.repos.d/capsule-*.repo` | Repository configuration |
| `/etc/pki/tls/certs/capsule-ca.crt` | Capsule CA certificate |

---

## Routine Operations

### Check Service Status

```powershell
# Satellite services
ssh admin@<satellite-ip> "hammer ping"
ssh admin@<satellite-ip> "systemctl status foreman"

# Capsule services
ssh admin@<capsule-ip> "systemctl status httpd"
ssh admin@<capsule-ip> "systemctl status pulpcore-api"
```

### View Sync Status

```powershell
ssh admin@<satellite-ip> "hammer task list --search 'label ~ sync'"
```

### List Content View Versions

```powershell
ssh admin@<satellite-ip> "hammer content-view version list \
  --organization 'Default Organization' \
  --content-view 'cv_rhel8_security'"
```

### Check Available Security Updates

```powershell
# On managed host
ssh admin@<managed-host> "dnf updateinfo list security"
```

---

## Host Onboarding

Configure new hosts to use the internal Capsule:

```powershell
ssh admin@<management-host>

# Run onboarding playbook
cd /srv/airgap/ansible
ansible-playbook -i inventories/lab.yml playbooks/configure_capsule_repos.yml --limit new_host

# Verify configuration
ssh admin@<new-host> "dnf repolist"
ssh admin@<new-host> "dnf check-update"
```

---

## TLS Certificate Management

### Check Certificate Expiration

```powershell
# Capsule server certificate
ssh admin@<capsule-ip> "openssl x509 -in /etc/pki/tls/certs/localhost.crt -noout -dates"

# Satellite certificate
ssh admin@<satellite-ip> "openssl x509 -in /etc/pki/katello/certs/katello-apache.crt -noout -dates"
```

### Replace TLS Certificate

```powershell
# Run certificate replacement playbook
ssh admin@<management-host> "cd /srv/airgap/ansible && \
  ansible-playbook -i inventories/lab.yml playbooks/replace_repo_tls_cert.yml \
  -e 'cert_path=/tmp/new-server.crt key_path=/tmp/new-server.key'"
```

---

## Backup and Recovery

### Backup Satellite

```powershell
ssh admin@<satellite-ip>

# Full backup (includes database, config, and content)
sudo satellite-maintain backup offline /var/backup/satellite-$(date +%Y%m%d)

# Online backup (content only)
sudo satellite-maintain backup online /var/backup/satellite-$(date +%Y%m%d)
```

### Backup Capsule Content

```powershell
ssh admin@<capsule-ip>

# Backup content directory
sudo tar -czf /var/backup/capsule-content-$(date +%Y%m%d).tar.gz -C /var/lib/pulp content/
```

### Restore from Backup

```powershell
# Satellite restore
ssh admin@<satellite-ip> "sudo satellite-maintain restore /var/backup/satellite-YYYYMMDD"

# Capsule restore
ssh admin@<capsule-ip> "sudo tar -xzf /var/backup/capsule-content-YYYYMMDD.tar.gz -C /var/lib/pulp"
```

---

## Troubleshooting

### Sync Fails

```powershell
ssh admin@<satellite-ip>

# Check task status
hammer task list --search "label ~ sync and result = error"

# View task details
hammer task info --id <task-id>

# Check Pulp logs
sudo tail -100 /var/log/messages | grep pulp
```

### Import Fails

```powershell
ssh admin@<capsule-ip>

# Verify bundle checksum
cd /var/lib/pulp/imports
sha256sum -c *.sha256

# Check import logs
sudo tail -100 /var/log/capsule-setup/import*.log

# Check disk space
df -h /var/lib/pulp
```

### Host Cannot Access Content

```powershell
# On managed host
# Check DNS resolution
nslookup capsule-internal

# Check connectivity
curl -vk https://capsule-internal:443/

# Verify CA certificate
openssl s_client -connect capsule-internal:443 -CAfile /etc/pki/tls/certs/capsule-ca.crt

# Check repo configuration
cat /etc/yum.repos.d/capsule-*.repo
```

### Patching Playbook Fails

```powershell
# Run with verbose output
ssh admin@<management-host> "cd /srv/airgap/ansible && \
  ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml -vvv"

# Check host connectivity
ansible -i inventories/lab.yml all -m ping

# Check available updates
ssh admin@<managed-host> "dnf check-update --security"
```

---

## Decommissioning

### Remove Managed Host

```powershell
# Collect final evidence
ssh admin@<management-host> "cd /srv/airgap/ansible && \
  ansible-playbook -i inventories/lab.yml playbooks/collect_manifests.yml --limit <host>"

# Remove from inventory
# Edit inventories/lab.yml and remove host entry

# Optionally restore original repo configuration on host
ssh admin@<host> "sudo rm /etc/yum.repos.d/capsule-*.repo"
```

### Decommission Infrastructure

```powershell
# Backup everything first
ssh admin@<satellite-ip> "sudo satellite-maintain backup offline /var/backup/final-$(date +%Y%m%d)"
ssh admin@<capsule-ip> "sudo tar -czf /var/backup/capsule-final.tar.gz -C /var/lib/pulp ."

# Destroy VMs
.\scripts\operator.ps1 destroy-servers -Force
```

---

## Appendix: hammer CLI Reference

| Command | Purpose |
|---------|---------|
| `hammer ping` | Check Satellite health |
| `hammer product synchronize` | Sync repository content |
| `hammer content-view publish` | Publish new CV version |
| `hammer content-view version promote` | Promote CV to lifecycle |
| `hammer content-export complete version` | Export CV for transfer |
| `hammer content-import library` | Import content bundle |
| `hammer repository list` | List repositories |
| `hammer task list` | List running tasks |
| `hammer lifecycle-environment list` | List lifecycle environments |

---

## Appendix: Ansible Playbook Reference

| Playbook | Purpose |
|----------|---------|
| `configure_capsule_repos.yml` | Configure hosts to use Capsule |
| `patch_monthly_security.yml` | Apply security updates with reboot |
| `collect_manifests.yml` | Collect host inventory data |
| `onboard_hosts.yml` | Full host onboarding |
| `replace_repo_tls_cert.yml` | Replace TLS certificates |
