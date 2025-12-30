<#
.SYNOPSIS
    Validate spec.yaml configuration file.

.DESCRIPTION
    Validates the spec.yaml configuration file, checking for required fields,
    optional fields with defaults, password strength, and file existence.

.PARAMETER SpecPath
    Path to the spec.yaml file. Defaults to config/spec.yaml.

.EXAMPLE
    .\validate-spec.ps1
    .\validate-spec.ps1 -SpecPath C:\path\to\spec.yaml

.NOTES
    Exit codes:
      0 - Validation passed
      1 - Validation failed
      2 - File not found or parse error
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml")
)

$ErrorActionPreference = "Stop"

# Colors for console output
function Write-OK { param($Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Missing { param($Message) Write-Host "  [MISSING] $Message" -ForegroundColor Red }
function Write-Warn { param($Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-Default { param($Message) Write-Host "  [DEFAULT] $Message" -ForegroundColor Yellow }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Validating spec.yaml" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Resolve path
try {
    $SpecPath = Resolve-Path $SpecPath -ErrorAction Stop
} catch {
    Write-Host "[FAIL] File not found: $SpecPath" -ForegroundColor Red
    exit 2
}

Write-Host "File: $SpecPath"
Write-Host ""

# Check for powershell-yaml module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "[FAIL] Required module 'powershell-yaml' not found." -ForegroundColor Red
    Write-Host "       Install with: Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
    exit 2
}

Import-Module powershell-yaml -ErrorAction Stop

# Read and parse YAML
try {
    $yamlContent = Get-Content -Path $SpecPath -Raw
    $config = ConvertFrom-Yaml $yamlContent
} catch {
    Write-Host "[FAIL] Failed to parse YAML: $_" -ForegroundColor Red
    exit 2
}

# Validation results
$script:Errors = @()
$script:Warnings = @()

# Helper function to get nested value
function Get-ConfigValue {
    param([string]$Path)

    $parts = $Path.TrimStart('.') -split '\.'
    $value = $config
    foreach ($part in $parts) {
        if ($null -eq $value -or -not ($value -is [hashtable]) -or -not $value.ContainsKey($part)) {
            return $null
        }
        $value = $value[$part]
    }
    return $value
}

# Check required field
function Test-Required {
    param(
        [string]$Path,
        [string]$Description
    )

    $value = Get-ConfigValue -Path $Path

    if ([string]::IsNullOrWhiteSpace($value)) {
        $script:Errors += "$Path: $Description is required"
        Write-Missing $Path
        return $false
    } else {
        Write-OK $Path
        return $true
    }
}

# Check optional field
function Test-Optional {
    param(
        [string]$Path,
        [string]$Description
    )

    $value = Get-ConfigValue -Path $Path

    if ([string]::IsNullOrWhiteSpace($value)) {
        $script:Warnings += "$Path: $Description (using default)"
        Write-Default $Path
    } else {
        Write-OK $Path
    }
}

Write-Host "Checking required fields..."
Write-Host ""

Write-Host "--- vCenter Configuration ---"
Test-Required ".vcenter.server" "vCenter/ESXi server address" | Out-Null
Test-Required ".vcenter.datastore" "Datastore name" | Out-Null
Test-Optional ".vcenter.datacenter" "Datacenter name"
Test-Optional ".vcenter.cluster" "Cluster name"

Write-Host ""
Write-Host "--- ISO Configuration ---"
Test-Required ".isos.rhel96_iso_path" "RHEL 9.6 ISO path" | Out-Null

Write-Host ""
Write-Host "--- VM Names ---"
Test-Required ".vm_names.rpm_external" "External VM name" | Out-Null
Test-Required ".vm_names.rpm_internal" "Internal VM name" | Out-Null

Write-Host ""
Write-Host "--- Credentials ---"
Test-Required ".credentials.initial_root_password" "Initial root password" | Out-Null
Test-Optional ".credentials.initial_admin_user" "Admin username"
Test-Optional ".credentials.initial_admin_password" "Admin password"

Write-Host ""
Write-Host "--- Internal Services ---"
Test-Optional ".internal_services.service_user" "Service user"
Test-Optional ".internal_services.data_dir" "Data directory"

Write-Host ""
Write-Host "--- HTTPS Configuration ---"
Test-Optional ".https_internal_repo.https_port" "HTTPS port"
Test-Optional ".https_internal_repo.http_port" "HTTP port"

Write-Host ""
Write-Host "--- Syslog TLS ---"
Test-Optional ".syslog_tls.target_host" "Syslog target host"
Test-Optional ".syslog_tls.target_port" "Syslog target port"

Write-Host ""
Write-Host "--- Ansible ---"
Test-Optional ".ansible.ssh_username" "SSH username"
Test-Optional ".ansible.ssh_password" "SSH password"

# Validate password strength
Write-Host ""
Write-Host "Checking password requirements..."
$rootPass = Get-ConfigValue ".credentials.initial_root_password"
if ($rootPass -and $rootPass.Length -lt 8) {
    $script:Warnings += "Root password should be at least 8 characters"
    Write-Warn "Root password is short (< 8 chars)"
} else {
    Write-OK "Password length"
}

# Validate ISO path format
Write-Host ""
Write-Host "Checking ISO path..."
$isoPath = Get-ConfigValue ".isos.rhel96_iso_path"
if ($isoPath) {
    if ($isoPath -match '^\[.*\]') {
        Write-OK "ISO path is datastore format"
    } elseif (Test-Path $isoPath -ErrorAction SilentlyContinue) {
        Write-OK "ISO file exists locally"
    } else {
        $script:Warnings += "ISO file not found locally: $isoPath"
        Write-Warn "ISO file not found: $isoPath"
        Write-Host "         (May be on remote system or datastore)" -ForegroundColor Gray
    }
}

# Check syslog CA bundle if syslog is configured
$syslogHost = Get-ConfigValue ".syslog_tls.target_host"
if ($syslogHost) {
    Write-Host ""
    Write-Host "Checking syslog configuration..."
    $caPath = Get-ConfigValue ".syslog_tls.ca_bundle_local_path"
    if ($caPath) {
        if (Test-Path $caPath -ErrorAction SilentlyContinue) {
            Write-OK "Syslog CA bundle exists"
        } else {
            $script:Warnings += "Syslog CA bundle not found: $caPath"
            Write-Warn "Syslog CA bundle not found"
        }
    } else {
        $script:Warnings += "Syslog is configured but CA bundle path is not set"
        Write-Warn "Syslog CA bundle path not configured"
    }
}

# Summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

if ($script:Errors.Count -gt 0) {
    Write-Host "ERRORS ($($script:Errors.Count)):" -ForegroundColor Red
    foreach ($err in $script:Errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    Write-Host ""
}

if ($script:Warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($script:Warnings.Count)):" -ForegroundColor Yellow
    foreach ($warn in $script:Warnings) {
        Write-Host "  - $warn" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($script:Errors.Count -eq 0) {
    Write-Host "Validation PASSED" -ForegroundColor Green
    if ($script:Warnings.Count -gt 0) {
        Write-Host "(with $($script:Warnings.Count) warnings)"
    }
    exit 0
} else {
    Write-Host "Validation FAILED" -ForegroundColor Red
    Write-Host "Fix the errors above before proceeding."
    exit 1
}
