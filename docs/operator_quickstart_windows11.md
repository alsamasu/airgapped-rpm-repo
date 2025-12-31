# Operator Quick Checklist - Windows 11

> **One-Page Quick Reference for Windows 11 Laptop Operators**

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
```

---

## Operator Workflow

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

## Command Reference

| Command | Description |
|---------|-------------|
| `.\scripts\operator.ps1 init-spec` | Discover vSphere and initialize spec.yaml |
| `.\scripts\operator.ps1 validate-spec` | Validate configuration |
| `.\scripts\operator.ps1 deploy-servers` | Deploy VMs |
| `.\scripts\operator.ps1 report-servers` | Get VM status and IPs |
| `.\scripts\operator.ps1 destroy-servers` | Delete VMs (requires confirmation) |
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

## Troubleshooting

| Issue | Check |
|-------|-------|
| PowerCLI connection fails | Verify `$env:VMWARE_USER` and `$env:VMWARE_PASSWORD` are set |
| Spec validation fails | Run `.\scripts\operator.ps1 validate-spec` for specific errors |
| VM not accessible | Check vSphere console; wait for DHCP assignment |

---

## References

- Full guide: `docs/deployment_guide.md`
- Administration: `docs/administration_guide.md`
