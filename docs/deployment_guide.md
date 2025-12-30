# Deployment Guide

## Overview

This guide covers the deployment of the airgapped RPM repository infrastructure consisting of two RHEL 9.6 servers:

- **External Server** (`rpm-external`): Internet-connected system that syncs packages from Red Hat CDN and prepares bundles for hand-carry transfer
- **Internal Server** (`rpm-internal`): Airgapped system that hosts the internal RPM repository serving managed RHEL hosts

The deployment automation uses VMware PowerCLI scripts with kickstart injection for fully automated installation. Two deployment methods are available:

1. **Kickstart ISO Injection**: Direct deployment from RHEL 9.6 ISO with automated kickstart configuration
2. **OVA Deployment**: Pre-built appliance images with first-boot customization via OVF properties

All automation artifacts reside in the repository under `automation/powercli/` and `automation/kickstart/`.

---

## Prerequisites

### Operator Workstation Requirements

The deployment automation can be run from Windows, Linux, or macOS. Install the required software for your platform:

#### Windows 11 (Recommended)

1. **PowerShell 5.1+** (included with Windows 11)

2. **VMware PowerCLI Module**
   ```powershell
   Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
   Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
   ```

3. **PowerShell YAML Module** (for configuration parsing)
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

#### Linux / macOS

1. **PowerShell Core**
   ```bash
   # RHEL/CentOS
   sudo dnf install -y powershell

   # Ubuntu/Debian
   sudo apt-get install -y powershell

   # macOS
   brew install powershell
   ```

2. **VMware PowerCLI Module**
   ```bash
   pwsh -Command "Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force"
   ```

3. **ISO creation tools**
   ```bash
   # RHEL/CentOS
   sudo dnf install -y genisoimage

   # Ubuntu/Debian
   sudo apt-get install -y genisoimage

   # macOS
   brew install cdrtools
   ```

4. **Python 3 with PyYAML**
   ```bash
   sudo dnf install -y python3 python3-pyyaml  # RHEL
   sudo apt-get install -y python3 python3-yaml  # Debian
   ```

5. **Make** (optional, for using Makefile targets)
   ```bash
   sudo dnf install -y make  # RHEL
   sudo apt-get install -y make  # Debian
   ```

### VMware Environment

- vCenter Server 7.0+ or ESXi 7.0+ with direct access
- VM deployment permissions
- Datastore with sufficient space (500GB+ recommended)
- Network port group with DHCP enabled

### Credentials

Set VMware credentials via environment variables:

**Windows PowerShell:**
```powershell
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "YourPassword"
```

**Linux/macOS:**
```bash
export VMWARE_USER="administrator@vsphere.local"
export VMWARE_PASSWORD="YourPassword"
```

---

## Windows PowerShell Commands

Windows operators can run PowerShell scripts directly instead of using `make` targets.

| Make Command | Windows PowerShell Equivalent |
|--------------|------------------------------|
| `make vsphere-discover` | `.\automation\powercli\discover-vsphere-defaults.ps1 -OutputDir automation\artifacts` |
| `make spec-init` | Run discover, then: `Copy-Item automation\artifacts\spec.detected.yaml config\spec.yaml` |
| `make validate-spec` | `.\automation\powercli\validate-spec.ps1 -SpecPath config\spec.yaml` |
| `make generate-ks-iso` | `.\automation\powercli\generate-ks-iso.ps1 -SpecPath config\spec.yaml -OutputDir output\ks-isos` |
| `make servers-deploy` | `.\automation\powercli\deploy-rpm-servers.ps1 -SpecPath config\spec.yaml` |
| `make servers-wait` | `.\automation\powercli\wait-for-install-complete.ps1 -SpecPath config\spec.yaml` |
| `make servers-report` | `.\automation\powercli\wait-for-dhcp-and-report.ps1 -SpecPath config\spec.yaml` |
| `make servers-destroy` | `.\automation\powercli\destroy-rpm-servers.ps1 -SpecPath config\spec.yaml` |
| `make build-ovas` | `.\automation\powercli\build-ovas.ps1 -SpecPath config\spec.yaml -OutputDir automation\artifacts\ovas` |

