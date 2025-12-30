<#
.SYNOPSIS
    Destroy External and Internal RPM server VMs.

.DESCRIPTION
    Removes VMs created by deploy-rpm-servers.ps1. VMs are powered off
    and permanently deleted including all disks.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER Force
    Skip confirmation prompts (DANGEROUS).

.EXAMPLE
    ./destroy-rpm-servers.ps1

.EXAMPLE
    ./destroy-rpm-servers.ps1 -Force

.NOTES
    WARNING: This permanently deletes VMs and all data!
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Load configuration
Write-Host "Loading configuration..." -ForegroundColor Cyan
$config = & (Join-Path $PSScriptRoot "Read-SpecConfig.ps1") -SpecPath $SpecPath

$vmNames = @($config.vm_names.rpm_external, $config.vm_names.rpm_internal)

Write-Host @"

===============================================================================
  AIRGAPPED RPM REPOSITORY - VM DESTRUCTION
===============================================================================

  WARNING: This will PERMANENTLY DELETE the following VMs:

"@ -ForegroundColor Red

foreach ($vmName in $vmNames) {
    Write-Host "    - $vmName" -ForegroundColor Yellow
}

Write-Host @"

  All VM disks and configurations will be destroyed!

===============================================================================

"@ -ForegroundColor Red

# Get credentials
$vcUser = $env:VMWARE_USER
$vcPassword = $env:VMWARE_PASSWORD

if (-not $vcUser) {
    $vcUser = Read-Host "vCenter Username"
}
if (-not $vcPassword) {
    $secPassword = Read-Host "vCenter Password" -AsSecureString
    $vcPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPassword)
    )
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

# Connect to vCenter
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

try {
    $conn = Connect-VIServer -Server $config.vcenter.server -User $vcUser -Password $vcPassword -ErrorAction Stop
    Write-Host "[OK] Connected to $($conn.Name)" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# Destroy VMs
$deletedCount = 0
$notFoundCount = 0
$errorCount = 0

foreach ($vmName in $vmNames) {
    Write-Host "`n--- $vmName ---" -ForegroundColor Yellow
    
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "[SKIP] VM not found" -ForegroundColor Gray
        $notFoundCount++
        continue
    }
    
    try {
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Host "  Powering off..." -ForegroundColor White
            Stop-VM -VM $vm -Confirm:$false -Kill -ErrorAction Stop | Out-Null
        }
        
        Write-Host "  Deleting VM and disks..." -ForegroundColor White
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] Deleted" -ForegroundColor Green
        $deletedCount++
        
    } catch {
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
    }
}

Write-Host @"

===============================================================================
  DESTRUCTION SUMMARY
===============================================================================

  Deleted:   $deletedCount VM(s)
  Not Found: $notFoundCount VM(s)
  Errors:    $errorCount

===============================================================================

"@

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

if ($errorCount -gt 0) {
    exit 1
}
