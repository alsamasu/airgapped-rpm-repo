<#
.SYNOPSIS
    Deploy Airgapped RPM Repository Lab Environment

.DESCRIPTION
    Creates 4 VMs for testing the airgapped-rpm-repo system:
    - rpm-external: External RPM Server (RHEL 9.6, 2 vCPU, 8GB RAM, 200GB disk)
    - rpm-internal: Internal RPM Server (RHEL 9.6, 2 vCPU, 8GB RAM, 200GB disk)
    - rhel8-host: RHEL 8 Host (RHEL 8.10, 2 vCPU, 4GB RAM, 40GB disk)
    - rhel9-host: RHEL 9 Host (RHEL 9.6, 2 vCPU, 4GB RAM, 40GB disk)

    All VMs use EFI firmware and connect to the LAN port group.
    Uses rhel8_64Guest for ESXi 7.0 compatibility.

.PARAMETER Server
    ESXi/vCenter server address (default: $env:VMWARE_SERVER)

.PARAMETER User
    Username for authentication (default: $env:VMWARE_USER)

.PARAMETER Password
    Password for authentication (default: $env:VMWARE_PASSWORD)

.PARAMETER Datastore
    Datastore name for VM storage (default: "datastore1 (1)")

.PARAMETER SkipConfirmation
    Skip confirmation prompts

.EXAMPLE
    ./deploy-airgap-lab.ps1 -SkipConfirmation

.NOTES
    Author: Binhex DevOps
    Date: 2025-12-30
    Requires: VMware PowerCLI 13.x+, ESXi 7.0+
#>

[CmdletBinding()]
param(
    [string]$Server = $env:VMWARE_SERVER,
    [string]$User = $env:VMWARE_USER,
    [string]$Password = $env:VMWARE_PASSWORD,
    [string]$Datastore = "datastore1 (1)",
    [switch]$SkipConfirmation
)

$ErrorActionPreference = "Stop"

# =============================================================================
# VM Specifications
# =============================================================================

$VMSpecs = @(
    @{
        Name = "rpm-external"
        Description = "External RPM Server (Internet-reachable)"
        NumCpu = 2
        MemoryGB = 8
        DiskGB = 200
        Firmware = "efi"
        IsoFile = "rhel-9.6-x86_64-dvd.iso"
    },
    @{
        Name = "rpm-internal"
        Description = "Internal RPM Server (Airgapped)"
        NumCpu = 2
        MemoryGB = 8
        DiskGB = 200
        Firmware = "efi"
        IsoFile = "rhel-9.6-x86_64-dvd.iso"
    },
    @{
        Name = "rhel8-host"
        Description = "RHEL 8 Managed Host"
        NumCpu = 2
        MemoryGB = 4
        DiskGB = 40
        Firmware = "efi"
        IsoFile = "rhel-8.10-x86_64-dvd.iso"
    },
    @{
        Name = "rhel9-host"
        Description = "RHEL 9 Managed Host"
        NumCpu = 2
        MemoryGB = 4
        DiskGB = 40
        Firmware = "efi"
        IsoFile = "rhel-9.6-x86_64-dvd.iso"
    }
)

$NetworkName = "LAN"
$GuestId = "rhel8_64Guest"  # ESXi 7.0 compatible
$IsoBasePath = "[$Datastore]/isos"

# =============================================================================
# Main Script
# =============================================================================

Write-Host @"

===============================================================================
  AIRGAPPED RPM REPOSITORY - LAB DEPLOYMENT
===============================================================================

  VMs to create:
  +----------------+------------+------+-------+--------+-------------------------+
  | Name           | OS         | vCPU | RAM   | Disk   | ISO                     |
  +----------------+------------+------+-------+--------+-------------------------+
  | rpm-external   | RHEL 9.6   | 2    | 8 GB  | 200 GB | rhel-9.6-x86_64-dvd.iso |
  | rpm-internal   | RHEL 9.6   | 2    | 8 GB  | 200 GB | rhel-9.6-x86_64-dvd.iso |
  | rhel8-host     | RHEL 8.10  | 2    | 4 GB  | 40 GB  | rhel-8.10-x86_64-dvd.iso|
  | rhel9-host     | RHEL 9.6   | 2    | 4 GB  | 40 GB  | rhel-9.6-x86_64-dvd.iso |
  +----------------+------------+------+-------+--------+-------------------------+

  Network: $NetworkName
  Datastore: $Datastore

