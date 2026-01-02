# Deployment Guide - Red Hat Satellite + Capsule Architecture

## Overview

This guide covers the deployment of the airgapped RPM repository infrastructure using Red Hat Satellite and Capsule:

- **External Satellite Server** (`satellite-external`): Internet-connected RHEL 9.6 system that syncs content from Red Hat CDN, manages Content Views, and exports bundles for hand-carry transfer
- **Internal Capsule Server** (`capsule-internal`): Airgapped RHEL 9.6 system that imports content bundles and serves packages to managed hosts over HTTPS

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL (Connected)                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Red Hat Satellite 6.15+                                             │  │
│  │  - Syncs from Red Hat CDN                                            │  │
│  │  - Content Views: cv_rhel8_security, cv_rhel9_security              │  │
│  │  - Lifecycle: Library → test → prod                                  │  │
│  │  - Exports security-filtered bundles                                 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                              [Hand-Carry Transfer]
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INTERNAL (Airgapped)                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Red Hat Capsule                                                     │  │
│  │  - Imports content bundles                                           │  │
│  │  - Serves RHEL 8.10 + 9.6 content over HTTPS                        │  │
│  │  - Managed hosts connect here for updates                            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                         ┌──────────┴──────────┐                            │
│                         ▼                     ▼                            │
│                 ┌──────────────┐      ┌──────────────┐                     │
│                 │ RHEL 8.10    │      │ RHEL 9.6     │                     │
│                 │ Tester Host  │      │ Tester Host  │                     │
│                 └──────────────┘      └──────────────┘                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

> **Authoritative Prerequisites Guardrail**
>
> This section is the **single source of truth** for Windows 11 operator prerequisites.
>
> **Rules:**
> - No additional software requirements may be inferred or added unless explicitly invoked.
> - If a tool is not directly executed by the operator workflow, it is **not a prerequisite**.
>
> **Explicitly forbidden requirement inflation:**
> - Do NOT require Python unless the operator runs Python directly.
> - Do NOT require Windows ADK/WinPE unless building Windows images.
> - Do NOT require YAML modules unless the operator imports them.
> - Do NOT require GNU Make on Windows.
> - Do NOT require Git on Windows.
> - Do NOT require WSL.

---

## Obtaining the Software

This project uses **ZIP-based delivery** for air-gapped environments. Git is NOT required.

### Package Contents

You will receive two ZIP files:

| Package | Contents | Size |
|---------|----------|------|
| `airgapped-deps.zip` | PowerShell 7 MSI, VMware.PowerCLI modules | ~200MB |
| `airgapped-rpm-repo.zip` | Repository scripts, kickstarts, Ansible playbooks | ~5MB |

### Extraction Steps

```powershell
# Create working directory
New-Item -ItemType Directory -Force -Path C:\src

# Extract dependencies (run first)
Expand-Archive -Path .\airgapped-deps.zip -DestinationPath C:\src\airgapped-deps

# Extract repository
Expand-Archive -Path .\airgapped-rpm-repo.zip -DestinationPath C:\src\airgapped-rpm-repo
```

### Install Dependencies (Air-gapped)

```powershell
# Open PowerShell as Administrator
cd C:\src\airgapped-deps

# Verify checksums (recommended)
.\checksums\verify.ps1

# Install PowerShell 7 and VMware.PowerCLI
.\install-deps.ps1
```

After installation, open a **new PowerShell 7 terminal** (`pwsh`) to continue.

---

## Windows 11 Laptop (Primary Workflow)

### Prerequisites

If you installed from `airgapped-deps.zip`, these are already satisfied.

1. **PowerShell 7+**
   ```powershell
   # Verify version (must be 7.x)
   $PSVersionTable.PSVersion
   ```

2. **VMware PowerCLI Module**
   ```powershell
   # Verify installed
   Get-Module -ListAvailable VMware.PowerCLI

   # Configure (first time only)
   Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
   ```

> **Note:** Python, Windows ADK, powershell-yaml, Git, WSL, and GNU Make are explicitly **NOT REQUIRED**.

### Set VMware Credentials

```powershell
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "YourSecurePassword"
```

---

## Quick Start: Full Deployment

```powershell
# 1. Initialize configuration from vSphere discovery
.\scripts\operator.ps1 init-spec

# 2. Edit spec.yaml with your environment values
notepad config\spec.yaml

# 3. Validate configuration
.\scripts\operator.ps1 validate-spec

# 4. Deploy Satellite and Capsule servers
.\scripts\operator.ps1 deploy-servers

# 5. Check deployment status and get IP addresses
.\scripts\operator.ps1 report-servers
```

---

## VM Sizing Requirements

