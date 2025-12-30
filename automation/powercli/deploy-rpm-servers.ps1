<#
.SYNOPSIS
    Deploy External and Internal RPM servers via VMware.

.DESCRIPTION
    Creates and configures VMs for the airgapped RPM repository system:
    - External RPM Server: Internet-connected, syncs from Red Hat CDN
    - Internal RPM Server: Airgapped, publishes packages to managed hosts
    
    Uses kickstart ISO injection for fully automated OS installation.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER SkipIsoGeneration
    Skip generating kickstart ISOs (use existing ones).

.PARAMETER SkipIsoUpload
    Skip uploading ISOs to datastore.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    ./deploy-rpm-servers.ps1

.EXAMPLE
    ./deploy-rpm-servers.ps1 -Force -SkipIsoGeneration

.NOTES
    Requires: VMware PowerCLI 13.x+, powershell-yaml module
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [switch]$SkipIsoGeneration,
    [switch]$SkipIsoUpload,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# =============================================================================
# Banner
# =============================================================================
Write-Host @"

===============================================================================
  AIRGAPPED RPM REPOSITORY - AUTOMATED SERVER DEPLOYMENT
===============================================================================

  This script will:
  1. Generate kickstart ISOs (unless -SkipIsoGeneration)
  2. Upload ISOs to VMware datastore (unless -SkipIsoUpload)
  3. Create External and Internal RPM server VMs
  4. Mount RHEL ISO + Kickstart ISO to each VM
  5. Power on VMs for automated installation

  Configuration: $SpecPath

===============================================================================

"@ -ForegroundColor Cyan

# =============================================================================
# Load Configuration
# =============================================================================
Write-Host "Loading configuration..." -ForegroundColor Cyan
$config = & (Join-Path $ScriptDir "Read-SpecConfig.ps1") -SpecPath $SpecPath
Write-Host "[OK] Configuration loaded" -ForegroundColor Green

# Display configuration summary
Write-Host @"

  Configuration Summary:
  ----------------------
  vCenter Server:   $($config.vcenter.server)
  Datacenter:       $($config.vcenter.datacenter)
  Cluster:          $($config.vcenter.cluster)
  Datastore:        $($config.vcenter.datastore)
  Network:          $($config.network.portgroup_name)
  
  External VM:      $($config.vm_names.rpm_external)
                    CPU: $($config.vm_sizing.external.cpu), RAM: $($config.vm_sizing.external.memory_gb)GB, Disk: $($config.vm_sizing.external.disk_gb)GB
  
  Internal VM:      $($config.vm_names.rpm_internal)
                    CPU: $($config.vm_sizing.internal.cpu), RAM: $($config.vm_sizing.internal.memory_gb)GB, Disk: $($config.vm_sizing.internal.disk_gb)GB
                    FIPS Mode: $($config.compliance.enable_fips)
                    Service User: $($config.internal_services.service_user)

"@ -ForegroundColor White

# Confirmation
if (-not $Force) {
    $confirm = Read-Host "Proceed with deployment? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# =============================================================================
# Step 1: Generate Kickstart ISOs
# =============================================================================
$OutputDir = Join-Path $ScriptDir "../../output"
$KsIsoDir = Join-Path $OutputDir "ks-isos"

if (-not $SkipIsoGeneration) {
    Write-Host "`n=== Step 1: Generating Kickstart ISOs ===" -ForegroundColor Cyan
    & (Join-Path $ScriptDir "generate-ks-iso.ps1") -SpecPath $SpecPath -OutputDir $KsIsoDir
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to generate kickstart ISOs"
        exit 1
    }
} else {
    Write-Host "`n=== Step 1: Skipping ISO generation (using existing) ===" -ForegroundColor Yellow
}

# Verify ISOs exist
$externalKsIso = Join-Path $KsIsoDir "ks-external.iso"
$internalKsIso = Join-Path $KsIsoDir "ks-internal.iso"

if (-not (Test-Path $externalKsIso) -or -not (Test-Path $internalKsIso)) {
    Write-Error "Kickstart ISOs not found in $KsIsoDir"
    exit 1
}

# =============================================================================
# Step 2: Connect to vCenter/ESXi
# =============================================================================
Write-Host "`n=== Step 2: Connecting to VMware ===" -ForegroundColor Cyan

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

# Configure PowerCLI
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

