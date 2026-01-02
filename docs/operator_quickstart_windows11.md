# Operator Quick Checklist - Windows 11

> **One-Page Quick Reference for Windows 11 Laptop Operators**
>
> Red Hat Satellite + Capsule Architecture

---

## Step 0: Install Dependencies (Air-gapped)

Extract and install from the provided ZIP files:

```powershell
# Extract packages
Expand-Archive -Path .\airgapped-deps.zip -DestinationPath C:\src\airgapped-deps
Expand-Archive -Path .\airgapped-rpm-repo.zip -DestinationPath C:\src\airgapped-rpm-repo

# Install dependencies (run as Administrator)
cd C:\src\airgapped-deps
.\install-deps.ps1

# Open new PowerShell 7 terminal
pwsh
```

---

## Prerequisites (Minimal)

| Requirement | Verify Command |
|-------------|----------------|
| PowerShell 7+ | `$PSVersionTable.PSVersion` (must show 7.x) |
| VMware PowerCLI | `Get-Module -ListAvailable VMware.PowerCLI` |

**NOT REQUIRED:** Git, Python, Windows ADK, powershell-yaml, GNU Make, WSL

---

## Environment Setup

```powershell
# Set vSphere credentials (required before any VMware operation)
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "YourSecurePassword"

# Navigate to project
cd C:\src\airgapped-rpm-repo
```

---

## Initial Deployment

### 1. Initialize Configuration

```powershell
.\scripts\operator.ps1 init-spec
```

### 2. Edit Configuration

```powershell
notepad config\spec.yaml
```

### 3. Validate Configuration

```powershell
.\scripts\operator.ps1 validate-spec
```

### 4. Deploy Servers

```powershell
.\scripts\operator.ps1 deploy-servers
```

### 5. Check Status

```powershell
.\scripts\operator.ps1 report-servers
```

---

## Monthly Patch Workflow

### External Satellite (Connected Network)

```powershell
# 1. Sync from Red Hat CDN
ssh admin@<satellite-ip> "sudo /opt/satellite-setup/satellite-configure-content.sh --org 'Default Organization' --sync"

# 2. Publish Content Views
ssh admin@<satellite-ip> "hammer content-view publish --organization 'Default Organization' --name 'cv_rhel8_security'"
ssh admin@<satellite-ip> "hammer content-view publish --organization 'Default Organization' --name 'cv_rhel9_security'"

# 3. Export bundle
ssh admin@<satellite-ip> "sudo /opt/satellite-setup/satellite-export-bundle.sh --org 'Default Organization' --lifecycle-env prod"

# 4. Copy bundle to USB
scp admin@<satellite-ip>:/var/lib/pulp/exports/airgap-security-bundle-*.tar.gz E:\transfer\
```

### Internal Capsule (Airgapped Network)

```powershell
# 5. Copy bundle from USB
scp E:\transfer\airgap-security-bundle-*.tar.gz admin@<capsule-ip>:/var/lib/pulp/imports/

# 6. Import bundle
ssh admin@<capsule-ip> "sudo /opt/capsule-setup/capsule-import-bundle.sh --bundle /var/lib/pulp/imports/airgap-security-bundle-*.tar.gz"

# 7. Run patching playbook
ssh admin@<management-host> "cd /srv/airgap/ansible && ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml"
```

---

## Command Reference

| Command | Description |
|---------|-------------|
| `.\scripts\operator.ps1 init-spec` | Discover vSphere and initialize spec.yaml |
| `.\scripts\operator.ps1 validate-spec` | Validate configuration |
| `.\scripts\operator.ps1 deploy-servers` | Deploy Satellite, Capsule, Tester VMs |
| `.\scripts\operator.ps1 report-servers` | Get VM status and IPs |
| `.\scripts\operator.ps1 destroy-servers` | Delete VMs (requires confirmation) |
| `.\scripts\operator.ps1 e2e` | Run full E2E test suite |
| `.\scripts\operator.ps1 -Help` | Show full help |

---

## Common Options

```powershell
# Skip confirmation prompts
.\scripts\operator.ps1 deploy-servers -Force

# Preview without executing
.\scripts\operator.ps1 deploy-servers -WhatIf

# Custom spec path
.\scripts\operator.ps1 validate-spec -SpecPath C:\path\to\spec.yaml
```

---

## SSH Commands Quick Reference

### Satellite Server

```powershell
# Check Satellite health
ssh admin@<satellite-ip> "hammer ping"

# List Content Views
ssh admin@<satellite-ip> "hammer content-view list --organization 'Default Organization'"

# Check sync status
ssh admin@<satellite-ip> "hammer task list --search 'label ~ sync'"
```

### Capsule Server

```powershell
# Check content availability
ssh admin@<capsule-ip> "dnf repolist"

# Check HTTPS content serving
ssh admin@<capsule-ip> "curl -k https://localhost/content/"
```

### Managed Hosts

```powershell
# Check available security updates
ssh admin@<tester-host> "dnf updateinfo list security"

# Check patching evidence
ssh admin@<tester-host> "cat /var/log/patching/evidence-*.txt"
```

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| PowerCLI connection fails | Verify `$env:VMWARE_USER` and `$env:VMWARE_PASSWORD` are set |
| Spec validation fails | Run `.\scripts\operator.ps1 validate-spec` for specific errors |
| VM not accessible | Check vSphere console; wait for DHCP assignment |
| Sync fails | `ssh admin@<satellite-ip> "hammer task list --search 'result = error'"` |
| Import fails | `ssh admin@<capsule-ip> "sha256sum -c /var/lib/pulp/imports/*.sha256"` |
| Host can't reach Capsule | Check `/etc/yum.repos.d/capsule-*.repo` and CA cert |

---

## Evidence Locations

| Server | Path | Contents |
|--------|------|----------|
| Satellite | `/var/lib/pulp/exports/` | Export bundles |
| Capsule | `/var/lib/pulp/imports/` | Import staging |
| Managed hosts | `/var/log/patching/` | Patch evidence |
| Controller | `./artifacts/evidence/` | Collected reports |

---

## Key Contacts

| Role | Responsibility |
|------|---------------|
| Operator | Deploy infrastructure, run monthly patch cycle |
| Admin | Manage Content Views, troubleshoot Satellite |
| Security | Review evidence reports, approve patches |

---

## References

- Full deployment guide: `docs/deployment_guide.md`
- Administration runbook: `docs/administration_guide.md`
- Ansible playbooks: `ansible/playbooks/`
- Satellite scripts: `scripts/satellite/`
