# Deployment Guide

## Overview

This guide covers the deployment of the airgapped RPM repository infrastructure consisting of two RHEL 9.6 servers:

- **External Server** (`rpm-external`): Internet-connected system that syncs packages from Red Hat CDN and prepares bundles for hand-carry transfer
- **Internal Server** (`rpm-internal`): Airgapped system that hosts the internal RPM repository serving managed RHEL hosts

The deployment automation uses VMware PowerCLI scripts with kickstart injection for fully automated installation. Two deployment methods are available:

1. **Kickstart ISO Injection**: Direct deployment from RHEL 9.6 ISO with automated kickstart configuration
2. **OVA Deployment**: Pre-built appliance images with first-boot customization via OVF properties

---

## Windows 11 Laptop (Primary Workflow)

This is the **recommended workflow** for operators running from a Windows 11 laptop.

### Prerequisites

1. **PowerShell 7+** (download from [Microsoft](https://github.com/PowerShell/PowerShell/releases))
   ```powershell
   # Verify version
   $PSVersionTable.PSVersion
   ```

2. **VMware PowerCLI Module**
   ```powershell
   Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
   Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
   ```

3. **PowerShell YAML Module**
   ```powershell
   Install-Module -Name powershell-yaml -Scope CurrentUser -Force
   ```

4. **Windows ADK** (for ISO creation)
   - Download from [Microsoft Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
   - Install "Deployment Tools" component (includes `oscdimg.exe`)

5. **Python 3** (for inventory rendering)
   ```powershell
   winget install Python.Python.3.12
   pip install pyyaml
   ```

6. **Git for Windows** (optional, for bash script compatibility)
   - Download from [git-scm.com](https://git-scm.com/download/win)

### Set VMware Credentials

```powershell
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "YourSecurePassword"
```

### Quick Start: Full Deployment

```powershell
# 1. Initialize configuration from vSphere discovery
.\scripts\operator.ps1 init-spec

# 2. Edit spec.yaml with your environment values
notepad config\spec.yaml

# 3. Validate configuration
.\scripts\operator.ps1 validate-spec

# 4. Deploy servers (will prompt for confirmation)
.\scripts\operator.ps1 deploy-servers

# 5. Check deployment status and get IP addresses
.\scripts\operator.ps1 report-servers
```

### Operator CLI Reference

The `scripts\operator.ps1` script is the single canonical entrypoint for all operations:

| Command | Description |
|---------|-------------|
| `.\scripts\operator.ps1 init-spec` | Discover vSphere and initialize spec.yaml |
| `.\scripts\operator.ps1 validate-spec` | Validate spec.yaml configuration |
| `.\scripts\operator.ps1 deploy-servers` | Deploy External and Internal RPM servers |
| `.\scripts\operator.ps1 report-servers` | Report VM status and DHCP IPs |
| `.\scripts\operator.ps1 destroy-servers` | Destroy all deployed VMs |
| `.\scripts\operator.ps1 build-ovas` | Build OVAs from running VMs |
| `.\scripts\operator.ps1 guide-validate` | Validate operator guides |
| `.\scripts\operator.ps1 e2e` | Run full E2E test suite |

#### Common Options

```powershell
# Skip confirmation prompts
.\scripts\operator.ps1 deploy-servers -Force

# Custom spec path
.\scripts\operator.ps1 validate-spec -SpecPath C:\path\to\spec.yaml

# Keep VMs after E2E test
.\scripts\operator.ps1 e2e -KeepVMs

# Show what would be done without executing
.\scripts\operator.ps1 deploy-servers -WhatIf

# Get help
.\scripts\operator.ps1 -Help
```

---

## Detailed Deployment Steps

### Step 1: Initialize Configuration

Discover your vSphere environment and generate initial configuration:

```powershell
.\scripts\operator.ps1 init-spec
```

This will:
1. Connect to vCenter/ESXi
2. Discover datacenters, clusters, datastores, and networks
3. Generate `automation/artifacts/spec.detected.yaml`
4. Copy to `config/spec.yaml`

### Step 2: Customize Configuration

Edit `config/spec.yaml` with your environment-specific values:

```yaml
vcenter:
  server: "vcenter.example.local"
  datacenter: "Datacenter"
  cluster: "Cluster01"
  datastore: "datastore1"

network:
  portgroup_name: "LAN"
  dhcp: true

isos:
  rhel96_iso_path: "[datastore1] isos/rhel-9.6-x86_64-dvd.iso"

vm_names:
  rpm_external: "rpm-external"
  rpm_internal: "rpm-internal"

vm_sizing:
  external:
    cpu: 2
    memory_gb: 8
    disk_gb: 200
  internal:
    cpu: 2
    memory_gb: 8
    disk_gb: 200

credentials:
  initial_root_password: "ChangeMe123!"
  initial_admin_user: "admin"
  initial_admin_password: "ChangeMe123!"

compliance:
  enable_fips: true
```

### Step 3: Validate Configuration

```powershell
.\scripts\operator.ps1 validate-spec
```

Fix any reported errors before proceeding.

### Step 4: Deploy Servers

```powershell
.\scripts\operator.ps1 deploy-servers
```

The deployment will:
1. Generate kickstart ISOs
2. Upload ISOs to VMware datastore
3. Create VMs with correct sizing
4. Mount RHEL ISO and kickstart ISO
5. Power on VMs for automated installation

Installation typically takes 10-20 minutes per VM.

### Step 5: Verify Deployment

```powershell
# Get VM status and IP addresses
.\scripts\operator.ps1 report-servers

# Verify SSH connectivity
ssh admin@<internal-ip> "cat /etc/airgap-role"

# Check internal server services
ssh admin@<internal-ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"

# Test HTTPS endpoint
curl -k https://<internal-ip>:8443/
```

---

## Post-Deployment Validation

### Run E2E Tests

```powershell
.\scripts\operator.ps1 e2e
```

Reports are generated in `automation/artifacts/e2e/`.

### Build OVA Appliances

After successful E2E validation, export VMs as OVAs for future deployments:

```powershell
.\scripts\operator.ps1 build-ovas
```

OVAs are saved to `automation/artifacts/ovas/`.

---

## Initial System State

| Component | State |
|-----------|-------|
| Repository Service | Running under rpmops user |
| TLS Certificate | Self-signed (replace for production) |
| Repository Content | Empty (import first bundle) |
| FIPS Mode | Enabled on internal server |

---

## Appendix A: Linux/macOS Operators

For operators on Linux or macOS, you can use either the PowerShell operator script (after installing PowerShell Core) or the Makefile targets.

### Install PowerShell Core

```bash
# RHEL/CentOS
sudo dnf install -y powershell

# Ubuntu/Debian
sudo apt-get install -y powershell

# macOS
brew install powershell
```

Then use the same operator commands:

```bash
pwsh scripts/operator.ps1 validate-spec
pwsh scripts/operator.ps1 deploy-servers
```

### Alternative: Makefile Targets

If GNU Make is available:

| Make Command | Equivalent Operator Command |
|--------------|----------------------------|
| `make spec-init` | `.\scripts\operator.ps1 init-spec` |
| `make validate-spec` | `.\scripts\operator.ps1 validate-spec` |
| `make servers-deploy` | `.\scripts\operator.ps1 deploy-servers` |
| `make servers-report` | `.\scripts\operator.ps1 report-servers` |
| `make servers-destroy` | `.\scripts\operator.ps1 destroy-servers` |
| `make build-ovas` | `.\scripts\operator.ps1 build-ovas` |
| `make guide-validate` | `.\scripts\operator.ps1 guide-validate` |
| `make e2e` | `.\scripts\operator.ps1 e2e` |

---

## Appendix B: Testing/Validation Only - Windows 11 VM in vSphere

> **WARNING**: This section describes an **optional testing harness** for CI-like validation. It is **NOT** part of the production operator workflow. The primary workflow uses a Windows 11 laptop directly.

For automated testing environments, you can run the operator commands from a Windows 11 VM deployed in vSphere. This is useful for:
- CI/CD pipeline integration
- Automated regression testing
- Isolated test environments

### Test Harness Location

```
tests/windows-vsphere-operator/
  run.ps1           # Test harness entry script
  README.md         # Test harness documentation
```

### Running the Test Harness

```powershell
# From the project root
.\tests\windows-vsphere-operator\run.ps1

# Or with specific options
.\tests\windows-vsphere-operator\run.ps1 -VMName "test-operator-vm" -SkipVMDeploy
```

### Test Harness Artifacts

Test results are written to: `automation/artifacts/windows-vsphere-test/`

---

## Troubleshooting

### Kickstart Installation Fails
- Verify kickstart ISO has OEMDRV volume label
- Verify both ISOs are attached to VM
- Check vSphere console for boot errors

### Repository Service Not Accessible
- Check service: `ssh admin@<ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"`
- Check firewall: `ssh admin@<ip> "sudo firewall-cmd --list-ports"`

### PowerCLI Connection Fails
- Verify VMWARE_USER and VMWARE_PASSWORD environment variables
- Check vCenter/ESXi accessibility: `Test-NetConnection vcenter.example.local -Port 443`
- Verify PowerCLI is installed: `Get-Module -ListAvailable VMware.PowerCLI`

### ISO Upload Fails
- Verify datastore has sufficient space
- Check datastore permissions for the user
- Verify ISO path in spec.yaml is correct

### Python Not Found
- Install Python 3: `winget install Python.Python.3.12`
- Verify installation: `python --version`
- Install PyYAML: `pip install pyyaml`