**Example: Full Windows Deployment**
```powershell
# Set credentials
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "YourPassword"

# Discover vSphere environment
.\automation\powercli\discover-vsphere-defaults.ps1 -OutputDir automation\artifacts

# Copy and edit spec.yaml
Copy-Item automation\artifacts\spec.detected.yaml config\spec.yaml
notepad config\spec.yaml  # Edit with your values

# Validate configuration
.\automation\powercli\validate-spec.ps1 -SpecPath config\spec.yaml

# Generate kickstart ISOs
.\automation\powercli\generate-ks-iso.ps1 -SpecPath config\spec.yaml -OutputDir output\ks-isos

# Deploy VMs
.\automation\powercli\deploy-rpm-servers.ps1 -SpecPath config\spec.yaml

# Wait for installation
.\automation\powercli\wait-for-install-complete.ps1 -SpecPath config\spec.yaml

# Get IP addresses
.\automation\powercli\wait-for-dhcp-and-report.ps1 -SpecPath config\spec.yaml
```

---

## Deployment Inputs

### Required Files

1. RHEL 9.6 DVD ISO image (downloaded from Red Hat Customer Portal)
2. VMware vCenter credentials with VM deployment permissions
3. Completed `config/spec.yaml` configuration file

### Configuration File: config/spec.yaml

The primary configuration file controls all deployment parameters:

```yaml
vcenter:
  server: "vcenter.example.local"
  datacenter: "Datacenter"
  cluster: "Cluster01"
  datastore: "datastore1"
  folder: ""  # Optional: VM folder path
  resource_pool: ""  # Optional
  # Credentials via environment: VMWARE_USER, VMWARE_PASSWORD

network:
  portgroup_name: "LAN"
  dhcp: true  # Required; static IP not supported in automated install

isos:
  rhel96_iso_path: "/isos/rhel-9.6-x86_64-dvd.iso"
  iso_datastore_folder: "isos"

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

### Generating Initial Configuration

1. Run the spec initialization target:
   ```bash
   make spec-init
   ```

2. Edit `config/spec.yaml` with your environment values

3. Validate the configuration:
   ```bash
   make validate-spec
   ```

---

## vSphere Environment Discovery

1. Execute the discovery target:
   ```bash
   make vsphere-discover
   ```

2. Review the generated discovery output:
   ```bash
   cat automation/artifacts/vsphere-defaults.json
   cat automation/artifacts/spec.detected.yaml
   ```

---

## Deployment Method Selection

### Method 1: Kickstart ISO Injection (Recommended for Initial Deployment)

**Use when:** Deploying for the first time, FIPS mode needed, custom partitioning required.

### Method 2: OVA Deployment (Recommended for Replication)

**Use when:** Deploying additional instances, faster deployment preferred.

---

## Kickstart ISO Deployment

### Step 1: Generate Kickstart ISOs

```bash
make generate-ks-iso
```

Alternatively, run the PowerCLI script directly:
```bash
pwsh automation/powercli/generate-ks-iso.ps1 -SpecPath config/spec.yaml
```

### Step 2: Deploy VMs

```bash
make servers-deploy
```

### Step 3: Wait for Installation and Discover IPs

Wait for VMs to complete installation and obtain DHCP-assigned IPs:
```bash
make servers-wait
make servers-report
```

### Step 4: Validate Installation

Using the IPs from `servers-report`:
```bash
ssh admin@<internal-ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"
curl -k https://<internal-ip>/repo/stable/
```

---

## OVA Deployment

### Step 1: Build OVA Images

```bash
make build-ovas
```

### Step 2: Deploy from OVA

Deploy through vSphere Client or PowerCLI with OVF properties for hostname and network configuration.

---

## Post-Install Validation

Run the E2E test suite:
```bash
make e2e
```

Reports are generated in `automation/artifacts/e2e/`.

---

## Initial System State

| Component | State |
|-----------|-------|
| Repository Service | Running under rpmops user |
| TLS Certificate | Self-signed (replace for production) |
| Repository Content | Empty (import first bundle) |

---

## Deployment Troubleshooting

### Kickstart Installation Fails
- Verify kickstart ISO has OEMDRV volume label
- Verify both ISOs are attached to VM

### Repository Service Not Accessible
- Check service: `systemctl --user -M rpmops@ status airgap-rpm-publisher.service`
- Check firewall: `sudo firewall-cmd --list-ports`
