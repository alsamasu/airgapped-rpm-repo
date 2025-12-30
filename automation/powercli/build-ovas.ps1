<#
.SYNOPSIS
    Build OVAs from deployed RPM server VMs.

.DESCRIPTION
    Exports the external and internal RPM server VMs as OVAs with:
    - OVF properties for first-boot customization (hostname, network)
    - Checksums for verification
    - Proper metadata

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER OutputDir
    Directory for OVA output files.

.PARAMETER SkipShutdown
    Don't shutdown VMs before export (for testing).

.EXAMPLE
    ./build-ovas.ps1

.NOTES
    Requires: VMware PowerCLI, ovftool (optional for OVF properties)
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [string]$OutputDir = (Join-Path $PSScriptRoot "../../automation/artifacts/ovas"),
    [switch]$SkipShutdown
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

Write-Host @"

===============================================================================
  OVA BUILD - Airgapped RPM Repository
===============================================================================

  Building OVA images for one-touch deployment.

===============================================================================

"@ -ForegroundColor Cyan

# Load configuration
Write-Host "Loading configuration..." -ForegroundColor Cyan
$config = & (Join-Path $ScriptDir "Read-SpecConfig.ps1") -SpecPath $SpecPath

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

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

$vmNames = @(
    @{ Name = $config.vm_names.rpm_external; Type = "external"; Description = "External RPM Server (Internet-connected)" },
    @{ Name = $config.vm_names.rpm_internal; Type = "internal"; Description = "Internal RPM Server (Airgapped)" }
)

$ovaResults = @()

