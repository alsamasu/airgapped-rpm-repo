# Airgapped RPM Repository System - Automated Operator Guide

## Table of Contents

1. [Inputs Required](#1-inputs-required)
2. [Prerequisites](#2-prerequisites)
3. [vSphere Discovery (Optional)](#3-vsphere-discovery-optional)
4. [Happy Path Deployment (Kickstart)](#4-happy-path-deployment-kickstart)
5. [Alternative: OVA Deployment](#5-alternative-ova-deployment)
6. [E2E Testing](#6-e2e-testing)
7. [External RPM Server Operations](#7-external-rpm-server-operations)
8. [Internal RPM Server Operations](#8-internal-rpm-server-operations)
9. [Host Onboarding](#9-host-onboarding)
10. [Monthly Patch Cycle](#10-monthly-patch-cycle)
11. [Certificate Management](#11-certificate-management)
12. [Troubleshooting](#12-troubleshooting)
13. [Remaining Manual Steps](#13-remaining-manual-steps)

---

## 1. Inputs Required

All operator inputs are consolidated in **one configuration file**: `config/spec.yaml`

### Required Files

| File | Description | Source |
|------|-------------|--------|
| `config/spec.yaml` | All deployment configuration | Fill in template |
| RHEL 9.6 ISO | Installation media | Red Hat Customer Portal |
| Syslog CA bundle | CA certificate for syslog server | Your PKI |

### spec.yaml Configuration Sections

```yaml
# vCenter/ESXi connection
vcenter:
  server: "vcenter.example.local"
  datacenter: "Datacenter"
  cluster: "Cluster01"
  datastore: "datastore1"

# ISO paths
isos:
  rhel96_iso_path: "/path/to/rhel-9.6-x86_64-dvd.iso"

# VM names
vm_names:
  rpm_external: "rpm-external"
  rpm_internal: "rpm-internal"

# Credentials (change after deployment!)
credentials:
  initial_root_password: "ChangeMe123!"
  initial_admin_user: "admin"
  initial_admin_password: "ChangeMe123!"

# Syslog TLS (server-auth only)
syslog_tls:
  target_host: "syslog.example.local"
  target_port: 6514
  ca_bundle_local_path: "/path/to/syslog-ca.crt"

# Hosts to onboard
ansible:
  ssh_username: "admin"
  ssh_password: "ChangeMe123!"
  host_inventory:
    rhel9_hosts:
      - hostname_or_ip: "192.168.1.50"
        airgap_host_id: "app-server-01"
    rhel8_hosts:
      - hostname_or_ip: "192.168.1.60"
        airgap_host_id: "legacy-app-01"
```

---

## 2. Prerequisites

### Operator Workstation

| Requirement | Version | Installation |
|-------------|---------|--------------|
| PowerShell | 7.0+ | `winget install Microsoft.PowerShell` |
| VMware PowerCLI | 13.0+ | `Install-Module VMware.PowerCLI` |
| powershell-yaml | Latest | `Install-Module powershell-yaml` |
| Python 3 | 3.8+ | System package or pyenv |
| PyYAML | Latest | `pip3 install pyyaml` |
| Ansible | 2.14+ | `pip3 install ansible` |
| genisoimage (Linux) | Latest | `dnf install genisoimage` |
| oscdimg (Windows) | ADK | Windows ADK installation |

### VMware Environment

- vCenter Server or ESXi 7.0+
- Datastore with 500GB+ free space
- Port group named "LAN" with DHCP enabled
- RHEL 9.6 ISO uploaded to datastore (or local path for upload)

### Credentials

- vCenter/ESXi credentials (or set `VMWARE_USER`, `VMWARE_PASSWORD` env vars)
- Red Hat subscription credentials (for external server registration)

---

## 3. vSphere Discovery (Optional)

Before filling in spec.yaml manually, you can auto-discover your vSphere environment:

### Step 1: Run Discovery

```bash
make vsphere-discover
```

**Expected Output:**
```
===============================================================================
  VSPHERE ENVIRONMENT DISCOVERY
===============================================================================

Connecting to vCenter...
Discovering datacenters...
  Found: Datacenter1
Discovering clusters...
  Found: Cluster01 (2 hosts)
Discovering datastores...
  Found: datastore1 (500GB free)
  Found: datastore2 (200GB free)
  Selected: datastore1 (largest free space)
Validating LAN port group...
  [OK] LAN port group found

===============================================================================
  DISCOVERY COMPLETE
===============================================================================

  JSON output:  automation/artifacts/vsphere-defaults.json
  Spec template: automation/artifacts/spec.detected.yaml
```

### Step 2: Initialize spec.yaml

```bash
make spec-init
```

This copies the detected configuration to `config/spec.yaml`. Review and customize before proceeding.

### Discovery Output Files

| File | Description |
|------|-------------|
| `automation/artifacts/vsphere-defaults.json` | Raw JSON discovery data |
| `automation/artifacts/spec.detected.yaml` | Pre-filled spec.yaml template |

---

## 4. Happy Path Deployment (Kickstart)

This method uses kickstart ISOs for fully automated OS installation.

### Step 1: Fill spec.yaml

```bash
# Copy and edit configuration
cp config/spec.yaml.example config/spec.yaml
vim config/spec.yaml
```

Fill in all required fields for your environment.

### Step 2: Validate Configuration

```bash
make validate-spec
```

**Expected Output:**
```
==========================================
  Validating spec.yaml
==========================================

--- vCenter Configuration ---
  [OK] .vcenter.server
  [OK] .vcenter.datastore
  ...

==========================================
  Validation Summary
==========================================

Validation PASSED
```

### Step 3: Generate Ansible Inventory

```bash
make render-inventory
```

**Expected Output:**
```
Generating Ansible inventory from spec.yaml...
Inventory written to: ansible/inventories/generated.yml
```

### Step 4: Generate Kickstart ISOs

```bash
make generate-ks-iso
```

**Expected Output:**
```
Loading configuration...
Processing external VM...
  Generating kickstart file...
  Created: output/ks-isos/staging/external/ks.cfg
  Creating ISO for external...
  Created: output/ks-isos/ks-external.iso

Processing internal VM...
  ...
  Created: output/ks-isos/ks-internal.iso

============================================================
Kickstart ISOs generated successfully!
```

### Step 5: Upload ISOs to VMware Datastore

```bash
make upload-isos
```

**Expected Output:**
```
Uploading ISOs to VMware datastore...
  Uploading ks-external.iso...
  [OK] Uploaded ks-external.iso
  Uploading ks-internal.iso...
  [OK] Uploaded ks-internal.iso
```

### Step 6: Deploy VMs

```bash
make servers-deploy
```

**Expected Output:**
```
===============================================================================
  AIRGAPPED RPM REPOSITORY - AUTOMATED SERVER DEPLOYMENT
===============================================================================

  Configuration Summary:
  ----------------------
  vCenter Server:   vcenter.example.local
  External VM:      rpm-external
  Internal VM:      rpm-internal

Proceed with deployment? (yes/no): yes

=== Step 1: Generating Kickstart ISOs ===
...

=== Step 5: Creating Virtual Machines ===
  Creating rpm-external...
    Mounting RHEL ISO...
    Mounting Kickstart ISO...
  [OK] Created rpm-external

  Creating rpm-internal...
  [OK] Created rpm-internal

=== Step 6: Starting VMs ===
  [OK] Started rpm-external
  [OK] Started rpm-internal

===============================================================================
  DEPLOYMENT COMPLETE
===============================================================================
```

### Step 7: Wait for Installation

```bash
make servers-wait
```

**Expected Output:**
```
Monitoring VMs: rpm-external, rpm-internal
Timeout: 30 minutes

[rpm-external] Installing... (Tools: guestToolsNotRunning)
[rpm-internal] Installing... (Tools: guestToolsNotRunning)

Elapsed: 05:30 | Remaining: 24:30
Next check in 30 seconds...

[rpm-external] VMware Tools running
[rpm-external] Installation complete! IP: 192.168.1.100

[rpm-internal] VMware Tools running
[rpm-internal] Installation complete! IP: 192.168.1.101

===============================================================================
  ALL INSTALLATIONS COMPLETE
===============================================================================
```

### Step 8: Report DHCP IPs

```bash
make servers-report
```

**Expected Output:**
```
===============================================================================
  RPM SERVER IP ADDRESSES
===============================================================================

  rpm-external
    Type:       external
    Power:      PoweredOn
    IP Address: 192.168.1.100

  rpm-internal
    Type:       internal
    Power:      PoweredOn
    IP Address: 192.168.1.101

===============================================================================
  SSH Access Commands
===============================================================================

  ssh admin@192.168.1.100  # rpm-external
  ssh admin@192.168.1.101  # rpm-internal
```

### Step 9: Update Inventory with IPs

Edit `ansible/inventories/generated.yml` to replace placeholder IPs:

```yaml
external_servers:
  hosts:
    rpm-external:
      ansible_host: 192.168.1.100  # Update this

internal_servers:
  hosts:
    rpm-internal:
      ansible_host: 192.168.1.101  # Update this
```

### Step 10: Verify Internal Server Bootstrap

```bash
ssh admin@192.168.1.101

# On internal server:
systemctl --user status rpm-publisher
# Expected: Active (if container is built and running)

ls -la /srv/airgap/
# Expected: data/ certs/ ansible/ directories

cat /etc/airgap-role
# Expected: internal-rpm-server
```

### Step 11: Configure Syslog TLS (if configured in spec.yaml)

```bash
make compliance
```

This runs STIG hardening including syslog TLS forwarding to the target specified in spec.yaml.

**Expected Output:**
```
PLAY [STIG Hardening for Internal VM] ******************************************

TASK [stig_rsyslog_tls_forward : Deploy rsyslog TLS forwarding configuration] *
changed: [rpm-internal]

TASK [stig_rsyslog_tls_forward : Test syslog TLS connectivity] *****************
ok: [rpm-internal]
```

### Step 12: Onboard Managed Hosts

```bash
make ansible-onboard
```

You will be prompted for the SSH password (from spec.yaml).

**Expected Output:**
```
Onboarding managed hosts...
Step 1: Bootstrapping SSH keys (password auth)...
SSH password: ********

PLAY [Bootstrap SSH keys to managed hosts] *************************************
...
ok: [192.168.1.50]
ok: [192.168.1.60]

Step 2: Configuring repository access...

PLAY [Host Onboarding - Airgapped RPM Infrastructure] **************************
...
TASK [host_onboarding : Deploy internal repository configuration] **************
changed: [192.168.1.50]
changed: [192.168.1.60]

Onboarding complete!
```

### Step 13: Collect Manifests

```bash
make manifests
```

**Expected Output:**
```
Collecting package manifests...

PLAY [Collect package manifests from hosts] ************************************
...

Manifests saved to: ansible/artifacts/manifests/
Copy this directory to removable media for hand-carry to external server.
```

---

## 5. Alternative: OVA Deployment

Pre-built OVAs provide a faster deployment option with first-boot customization.

### When to Use OVAs

- Deploying to multiple environments with same base configuration
- Faster deployment without waiting for OS installation
- Environments without access to RHEL ISO

### OVA First-Boot Customization

OVAs support customization via OVF properties at deployment time:

| Property | Description | Example |
|----------|-------------|---------|
| `hostname` | VM hostname | `rpm-internal-prod` |
| `network.mode` | `dhcp` or `static` | `static` |
| `network.ip` | Static IP address | `192.168.1.100` |
| `network.prefix` | Network prefix length | `24` |
| `network.gateway` | Default gateway | `192.168.1.1` |
| `network.dns` | DNS servers | `192.168.1.10,192.168.1.11` |

### Deploy OVA via vSphere Client

1. **Import OVA**:
   - Right-click datacenter → Deploy OVF Template
   - Select `rpm-external.ova` or `rpm-internal.ova`

2. **Configure Properties**:
   - Set hostname
   - Choose network mode (DHCP or Static)
   - If static, provide IP, gateway, DNS

3. **Power On**:
   - First-boot script configures networking automatically
   - Check `/var/log/airgap-firstboot.log` for status

### Deploy OVA via PowerCLI

```powershell
# Import OVA with customization
Import-VApp -Source "rpm-internal.ova" `
    -Name "rpm-internal-prod" `
    -VMHost $vmhost `
    -Datastore $datastore `
    -OvfConfiguration @{
        "hostname" = "rpm-internal-prod"
        "network.mode" = "static"
        "network.ip" = "192.168.1.101"
        "network.prefix" = "24"
        "network.gateway" = "192.168.1.1"
        "network.dns" = "192.168.1.10"
    }

# Power on
Start-VM -VM "rpm-internal-prod"
```

### Building OVAs

After successful E2E tests, build OVAs from running VMs:

```bash
make build-ovas
```

**Expected Output:**
```
Building OVAs from running VMs...

Shutting down rpm-external for export...
Exporting rpm-external to OVA...
  [OK] Created: automation/artifacts/ovas/rpm-external.ova
  SHA256: a1b2c3d4...

Shutting down rpm-internal for export...
Exporting rpm-internal to OVA...
  [OK] Created: automation/artifacts/ovas/rpm-internal.ova
  SHA256: e5f6g7h8...

Creating manifest...
  [OK] automation/artifacts/ovas/manifest.json

OVA build complete!
```

### OVA Artifacts

| File | Description |
|------|-------------|
| `automation/artifacts/ovas/rpm-external.ova` | External server OVA |
| `automation/artifacts/ovas/rpm-internal.ova` | Internal server OVA |
| `automation/artifacts/ovas/*.sha256` | Checksum files |
| `automation/artifacts/ovas/manifest.json` | Build metadata |

---

## 6. E2E Testing

Run the full end-to-end test suite to validate deployment.

### Run E2E Tests

```bash
make e2e
```

**Expected Output:**
```
===============================================================================
  E2E TEST HARNESS - Airgapped RPM Repository
===============================================================================

[PASS] Spec file exists
[PASS] Spec validation
[PASS] VM deployment initiated
[PASS] Installation completed
[PASS] IP retrieval
[PASS] External: IP available (192.168.1.100)
[PASS] External: SSH accessible
[PASS] External: OS version 9.6
[PASS] External: subscription-manager installed
[PASS] External: Data directories exist
[PASS] External: Role marker correct
[PASS] Internal: IP available (192.168.1.101)
[PASS] Internal: SSH accessible
[PASS] Internal: FIPS enabled
[PASS] Internal: rpmops user exists
[PASS] Internal: Rootless podman works
[PASS] Internal: Systemd user services exist
[PASS] Internal: HTTPS endpoint responds
[PASS] Internal: TLS certificate exists
[PASS] Internal: Repo directories exist
[PASS] Internal: Role marker correct

===============================================================================
  TEST SUMMARY
===============================================================================

  Passed:  20
  Failed:  0
  Skipped: 0

  Reports: automation/artifacts/e2e/report.md
           automation/artifacts/e2e/report.json

E2E TESTS PASSED
```

### E2E Test Options

```bash
# Skip deployment (test existing VMs)
./automation/scripts/run-e2e-tests.sh --skip-deploy

# Cleanup VMs after tests
./automation/scripts/run-e2e-tests.sh --cleanup
```

### Validate Operator Guide

Ensure all documentation references are valid:

```bash
make guide-validate
```

**Expected Output:**
```
==============================================
Operator Guide Validation
==============================================
Guide: docs/operator_guide_automated.md
Spec:  config/spec.yaml

[INFO] Checking Makefile targets...
[INFO] Checking referenced files...
[INFO] Checking script permissions...
[INFO] Checking PowerShell scripts...
[INFO] Validating spec.yaml structure...
[PASS] spec.yaml is valid YAML
[INFO] Checking directory structure...
[INFO] Checking E2E artifacts structure...

==============================================
Validation Summary
==============================================
Errors:   0
Warnings: 0

Guide validation PASSED
```

### E2E Test Artifacts

| File | Description |
|------|-------------|
| `automation/artifacts/e2e/report.md` | Human-readable test report |
| `automation/artifacts/e2e/report.json` | Machine-readable results |
| `automation/artifacts/e2e/servers.json` | Server IP information |
| `automation/artifacts/e2e/e2e.log` | Full test log |

---

## 7. External RPM Server Operations

These operations are performed **on the external RPM server** (internet-connected).

### Register with Red Hat

```bash
ssh admin@<external-ip>
cd /path/to/airgapped-rpm-repo
make sm-register
```

Enter Red Hat credentials when prompted.

### Enable Repositories

```bash
make enable-repos
```

### Sync Packages

```bash
make sync
```

This may take several hours on first run.

### Build Repository Metadata

```bash
make build-repos
```

### Create Export Bundle

```bash
make export BUNDLE_NAME=patch-$(date +%Y%m)
```

**Expected Output:**
```
Creating export bundle: patch-202501
...
Bundle created: /data/export/patch-202501.tar.gz
Checksum:       /data/export/patch-202501.tar.gz.sha256
Signature:      /data/export/patch-202501.tar.gz.sig
BOM:            /data/export/patch-202501.bom.json
```

### Transfer Bundle to Internal Server

Copy bundle files to removable media:
```bash
cp /data/export/patch-202501.* /mnt/usb/
```

Physically transfer media across airgap.

---

## 8. Internal RPM Server Operations

These operations are performed **on the internal RPM server** (airgapped).

### Import Bundle

```bash
ssh admin@<internal-ip>
cd /path/to/airgapped-rpm-repo

# Copy from removable media
cp /mnt/usb/patch-202501.* /srv/airgap/data/import/

# Import
make import BUNDLE_PATH=/srv/airgap/data/import/patch-202501.tar.gz
```

**Expected Output:**
```
Importing bundle: /srv/airgap/data/import/patch-202501.tar.gz
Verifying checksum... OK
Verifying GPG signature... OK
Extracting to testing environment...
Building repository metadata...
Import complete!
```

### Verify Import

```bash
make verify
```

### Test from Managed Host

```bash
# From a managed host configured for testing lifecycle
ssh admin@<managed-host>
sudo dnf clean all
sudo dnf check-update
```

### Promote to Stable

```bash
make promote FROM=testing TO=stable
```

**Expected Output:**
```
Promoting from testing to stable...
Syncing rhel8 packages...
Syncing rhel9 packages...
Rebuilding metadata...
Promotion complete!
```

---

## 9. Host Onboarding

### Onboard New Hosts

1. Add hosts to `config/spec.yaml`:
   ```yaml
   ansible:
     host_inventory:
       rhel9_hosts:
         - hostname_or_ip: "192.168.1.70"
           airgap_host_id: "new-server-01"
   ```

2. Regenerate inventory:
   ```bash
   make render-inventory
   ```

3. Run onboarding:
   ```bash
   make ansible-onboard
   ```

### Verify Host Configuration

```bash
# On managed host
sudo dnf repolist
# Expected: Only airgap-* repositories

cat /etc/airgap/host-identity
# Expected: new-server-01

sudo dnf install -y tree
# Expected: Installs from internal repository
```

---

## 10. Monthly Patch Cycle

### Complete Workflow

1. **External Server**: Sync and export
   ```bash
   make sync
   make build-repos
   make export BUNDLE_NAME=patch-$(date +%Y%m)
   ```

2. **Physical Transfer**: Copy bundle to removable media

3. **Internal Server**: Import and promote
   ```bash
   make import BUNDLE_PATH=/path/to/bundle.tar.gz
   # Test on staging hosts
   make promote FROM=testing TO=stable
   ```

4. **Managed Hosts**: Apply patches
   ```bash
   make patch
   ```

### Patch Verification

```bash
# Check all hosts are reachable after patching
ansible -i ansible/inventories/generated.yml all -m ping

# Check kernel versions
ansible -i ansible/inventories/generated.yml managed_hosts -m shell -a "uname -r"

# Collect updated manifests
make manifests
```

---

## 11. Certificate Management

### Replace Self-Signed Certificate

After obtaining a CA-signed certificate:

```bash
make replace-tls-cert \
  CERT_PATH=/path/to/server.crt \
  KEY_PATH=/path/to/server.key \
  CA_CHAIN=/path/to/ca-chain.crt
```

**Expected Output:**
```
Replacing TLS certificate...

TASK [Deploy new certificate] **************************************************
changed: [rpm-internal]

TASK [Restart rpm-publisher] ***************************************************
changed: [rpm-internal]

============================================================
TLS CERTIFICATE REPLACED SUCCESSFULLY
============================================================
```

### Distribute New CA to Hosts

```bash
cd ansible
ansible-playbook -i inventories/generated.yml playbooks/onboard_hosts.yml --tags repository
```

---

## 12. Troubleshooting

### VM Deployment Issues

**Problem**: PowerCLI cannot connect to vCenter
```
[FAIL] Connection failed: Could not connect to vCenter
```

**Solution**:
```bash
# Verify credentials
export VMWARE_USER="administrator@vsphere.local"
export VMWARE_PASSWORD="your-password"

# Test connection
pwsh -Command "Connect-VIServer -Server vcenter.example.local"
```

**Problem**: VM creation fails with "datastore not found"

**Solution**: Verify datastore name in spec.yaml matches exactly (case-sensitive).

### Kickstart Issues

**Problem**: Installation not starting automatically

**Solution**:
1. Verify kickstart ISO has `OEMDRV` volume label
2. Check both CD drives are connected
3. Verify RHEL ISO is mounted as primary CD

```bash
# Verify ISO label
isoinfo -d -i output/ks-isos/ks-external.iso | grep "Volume id"
# Expected: Volume id: OEMDRV
```

### Ansible Issues

**Problem**: SSH connection refused

**Solution**:
```bash
# Verify SSH is running on target
ssh admin@<ip>

# Check SSH password in spec.yaml matches
# Use --ask-pass for initial connection
ansible -i ansible/inventories/generated.yml all -m ping --ask-pass
```

**Problem**: Python interpreter not found (RHEL 8)

**Solution**: Verify inventory has correct interpreter:
```yaml
rhel8_hosts:
  vars:
    ansible_python_interpreter: /usr/bin/python3.11
```

### Repository Issues

**Problem**: Managed host cannot reach repository

**Solution**:
```bash
# Test connectivity
curl -k https://<internal-ip>:8443/

# Verify firewall
ssh admin@<internal-ip> sudo firewall-cmd --list-all
# Should include ports 8080 and 8443

# Check container is running
ssh admin@<internal-ip> systemctl --user status rpm-publisher
```

---

## 13. Remaining Manual Steps

### Required Manual Actions

| Action | Justification | Frequency |
|--------|---------------|-----------|
| Fill `config/spec.yaml` | Environment-specific configuration | Once |
| Download RHEL ISO | Red Hat licensing requires manual download | Once |
| Provide syslog CA cert | Organization PKI requirement | Once |
| Physical bundle transfer | Security requirement (airgap) | Monthly |
| Red Hat registration | Requires subscription credentials | Once |

### Why These Cannot Be Automated

1. **spec.yaml**: Contains environment-specific values that only the operator knows
2. **RHEL ISO**: Legal requirement to download from Red Hat with valid subscription
3. **Syslog CA**: Organization-specific PKI infrastructure
4. **Physical transfer**: The airgap is a security feature, not a limitation
5. **Red Hat registration**: Credentials should not be stored in configuration files

### Automation Coverage Summary

| Category | Automated | Manual |
|----------|-----------|--------|
| VM creation and configuration | 100% | 0% |
| OS installation | 100% | 0% |
| SSH and user setup | 100% | 0% |
| Repository server configuration | 100% | 0% |
| TLS certificate bootstrap | 100% | 0% |
| Host onboarding | 100% | 0% |
| Patching workflow | 100% | 0% |
| OVA building | 100% | 0% |
| E2E testing | 100% | 0% |

All deployment steps that can be automated have been automated. The remaining manual steps are either security requirements (airgap) or licensing requirements (Red Hat).

---

## Quick Reference

### Make Targets

```bash
# Discovery & Initialization
make vsphere-discover      # Discover vSphere environment
make spec-init             # Initialize spec.yaml from discovery

# Configuration
make validate-spec         # Validate spec.yaml
make render-inventory      # Generate Ansible inventory

# VMware Deployment
make servers-deploy        # Deploy VMs via kickstart
make servers-destroy       # Destroy VMs
make servers-report        # Report VM IPs
make servers-wait          # Wait for installation

# Testing & Validation
make e2e                   # Run E2E test suite
make guide-validate        # Validate operator guide

# OVA Building
make build-ovas            # Build OVAs from running VMs

# Ansible
make ansible-onboard       # Full onboarding
make ansible-bootstrap     # SSH keys only
make manifests             # Collect manifests
make patch                 # Monthly patching
make compliance            # STIG hardening

# External server
make sm-register           # Red Hat registration
make sync                  # Sync packages
make export BUNDLE_NAME=x  # Create bundle

# Internal server
make import BUNDLE_PATH=x  # Import bundle
make promote FROM=x TO=y   # Promote lifecycle
```

### Key Files

```
config/spec.yaml                              # All configuration
ansible/inventories/generated.yml             # Generated inventory
automation/powercli/deploy-rpm-servers.ps1    # VM deployment
automation/powercli/discover-vsphere-defaults.ps1  # vSphere discovery
automation/powercli/build-ovas.ps1            # OVA builder
automation/kickstart/rhel96_*.ks              # OS installation
automation/scripts/run-e2e-tests.sh           # E2E test harness
ansible/playbooks/onboard_hosts.yml           # Host onboarding
```

### Artifacts

```
automation/artifacts/vsphere-defaults.json    # vSphere discovery output
automation/artifacts/spec.detected.yaml       # Auto-generated spec template
automation/artifacts/e2e/report.md            # E2E test report
automation/artifacts/e2e/report.json          # E2E results (JSON)
automation/artifacts/ovas/*.ova               # Built OVAs
automation/artifacts/ovas/*.sha256            # OVA checksums
```

### Environment Variables

```bash
export VMWARE_USER="administrator@vsphere.local"
export VMWARE_PASSWORD="your-password"
```
