<#
.SYNOPSIS
    Generate kickstart ISO files for automated RHEL installation.

.DESCRIPTION
    Creates bootable ISO images containing kickstart configuration files
    for the external and internal RPM servers. These ISOs are mounted
    as a second CD-ROM drive during VM creation.

    The kickstart files are generated from templates based on spec.yaml.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER OutputDir
    Directory where ISO files will be created.

.PARAMETER VMType
    Type of VM: 'external', 'internal', or 'all' (default).

.EXAMPLE
    ./generate-ks-iso.ps1 -OutputDir ./output

.NOTES
    Requires: mkisofs/genisoimage (Linux) or oscdimg (Windows)
    On Windows, install Windows ADK for oscdimg.
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [string]$OutputDir = (Join-Path $PSScriptRoot "../../output/ks-isos"),
    [ValidateSet("external", "internal", "all")]
    [string]$VMType = "all"
)

$ErrorActionPreference = "Stop"

# Load configuration
Write-Host "Loading configuration from $SpecPath..." -ForegroundColor Cyan
$config = & (Join-Path $PSScriptRoot "Read-SpecConfig.ps1") -SpecPath $SpecPath

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Template paths
$TemplateDir = Join-Path $PSScriptRoot "../kickstart"
$KsFilesDir = Join-Path $TemplateDir "ks-files"

# Staging directory for ISO contents
$StagingBase = Join-Path $OutputDir "staging"

function New-KickstartFile {
    param(
        [string]$VMType,
        [hashtable]$Config,
        [string]$OutputPath
    )
    
    $templatePath = Join-Path $TemplateDir "rhel96_${VMType}.ks"
    if (-not (Test-Path $templatePath)) {
        Write-Error "Kickstart template not found: $templatePath"
        return $false
    }
    
    $template = Get-Content -Path $templatePath -Raw
    
    # Replace placeholders
    $hostname = if ($VMType -eq "external") { 
        $Config.vm_names.rpm_external 
    } else { 
        $Config.vm_names.rpm_internal 
    }
    
    $template = $template -replace '{{HOSTNAME}}', $hostname
    $template = $template -replace '{{ROOT_PASSWORD}}', $Config.credentials.initial_root_password
    $template = $template -replace '{{ADMIN_USER}}', $Config.credentials.initial_admin_user
    $template = $template -replace '{{ADMIN_PASSWORD}}', $Config.credentials.initial_admin_password
    $template = $template -replace '{{SERVICE_USER}}', $Config.internal_services.service_user
    $template = $template -replace '{{DATA_DIR}}', $Config.internal_services.data_dir
    $template = $template -replace '{{CERTS_DIR}}', $Config.internal_services.certs_dir
    $template = $template -replace '{{ANSIBLE_DIR}}', $Config.internal_services.ansible_dir
    $template = $template -replace '{{HTTPS_PORT}}', $Config.https_internal_repo.https_port
    $template = $template -replace '{{HTTP_PORT}}', $Config.https_internal_repo.http_port
    
    # FIPS mode
    $fipsEnabled = if ($Config.compliance -and $Config.compliance.enable_fips) { "true" } else { "false" }
    $template = $template -replace '{{FIPS_ENABLED}}', $fipsEnabled
    
    # Write output
    Set-Content -Path $OutputPath -Value $template -NoNewline
    return $true
}

function New-KickstartISO {
    param(
        [string]$VMType,
        [string]$StagingDir,
        [string]$OutputPath
    )
    
    Write-Host "Creating ISO for $VMType..." -ForegroundColor Yellow
    
    # Determine ISO creation tool
    $runningOnWindows = $PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows
    if (-not $runningOnWindows) {
        $runningOnWindows = $env:OS -eq "Windows_NT"
    }

    if ($runningOnWindows) {
        # Try oscdimg from Windows ADK
        $oscdimg = Get-Command oscdimg -ErrorAction SilentlyContinue
        if (-not $oscdimg) {
            # Check common installation paths
            $adkPaths = @(
                "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
                "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
            )
            foreach ($path in $adkPaths) {
                if (Test-Path $path) {
                    $oscdimg = $path
                    break
                }
            }
        }
        
        if ($oscdimg) {
            $oscdimgPath = if ($oscdimg -is [System.Management.Automation.CommandInfo]) { $oscdimg.Source } else { $oscdimg }
            & $oscdimgPath -l"OEMDRV" -o -m "$StagingDir" "$OutputPath"
            if ($LASTEXITCODE -ne 0) {
                Write-Error "oscdimg failed with exit code $LASTEXITCODE"
                return $false
            }
        } else {
            Write-Warning "oscdimg not found. Install Windows ADK or use mkisofs/genisoimage."
            Write-Warning "Attempting PowerShell ISO creation..."
            
            # Fallback: Create a basic ISO using .NET
            # This is a simplified version and may not work for all cases
            $isoCreated = New-BasicISO -SourceDir $StagingDir -OutputPath $OutputPath -VolumeName "OEMDRV"
            if (-not $isoCreated) {
                return $false
            }
        }
    } else {
        # Linux: use genisoimage or mkisofs
        $mkisofs = Get-Command genisoimage -ErrorAction SilentlyContinue
        if (-not $mkisofs) {
            $mkisofs = Get-Command mkisofs -ErrorAction SilentlyContinue
        }
        
        if (-not $mkisofs) {
            Write-Error "Neither genisoimage nor mkisofs found. Install with: dnf install genisoimage"
            return $false
        }
        
        & $mkisofs.Source -o "$OutputPath" -V "OEMDRV" -R -J "$StagingDir"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "mkisofs failed with exit code $LASTEXITCODE"
            return $false
        }
    }
    
    Write-Host "  Created: $OutputPath" -ForegroundColor Green
    return $true
}