try {
    $conn = Connect-VIServer -Server $config.vcenter.server -User $vcUser -Password $vcPassword -ErrorAction Stop
    Write-Host "[OK] Connected to $($conn.Name)" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to vCenter: $_"
    exit 1
}

# Get VMware objects
try {
    if ($config.vcenter.datacenter) {
        $datacenter = Get-Datacenter -Name $config.vcenter.datacenter -ErrorAction Stop
    }
    
    if ($config.vcenter.cluster) {
        $cluster = Get-Cluster -Name $config.vcenter.cluster -ErrorAction Stop
        $vmHost = Get-VMHost -Location $cluster | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
    } elseif ($config.vcenter.host) {
        $vmHost = Get-VMHost -Name $config.vcenter.host -ErrorAction Stop
    } else {
        $vmHost = Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
    }
    
    $datastore = Get-Datastore -Name $config.vcenter.datastore -ErrorAction Stop
    
    Write-Host "[OK] VMware objects resolved" -ForegroundColor Green
    Write-Host "     Host: $($vmHost.Name)" -ForegroundColor White
    Write-Host "     Datastore: $($datastore.Name)" -ForegroundColor White
} catch {
    Write-Error "Failed to get VMware objects: $_"
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

# =============================================================================
# Step 3: Upload ISOs to Datastore
# =============================================================================
Write-Host "`n=== Step 3: Uploading ISOs to Datastore ===" -ForegroundColor Cyan

$isoFolder = $config.isos.iso_datastore_folder
$datastorePath = "[$($datastore.Name)] $isoFolder"

if (-not $SkipIsoUpload) {
    # Create ISO folder on datastore if it doesn't exist
    try {
        $dsBrowser = Get-View $datastore.ExtensionData.Browser
        $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
        
        # Check if folder exists
        New-PSDrive -Name ds -Location $datastore -PSProvider VimDatastore -Root "\" -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path "ds:\$isoFolder")) {
            New-Item -Path "ds:\$isoFolder" -ItemType Directory -ErrorAction Stop | Out-Null
            Write-Host "  Created folder: $datastorePath" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not verify/create ISO folder: $_"
    }
    
    # Upload kickstart ISOs
    foreach ($iso in @($externalKsIso, $internalKsIso)) {
        $isoName = Split-Path $iso -Leaf
        Write-Host "  Uploading $isoName..." -ForegroundColor Yellow
        try {
            Copy-DatastoreItem -Item $iso -Destination "ds:\$isoFolder\$isoName" -Force -ErrorAction Stop
            Write-Host "  [OK] Uploaded $isoName" -ForegroundColor Green
        } catch {
            Write-Error "Failed to upload $isoName : $_"
            Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
            exit 1
        }
    }
    
    Remove-PSDrive -Name ds -ErrorAction SilentlyContinue
} else {
    Write-Host "  Skipping ISO upload" -ForegroundColor Yellow
}

# =============================================================================
# Step 4: Check for Existing VMs
# =============================================================================
Write-Host "`n=== Step 4: Checking for Existing VMs ===" -ForegroundColor Cyan

$vmNames = @($config.vm_names.rpm_external, $config.vm_names.rpm_internal)
$existingVMs = @()

foreach ($vmName in $vmNames) {
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        $existingVMs += $vmName
    }
}

