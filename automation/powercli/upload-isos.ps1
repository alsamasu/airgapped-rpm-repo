<#
.SYNOPSIS
    Upload ISO files to VMware datastore.

.DESCRIPTION
    Uploads the RHEL installation ISO and kickstart ISOs to the
    configured VMware datastore.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER RhelIsoPath
    Path to RHEL 9.6 ISO file (overrides spec.yaml).

.PARAMETER KsIsoDir
    Directory containing kickstart ISOs.

.PARAMETER SkipRhelIso
    Skip uploading RHEL ISO (already on datastore).

.EXAMPLE
    ./upload-isos.ps1

.EXAMPLE
    ./upload-isos.ps1 -SkipRhelIso
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [string]$RhelIsoPath,
    [string]$KsIsoDir = (Join-Path $PSScriptRoot "../../output/ks-isos"),
    [switch]$SkipRhelIso
)

$ErrorActionPreference = "Stop"

# Load configuration
Write-Host "Loading configuration..." -ForegroundColor Cyan
$config = & (Join-Path $PSScriptRoot "Read-SpecConfig.ps1") -SpecPath $SpecPath

if (-not $RhelIsoPath) {
    $RhelIsoPath = $config.isos.rhel96_iso_path
}

Write-Host @"

===============================================================================
  UPLOAD ISOs TO DATASTORE
===============================================================================

  Datastore: $($config.vcenter.datastore)
  ISO Folder: $($config.isos.iso_datastore_folder)
  
  RHEL ISO: $RhelIsoPath
  KS ISOs:  $KsIsoDir

===============================================================================

"@ -ForegroundColor Cyan

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

# Connect
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

try {
    $conn = Connect-VIServer -Server $config.vcenter.server -User $vcUser -Password $vcPassword -ErrorAction Stop
    Write-Host "[OK] Connected to $($conn.Name)" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# Get datastore
$datastore = Get-Datastore -Name $config.vcenter.datastore -ErrorAction Stop
$isoFolder = $config.isos.iso_datastore_folder

# Create PSDrive for datastore access
New-PSDrive -Name ds -Location $datastore -PSProvider VimDatastore -Root "\" -ErrorAction SilentlyContinue | Out-Null

# Create ISO folder if needed
if (-not (Test-Path "ds:\$isoFolder")) {
    Write-Host "Creating ISO folder on datastore..." -ForegroundColor Yellow
    New-Item -Path "ds:\$isoFolder" -ItemType Directory | Out-Null
    Write-Host "[OK] Created folder" -ForegroundColor Green
}

# Upload RHEL ISO
if (-not $SkipRhelIso) {
    if ($RhelIsoPath -match "^\[") {
        Write-Host "RHEL ISO path is already a datastore path, skipping upload" -ForegroundColor Yellow
    } elseif (Test-Path $RhelIsoPath) {
        $isoName = Split-Path $RhelIsoPath -Leaf
        Write-Host "Uploading RHEL ISO ($isoName)..." -ForegroundColor Yellow
        Write-Host "  This may take several minutes for large files..." -ForegroundColor Gray
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Copy-DatastoreItem -Item $RhelIsoPath -Destination "ds:\$isoFolder\$isoName" -Force
        $sw.Stop()
        
        Write-Host "[OK] Uploaded in $($sw.Elapsed.ToString('mm\:ss'))" -ForegroundColor Green
    } else {
        Write-Warning "RHEL ISO not found: $RhelIsoPath"
    }
} else {
    Write-Host "Skipping RHEL ISO upload" -ForegroundColor Yellow
}

# Upload kickstart ISOs
if (Test-Path $KsIsoDir) {
    $ksIsos = Get-ChildItem -Path $KsIsoDir -Filter "*.iso"
    foreach ($iso in $ksIsos) {
        Write-Host "Uploading $($iso.Name)..." -ForegroundColor Yellow
        Copy-DatastoreItem -Item $iso.FullName -Destination "ds:\$isoFolder\$($iso.Name)" -Force
        Write-Host "[OK] Uploaded $($iso.Name)" -ForegroundColor Green
    }
} else {
    Write-Warning "Kickstart ISO directory not found: $KsIsoDir"
    Write-Host "Run generate-ks-iso.ps1 first" -ForegroundColor Yellow
}

# List uploaded files
Write-Host "`n=== Datastore Contents ===" -ForegroundColor Cyan
Get-ChildItem -Path "ds:\$isoFolder" | ForEach-Object {
    $sizeMB = [math]::Round($_.Length / 1MB, 2)
    Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor White
}

Remove-PSDrive -Name ds -ErrorAction SilentlyContinue
Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "`n[OK] ISO upload complete" -ForegroundColor Green