function New-BasicISO {
    param(
        [string]$SourceDir,
        [string]$OutputPath,
        [string]$VolumeName
    )
    
    # This is a fallback that creates a simple ISO
    # For production use, oscdimg or mkisofs is recommended
    
    try {
        Add-Type -AssemblyName System.IO
        
        # Get all files in source directory
        $files = Get-ChildItem -Path $SourceDir -Recurse -File
        
        # Create ISO header and file system
        # This is a simplified ISO9660 implementation
        $isoBytes = [System.Collections.Generic.List[byte]]::new()
        
        # System area (32KB of zeros)
        $isoBytes.AddRange([byte[]]::new(32768))
        
        # Primary Volume Descriptor
        $pvd = [byte[]]::new(2048)
        $pvd[0] = 1  # Type: Primary
        [System.Text.Encoding]::ASCII.GetBytes("CD001").CopyTo($pvd, 1)  # Standard ID
        $pvd[6] = 1  # Version
        
        # Volume identifier
        $volId = $VolumeName.PadRight(32, ' ').Substring(0, 32)
        [System.Text.Encoding]::ASCII.GetBytes($volId).CopyTo($pvd, 40)
        
        $isoBytes.AddRange($pvd)
        
        # Volume Descriptor Set Terminator
        $vdst = [byte[]]::new(2048)
        $vdst[0] = 255  # Type: Terminator
        [System.Text.Encoding]::ASCII.GetBytes("CD001").CopyTo($vdst, 1)
        $vdst[6] = 1
        $isoBytes.AddRange($vdst)
        
        # For a proper implementation, we'd need to add:
        # - Path tables
        # - Directory records
        # - File data
        
        # This basic version won't work for actual use
        # Prompt user to install proper tools
        Write-Warning "Basic ISO creation not fully implemented. Please install oscdimg or genisoimage."
        return $false
        
    } catch {
        Write-Error "Failed to create ISO: $_"
        return $false
    }
}

# Process VM types
$vmTypes = if ($VMType -eq "all") { @("external", "internal") } else { @($VMType) }

$success = $true
foreach ($type in $vmTypes) {
    Write-Host "`nProcessing $type VM..." -ForegroundColor Cyan
    
    # Create staging directory
    $stagingDir = Join-Path $StagingBase $type
    if (Test-Path $stagingDir) {
        Remove-Item -Path $stagingDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    
    # Generate kickstart file
    $ksPath = Join-Path $stagingDir "ks.cfg"
    Write-Host "  Generating kickstart file..." -ForegroundColor Yellow
    $ksResult = New-KickstartFile -VMType $type -Config $config -OutputPath $ksPath
    if (-not $ksResult) {
        $success = $false
        continue
    }
    Write-Host "  Created: $ksPath" -ForegroundColor Green
    
    # Copy additional files if they exist
    $additionalFiles = Join-Path $KsFilesDir $type
    if (Test-Path $additionalFiles) {
        Write-Host "  Copying additional files..." -ForegroundColor Yellow
        Copy-Item -Path "$additionalFiles\*" -Destination $stagingDir -Recurse -Force
    }
    
    # Create ISO
    $isoPath = Join-Path $OutputDir "ks-$type.iso"
    $isoResult = New-KickstartISO -VMType $type -StagingDir $stagingDir -OutputPath $isoPath
    if (-not $isoResult) {
        $success = $false
    }
}

# Summary
Write-Host "`n" + "="*60 -ForegroundColor Cyan
if ($success) {
    Write-Host "Kickstart ISOs generated successfully!" -ForegroundColor Green
    Write-Host "`nOutput files:" -ForegroundColor Cyan
    Get-ChildItem -Path $OutputDir -Filter "*.iso" | ForEach-Object {
        Write-Host "  $($_.FullName)" -ForegroundColor White
    }
} else {
    Write-Host "Some ISOs failed to generate. Check errors above." -ForegroundColor Red
    exit 1
}

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. Upload ISOs to datastore: ./upload-isos.ps1" -ForegroundColor White
Write-Host "  2. Deploy VMs: ./deploy-rpm-servers.ps1" -ForegroundColor White