if ($existingVMs.Count -gt 0) {
    Write-Host "[WARN] VMs already exist: $($existingVMs -join ', ')" -ForegroundColor Yellow
    Write-Host "       Run destroy-rpm-servers.ps1 first, or use different names." -ForegroundColor Yellow
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "[OK] No conflicts found" -ForegroundColor Green

# =============================================================================
# Step 5: Create VMs
# =============================================================================
Write-Host "`n=== Step 5: Creating Virtual Machines ===" -ForegroundColor Cyan

# VM specifications
$vmSpecs = @(
    @{
        Name = $config.vm_names.rpm_external
        Type = "external"
        NumCpu = $config.vm_sizing.external.cpu
        MemoryGB = $config.vm_sizing.external.memory_gb
        DiskGB = $config.vm_sizing.external.disk_gb
        KsIso = "ks-external.iso"
    },
    @{
        Name = $config.vm_names.rpm_internal
        Type = "internal"
        NumCpu = $config.vm_sizing.internal.cpu
        MemoryGB = $config.vm_sizing.internal.memory_gb
        DiskGB = $config.vm_sizing.internal.disk_gb
        KsIso = "ks-internal.iso"
    }
)

# RHEL ISO path
$rhelIsoPath = $config.isos.rhel96_iso_path
if ($rhelIsoPath -notmatch "^\[") {
    # Local path - assume it's already on datastore
    $rhelIsoPath = "[$($datastore.Name)] $isoFolder/$(Split-Path $rhelIsoPath -Leaf)"
}

$createdVMs = @()

foreach ($spec in $vmSpecs) {
    Write-Host "`n  Creating $($spec.Name)..." -ForegroundColor Yellow
    
    try {
        # Create VM
        $vm = New-VM -Name $spec.Name -VMHost $vmHost -Datastore $datastore `
            -GuestId "rhel9_64Guest" `
            -NumCpu $spec.NumCpu -MemoryGB $spec.MemoryGB -DiskGB $spec.DiskGB `
            -DiskStorageFormat Thin -NetworkName $config.network.portgroup_name `
            -ErrorAction Stop
        
        # Set EFI firmware
        $vmConfig = New-Object VMware.Vim.VirtualMachineConfigSpec
        $vmConfig.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
        
        # Enable Secure Boot (optional, commented out for compatibility)
        # $vmConfig.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
        # $vmConfig.BootOptions.EfiSecureBootEnabled = $true
        
        $vm.ExtensionData.ReconfigVM($vmConfig)
        
        # Add CD/DVD drive 1: RHEL ISO
        Write-Host "    Mounting RHEL ISO..." -ForegroundColor White
        $cdRhel = New-CDDrive -VM $vm -IsoPath $rhelIsoPath -StartConnected -ErrorAction Stop
        
        # Add CD/DVD drive 2: Kickstart ISO
        Write-Host "    Mounting Kickstart ISO..." -ForegroundColor White
        $ksIsoPath = "[$($datastore.Name)] $isoFolder/$($spec.KsIso)"
        $cdKs = New-CDDrive -VM $vm -IsoPath $ksIsoPath -StartConnected -ErrorAction Stop
        
        Write-Host "  [OK] Created $($spec.Name)" -ForegroundColor Green
        $createdVMs += $vm
        
    } catch {
        Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        
        # Rollback
        Write-Host "`n  Rolling back..." -ForegroundColor Yellow
        foreach ($v in $createdVMs) {
            Stop-VM -VM $v -Confirm:$false -Kill -ErrorAction SilentlyContinue | Out-Null
            Remove-VM -VM $v -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
        }
        Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }
}

# =============================================================================
# Step 6: Configure Boot Order and Start VMs
# =============================================================================
Write-Host "`n=== Step 6: Starting VMs ===" -ForegroundColor Cyan

foreach ($vm in $createdVMs) {
    Write-Host "  Starting $($vm.Name)..." -ForegroundColor Yellow
    
    try {
        # Configure boot order (CD first)
        $bootConfig = New-Object VMware.Vim.VirtualMachineConfigSpec
        $bootConfig.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
        $bootConfig.BootOptions.BootDelay = 3000  # 3 second delay
        
        $vm.ExtensionData.ReconfigVM($bootConfig)
        
        # Power on
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Write-Host "  [OK] Started $($vm.Name)" -ForegroundColor Green
        
    } catch {
        Write-Host "  [WARN] Failed to start $($vm.Name): $_" -ForegroundColor Yellow
    }
}

# =============================================================================
# Summary
# =============================================================================
Write-Host @"

===============================================================================
  DEPLOYMENT COMPLETE
===============================================================================

  VMs Created:
"@ -ForegroundColor Green

foreach ($vm in $createdVMs) {
    $vmInfo = Get-VM -Name $vm.Name
    Write-Host "    - $($vm.Name): $($vmInfo.PowerState)" -ForegroundColor White
}

Write-Host @"

  Installation Status:
  --------------------
  The VMs are now booting from the RHEL ISO with kickstart automation.
  Installation typically takes 10-20 minutes.

  Next Steps:
  -----------
  1. Wait for installation:  ./wait-for-install-complete.ps1
  2. Get DHCP IPs:           ./wait-for-dhcp-and-report.ps1
  3. Verify connectivity:    ssh admin@<ip>
  4. Run Ansible onboarding: make ansible-onboard

  Monitor installation via vSphere console if needed.

===============================================================================

"@ -ForegroundColor Cyan

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