===============================================================================

"@

# Validate parameters
if (-not $Server -or -not $User -or -not $Password) {
    Write-Host "[FAIL] Missing credentials. Set VMWARE_SERVER, VMWARE_USER, VMWARE_PASSWORD" -ForegroundColor Red
    exit 1
}

# Confirmation
if (-not $SkipConfirmation) {
    $confirm = Read-Host "Proceed with deployment? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Aborted."
        exit 0
    }
}

# Configure PowerCLI
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

# Connect
Write-Host "Connecting to $Server..." -ForegroundColor Cyan
try {
    $conn = Connect-VIServer -Server $Server -User $User -Password $Password -ErrorAction Stop
    Write-Host "[OK] Connected to $($conn.Name) ($($conn.ProductLine) $($conn.Version))" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$vmHost = Get-VMHost | Select-Object -First 1
$ds = Get-Datastore -Name $Datastore -ErrorAction Stop

# Check for existing VMs
Write-Host "`nChecking for existing VMs..." -ForegroundColor Cyan
$conflicts = @()
foreach ($spec in $VMSpecs) {
    $existing = Get-VM -Name $spec.Name -ErrorAction SilentlyContinue
    if ($existing) {
        $conflicts += $spec.Name
    }
}

if ($conflicts.Count -gt 0) {
    Write-Host "[FAIL] VMs already exist: $($conflicts -join ', ')" -ForegroundColor Red
    Write-Host "       Run destroy-airgap-lab.ps1 first." -ForegroundColor Yellow
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "[OK] No conflicts" -ForegroundColor Green

# Create VMs
Write-Host "`nCreating VMs..." -ForegroundColor Cyan

$createdVMs = @()
foreach ($spec in $VMSpecs) {
    Write-Host "  $($spec.Name) [$($spec.IsoFile)]" -ForegroundColor Yellow

    try {
        # Create VM
        $vm = New-VM -Name $spec.Name -VMHost $vmHost -Datastore $ds -GuestId $GuestId `
            -NumCpu $spec.NumCpu -MemoryGB $spec.MemoryGB -DiskGB $spec.DiskGB `
            -DiskStorageFormat Thin -NetworkName $NetworkName -ErrorAction Stop

        # Set EFI firmware
        if ($spec.Firmware -eq "efi") {
            $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec
            $cfg.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
            $vm.ExtensionData.ReconfigVM($cfg)
        }

        # Add CD drive with ISO
        $isoPath = "$IsoBasePath/$($spec.IsoFile)"
        New-CDDrive -VM $vm -IsoPath $isoPath -StartConnected | Out-Null

        # Power on
        Start-VM -VM $vm -Confirm:$false | Out-Null

        Write-Host "    [OK] Created and powered on" -ForegroundColor Green
        $createdVMs += $vm

    } catch {
        Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red

        # Rollback
        Write-Host "`nRolling back..." -ForegroundColor Yellow
        foreach ($v in $createdVMs) {
            Stop-VM -VM $v -Confirm:$false -Kill -ErrorAction SilentlyContinue | Out-Null
            Remove-VM -VM $v -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
        }
        Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }
}

# Final status
Write-Host "`n=== DEPLOYMENT COMPLETE ===" -ForegroundColor Green

Get-VM | Where-Object { $_.Name -match "rpm-|rhel" } | ForEach-Object {
    $cd = Get-CDDrive -VM $_
    $nic = Get-NetworkAdapter -VM $_
    $iso = if ($cd.IsoPath) { Split-Path $cd.IsoPath -Leaf } else { "None" }
    Write-Host "  $($_.Name): $($_.PowerState) | $($nic.NetworkName) | $iso"
}

Write-Host @"

===============================================================================
  NEXT STEPS
===============================================================================

  1. Access VM consoles via vSphere Client or ESXi Host UI
  2. Complete RHEL installation from ISO (boot from CD)
  3. Configure networking (DHCP on LAN)
  4. Run Ansible onboarding playbooks

  To destroy: ./destroy-airgap-lab.ps1

===============================================================================

"@

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