### Satellite Server (External)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 vCPU | 4 vCPU |
| Memory | 20 GB | 32 GB |
| OS Disk | 50 GB | 100 GB |
| PostgreSQL Disk | 100 GB | 200 GB |
| Pulp Content Disk | 500 GB | 1 TB |

### Capsule Server (Internal)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 vCPU | 4 vCPU |
| Memory | 16 GB | 20 GB |
| OS Disk | 50 GB | 100 GB |
| Pulp Content Disk | 300 GB | 500 GB |

### Tester Hosts

| Resource | Value |
|----------|-------|
| CPU | 2 vCPU |
| Memory | 4 GB |
| OS Disk | 50 GB |

---

## Configuration Reference

### spec.yaml Structure

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
  rhel810_iso_path: "[datastore1] isos/rhel-8.10-x86_64-dvd.iso"

# Satellite Configuration
satellite:
  organization: "Default Organization"
  location: "Default Location"
  lifecycle_environments:
    - name: "test"
      prior: "Library"
    - name: "prod"
      prior: "test"

# Content Views with Security Filtering
content_views:
  - name: "cv_rhel8_security"
    repositories:
      - product: "Red Hat Enterprise Linux for x86_64"
        name: "Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs 8.10"
      - product: "Red Hat Enterprise Linux for x86_64"
        name: "Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs 8.10"
    filters:
      - name: "security_errata_only"
        type: "erratum"
        errata_type: "security"
  - name: "cv_rhel9_security"
    repositories:
      - product: "Red Hat Enterprise Linux for x86_64"
        name: "Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs 9.6"
      - product: "Red Hat Enterprise Linux for x86_64"
        name: "Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs 9.6"
    filters:
      - name: "security_errata_only"
        type: "erratum"
        errata_type: "security"

# VM Sizing
vm_sizing:
  satellite:
    cpu: 4
    memory_gb: 20
    os_disk_gb: 100
    pgsql_disk_gb: 100
    pulp_disk_gb: 500
  capsule:
    cpu: 4
    memory_gb: 16
    os_disk_gb: 100
    pulp_disk_gb: 300
  tester:
    cpu: 2
    memory_gb: 4
    disk_gb: 50

credentials:
  initial_root_password: "ChangeMe123!"
  initial_admin_user: "admin"
  initial_admin_password: "ChangeMe123!"

compliance:
  enable_fips: true
```

---

## Detailed Deployment Steps

### Step 1: Deploy Satellite Server (External)

The Satellite server is deployed to the connected network with internet access.

```powershell
.\scripts\operator.ps1 deploy-satellite
```

After VM deployment, SSH in and run the installation:

```powershell
# SSH to Satellite server
ssh admin@<satellite-ip>

# Run Satellite installation (requires Red Hat subscription)
sudo /opt/satellite-setup/satellite-install.sh \
  --manifest /path/to/manifest.zip \
  --org "Default Organization"
```

### Step 2: Configure Content

```powershell
# Enable RHEL repositories and create Content Views
ssh admin@<satellite-ip> "sudo /opt/satellite-setup/satellite-configure-content.sh --org 'Default Organization' --sync --create-cv"
```

This script:
1. Enables RHEL 8.10 and RHEL 9.6 BaseOS + AppStream repositories
2. Syncs content from Red Hat CDN
3. Creates security-filtered Content Views
4. Publishes and promotes to test/prod lifecycle environments

### Step 3: Deploy Capsule Server (Internal)

The Capsule server is deployed to the airgapped network.

```powershell
.\scripts\operator.ps1 deploy-capsule
```

### Step 4: Export Content Bundle

On the Satellite server, export the Content Views for hand-carry transfer:

```powershell
ssh admin@<satellite-ip> "sudo /opt/satellite-setup/satellite-export-bundle.sh \
  --org 'Default Organization' \
  --lifecycle-env prod \
  --output-dir /var/lib/pulp/exports"
```

### Step 5: Transfer Bundle

Copy the bundle to removable media for hand-carry transfer:

```powershell
# From Satellite server to USB/removable media
scp admin@<satellite-ip>:/var/lib/pulp/exports/airgap-security-bundle-*.tar.gz /path/to/usb/
scp admin@<satellite-ip>:/var/lib/pulp/exports/airgap-security-bundle-*.tar.gz.sha256 /path/to/usb/
```

### Step 6: Import Content on Capsule

On the internal network, import the bundle:

```powershell
# Copy from USB to Capsule
scp /path/to/usb/airgap-security-bundle-*.tar.gz admin@<capsule-ip>:/var/lib/pulp/imports/