foreach ($vmSpec in $vmNames) {
    Write-Host "`n=== Processing $($vmSpec.Name) ===" -ForegroundColor Cyan
    
    $vm = Get-VM -Name $vmSpec.Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "[SKIP] VM not found: $($vmSpec.Name)" -ForegroundColor Yellow
        continue
    }
    
    # Shutdown VM if running
    if (-not $SkipShutdown -and $vm.PowerState -eq "PoweredOn") {
        Write-Host "  Shutting down VM..." -ForegroundColor Yellow
        Stop-VMGuest -VM $vm -Confirm:$false | Out-Null
        
        # Wait for shutdown
        $timeout = 120
        $elapsed = 0
        while ($vm.PowerState -eq "PoweredOn" -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 5
            $elapsed += 5
            $vm = Get-VM -Name $vmSpec.Name
        }
        
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Host "  Force powering off..." -ForegroundColor Yellow
            Stop-VM -VM $vm -Confirm:$false | Out-Null
            Start-Sleep -Seconds 5
        }
        
        Write-Host "  [OK] VM stopped" -ForegroundColor Green
    }
    
    # Export OVA
    $ovaName = "rpm-$($vmSpec.Type)"
    $ovaPath = Join-Path $OutputDir "$ovaName.ova"
    $ovfPath = Join-Path $OutputDir "$ovaName.ovf"
    
    Write-Host "  Exporting to OVA..." -ForegroundColor Yellow
    
    # Check for ovftool
    $ovftool = Get-Command ovftool -ErrorAction SilentlyContinue
    
    if ($ovftool) {
        # Use ovftool for better OVF property support
        Write-Host "  Using ovftool for export..." -ForegroundColor Gray
        
        # Get VM's moref
        $vmMoRef = $vm.ExtensionData.MoRef.Value
        $vmPath = "vi://$vcUser`:$vcPassword@$($config.vcenter.server)/$($config.vcenter.datacenter)/vm/$($vmSpec.Name)"
        
        # Create OVF properties file
        $ovfPropsPath = Join-Path $OutputDir "$ovaName-ovf-properties.xml"
        
        $ovfProperties = @"
<?xml version="1.0" encoding="UTF-8"?>
<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1"
             xmlns:oe="http://schemas.dmtf.org/ovf/environment/1"
             xmlns:ve="http://www.vmware.com/schema/ovfenv">
  <PropertySection>
    <Property oe:key="hostname" oe:value=""/>
    <Property oe:key="network.mode" oe:value="dhcp"/>
    <Property oe:key="network.ip" oe:value=""/>
    <Property oe:key="network.prefix" oe:value="24"/>
    <Property oe:key="network.gateway" oe:value=""/>
    <Property oe:key="network.dns" oe:value=""/>
  </PropertySection>
</Environment>
"@
        $ovfProperties | Set-Content -Path $ovfPropsPath
        
        # Export using ovftool
        $ovftoolArgs = @(
            "--noSSLVerify",
            "--acceptAllEulas",
            "--name=$ovaName",
            "--annotation=`"$($vmSpec.Description) - Airgapped RPM Repository System`"",
            $vmPath,
            $ovaPath
        )
        
        try {
            & ovftool @ovftoolArgs 2>&1 | Tee-Object -FilePath (Join-Path $OutputDir "$ovaName-export.log")
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Exported via ovftool" -ForegroundColor Green
            } else {
                throw "ovftool failed with exit code $LASTEXITCODE"
            }
        } catch {
            Write-Host "  [WARN] ovftool failed, falling back to PowerCLI" -ForegroundColor Yellow
            $ovftool = $null
        }
    }
    
    if (-not $ovftool) {
        # Use PowerCLI Export-VApp
        Write-Host "  Using PowerCLI Export-VApp..." -ForegroundColor Gray
        
        try {
            Export-VApp -VM $vm -Destination $OutputDir -Format OVA -Force -ErrorAction Stop
            
            # Rename if needed
            $exportedOva = Get-ChildItem -Path $OutputDir -Filter "$($vmSpec.Name)*.ova" | Select-Object -First 1
            if ($exportedOva -and $exportedOva.Name -ne "$ovaName.ova") {
                Move-Item -Path $exportedOva.FullName -Destination $ovaPath -Force
            }
            
            Write-Host "  [OK] Exported via PowerCLI" -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL] Export failed: $_" -ForegroundColor Red
            continue
        }
    }
    
    # Generate checksums
    if (Test-Path $ovaPath) {
        Write-Host "  Generating checksums..." -ForegroundColor Yellow
        
        $sha256 = (Get-FileHash -Path $ovaPath -Algorithm SHA256).Hash.ToLower()
        $sha256Path = "$ovaPath.sha256"
        "$sha256  $(Split-Path $ovaPath -Leaf)" | Set-Content -Path $sha256Path
        
        $fileSize = (Get-Item $ovaPath).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
        
        Write-Host "  [OK] SHA256: $sha256" -ForegroundColor Green
        Write-Host "  [OK] Size: $fileSizeMB MB" -ForegroundColor Green
        
        $ovaResults += @{
            Name = $ovaName
            Type = $vmSpec.Type
            Path = $ovaPath
            Size = $fileSize
            SizeMB = $fileSizeMB
            SHA256 = $sha256
            ChecksumFile = $sha256Path
        }
    }
    
    # Power VM back on if it was running
    if (-not $SkipShutdown) {
        Write-Host "  Powering on VM..." -ForegroundColor Yellow
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Write-Host "  [OK] VM started" -ForegroundColor Green
    }
}

# Generate manifest
$manifestPath = Join-Path $OutputDir "manifest.json"
$manifest = @{
    generated = (Get-Date -Format "o")
    ovas = $ovaResults
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath

Write-Host @"

===============================================================================
  OVA BUILD COMPLETE
===============================================================================

  Output Directory: $OutputDir

  OVAs Generated:
"@ -ForegroundColor Green

foreach ($ova in $ovaResults) {
    Write-Host "    $($ova.Name).ova ($($ova.SizeMB) MB)" -ForegroundColor White
    Write-Host "      SHA256: $($ova.SHA256)" -ForegroundColor Gray
}

Write-Host @"

  Manifest: $manifestPath

  OVF Properties for Deployment:
  ------------------------------
  - hostname:        VM hostname
  - network.mode:    'dhcp' or 'static'
  - network.ip:      IP address (if static)
  - network.prefix:  Network prefix (default: 24)
  - network.gateway: Default gateway (if static)
  - network.dns:     DNS servers (if static)

===============================================================================

"@ -ForegroundColor Cyan

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

# Return results
$ovaResults
