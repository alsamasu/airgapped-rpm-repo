<#
.SYNOPSIS
    Destroy Airgapped RPM Repository Lab Environment

.DESCRIPTION
    Removes all VMs created by deploy-airgap-lab.ps1:
    - rpm-external
    - rpm-internal
    - rhel8-host
    - rhel9-host

    VMs are powered off (if running) and permanently deleted including all disks.

.PARAMETER Server
    ESXi/vCenter server address

.PARAMETER User
    Username for authentication

.PARAMETER Password
    Password for authentication

.PARAMETER Force
    Skip confirmation prompts (DANGEROUS!)

.EXAMPLE
    ./destroy-airgap-lab.ps1 -Server 192.168.1.99 -User root -Password secret

.EXAMPLE
    ./destroy-airgap-lab.ps1 -Force  # Uses environment variables, no confirmation

.NOTES
    Author: Binhex DevOps
    Date: 2025-12-30
    WARNING: This script permanently deletes VMs and their data!
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Server = $env:VMWARE_SERVER,

    [Parameter(Mandatory=$false)]
    [string]$User = $env:VMWARE_USER,

    [Parameter(Mandatory=$false)]
    [string]$Password = $env:VMWARE_PASSWORD,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Configuration
# =============================================================================

$VMNames = @(
    "rpm-external",
    "rpm-internal",
    "rhel8-host",
    "rhel9-host"
)

# =============================================================================
# Functions
# =============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

# =============================================================================
# Main Script
# =============================================================================

Write-Host @"

===============================================================================
  AIRGAPPED RPM REPOSITORY - LAB DESTRUCTION
===============================================================================

  WARNING: This script will PERMANENTLY DELETE the following VMs:

"@ -ForegroundColor Red

foreach ($vmName in $VMNames) {
    Write-Host "    - $vmName" -ForegroundColor Yellow
}

Write-Host @"

  All VM disks and configurations will be destroyed!

===============================================================================

"@ -ForegroundColor Red

# Validate parameters
if (-not $Server -or -not $User -or -not $Password) {
    Write-Fail "Missing required parameters. Set VMWARE_SERVER, VMWARE_USER, VMWARE_PASSWORD or pass as arguments."
    exit 1
}

# Confirmation
if (-not $Force) {
    Write-Host "Type 'DESTROY' to confirm permanent deletion: " -NoNewline -ForegroundColor Red
    $confirm = Read-Host
    if ($confirm -ne "DESTROY") {
        Write-Host "`nAborted. No changes made." -ForegroundColor Green
        exit 0
    }
}

Write-Step "Configuring PowerCLI"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null
Write-Success "PowerCLI configured"

Write-Step "Connecting to $Server"
try {
    $connection = Connect-VIServer -Server $Server -User $User -Password $Password -ErrorAction Stop
    Write-Success "Connected to $($connection.Name)"
} catch {
    Write-Fail "Failed to connect: $($_.Exception.Message)"
    exit 1
}

# =============================================================================
# VM Destruction
# =============================================================================

Write-Step "Destroying Virtual Machines"

$deletedCount = 0
$notFoundCount = 0
$errorCount = 0

foreach ($vmName in $VMNames) {
    Write-Host "`n--- $vmName ---" -ForegroundColor Yellow

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warn "VM not found (already deleted?)"
        $notFoundCount++
        continue
    }

    try {
        # Power off if running
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Info "Powering off..."
            Stop-VM -VM $vm -Confirm:$false -Kill -ErrorAction Stop | Out-Null
            Write-Success "Powered off"
        }

        # Delete VM and disks
        Write-Info "Deleting VM and disks..."
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
        Write-Success "VM deleted permanently"
        $deletedCount++

    } catch {
        Write-Fail "Error: $($_.Exception.Message)"
        $errorCount++
    }
}

# =============================================================================
# Summary
# =============================================================================

Write-Host @"

===============================================================================
  DESTRUCTION SUMMARY
===============================================================================

  Deleted:   $deletedCount VM(s)
  Not Found: $notFoundCount VM(s)
  Errors:    $errorCount

"@

if ($errorCount -gt 0) {
    Write-Host "  Some VMs could not be deleted. Check errors above." -ForegroundColor Red
} elseif ($deletedCount -eq 0) {
    Write-Host "  No VMs were found to delete." -ForegroundColor Yellow
} else {
    Write-Host "  Lab environment destroyed successfully." -ForegroundColor Green
}

Write-Host @"

===============================================================================

"@

Disconnect-VIServer -Server $Server -Confirm:$false -ErrorAction SilentlyContinue