# Import the bundle
ssh admin@<capsule-ip> "sudo /opt/capsule-setup/capsule-import-bundle.sh \
  --bundle /var/lib/pulp/imports/airgap-security-bundle-*.tar.gz \
  --org 'Default Organization'"
```

### Step 7: Configure Managed Hosts

Run the Ansible playbook to configure hosts to use the Capsule:

```powershell
ssh admin@<management-host> "cd /srv/airgap/ansible && \
  ansible-playbook -i inventories/lab.yml playbooks/configure_capsule_repos.yml"
```

---

## Post-Deployment Validation

### Verify Satellite

```powershell
ssh admin@<satellite-ip> "hammer ping"
ssh admin@<satellite-ip> "hammer content-view list --organization 'Default Organization'"
```

### Verify Capsule Content

```powershell
ssh admin@<capsule-ip> "dnf repolist"
ssh admin@<capsule-ip> "curl -k https://localhost/content/"
```

### Verify Managed Hosts

```powershell
ssh admin@<tester-host> "dnf repolist"
ssh admin@<tester-host> "dnf check-update --security"
```

---

## Operator CLI Reference

| Command | Description |
|---------|-------------|
| `.\scripts\operator.ps1 init-spec` | Discover vSphere and initialize spec.yaml |
| `.\scripts\operator.ps1 validate-spec` | Validate spec.yaml configuration |
| `.\scripts\operator.ps1 deploy-servers` | Deploy Satellite, Capsule, and Tester VMs |
| `.\scripts\operator.ps1 report-servers` | Report VM status and DHCP IPs |
| `.\scripts\operator.ps1 destroy-servers` | Destroy all deployed VMs |
| `.\scripts\operator.ps1 e2e` | Run full E2E test suite |

---

## Kickstart Files

| Kickstart | Server Type | Description |
|-----------|-------------|-------------|
| `ks-satellite.cfg` | Satellite | Multi-disk layout for OS, PostgreSQL, Pulp |
| `ks-capsule.cfg` | Capsule | Multi-disk layout for OS, Pulp import/content |
| `ks-rhel8-host.cfg` | Tester | RHEL 8.10 managed host |
| `ks-rhel9-host.cfg` | Tester | RHEL 9.6 managed host |

---

## Scripts Reference

### Satellite Scripts (`scripts/satellite/`)

| Script | Purpose |
|--------|---------|
| `satellite-install.sh` | Install and configure Satellite server |
| `satellite-configure-content.sh` | Enable repos, create Content Views, sync |
| `satellite-export-bundle.sh` | Export Content Views as transfer bundle |
| `capsule-import-bundle.sh` | Import bundle into Capsule |

---

## Troubleshooting

### Satellite Installation Fails

```bash
# Check Satellite installer logs
sudo tail -f /var/log/foreman-installer/satellite.log

# Verify subscription
sudo subscription-manager status
```

### Content Sync Fails

```bash
# Check sync status
hammer sync-plan list --organization "Default Organization"
hammer task list --search "label ~ sync"

# Check Pulp logs
sudo tail -f /var/log/messages | grep pulp
```

### Capsule Import Fails

```bash
# Verify bundle checksum
sha256sum -c bundle.tar.gz.sha256

# Check import logs
sudo tail -f /var/log/capsule-setup/import.log
```

### Managed Host Cannot Access Capsule

```bash
# Verify CA certificate
openssl s_client -connect capsule-internal:443 -CAfile /etc/pki/tls/certs/capsule-ca.crt

# Check firewall
sudo firewall-cmd --list-all

# Verify repo configuration
cat /etc/yum.repos.d/capsule-*.repo
```

---

## Appendix A: Linux/macOS Operators

For operators on Linux or macOS:

```bash
# Install PowerShell Core
# RHEL: sudo dnf install -y powershell
# Ubuntu: sudo apt-get install -y powershell
# macOS: brew install powershell

# Use same operator commands
pwsh scripts/operator.ps1 validate-spec
pwsh scripts/operator.ps1 deploy-servers
```

---

## Appendix B: Evidence Collection

Evidence for compliance is collected in `automation/artifacts/e2e-satellite-proof/`:

```
automation/artifacts/e2e-satellite-proof/
├── satellite/
│   ├── cv-versions.txt
│   ├── sync-status.txt
│   └── export-manifest.json
├── capsule/
│   ├── import-report.txt
│   └── content-listing.txt
├── testers/
│   ├── rhel8/
│   │   ├── pre-patch-packages.txt
│   │   ├── post-patch-packages.txt
│   │   ├── uname-r.txt
│   │   └── os-release.txt
│   └── rhel9/
│       ├── pre-patch-packages.txt
│       ├── post-patch-packages.txt
│       ├── uname-r.txt
│       └── os-release.txt
└── README.txt
```
