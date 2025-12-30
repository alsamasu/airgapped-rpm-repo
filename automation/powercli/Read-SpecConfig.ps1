<#
.SYNOPSIS
    Read and parse the spec.yaml configuration file.

.DESCRIPTION
    Loads the spec.yaml configuration and returns a PowerShell object.
    Validates required fields and provides defaults for optional fields.

.PARAMETER SpecPath
    Path to the spec.yaml file. Defaults to config/spec.yaml.

.OUTPUTS
    PSCustomObject containing the parsed configuration.

.EXAMPLE
    $config = . ./Read-SpecConfig.ps1
    $config.vcenter.server

.NOTES
    Requires: powershell-yaml module (Install-Module powershell-yaml)
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml")
)

$ErrorActionPreference = "Stop"

# Import YAML module
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    exit 1
}
Import-Module powershell-yaml -ErrorAction Stop

# Resolve path
$SpecPath = Resolve-Path $SpecPath -ErrorAction Stop

# Read and parse YAML
$yamlContent = Get-Content -Path $SpecPath -Raw
$config = ConvertFrom-Yaml $yamlContent

# Validate required fields
$requiredFields = @(
    @{ Path = "vcenter.server"; Description = "vCenter/ESXi server address" },
    @{ Path = "vcenter.datastore"; Description = "Datastore name" },
    @{ Path = "isos.rhel96_iso_path"; Description = "RHEL 9.6 ISO path" },
    @{ Path = "credentials.initial_root_password"; Description = "Initial root password" },
    @{ Path = "vm_names.rpm_external"; Description = "External VM name" },
    @{ Path = "vm_names.rpm_internal"; Description = "Internal VM name" }
)

$missingFields = @()
foreach ($field in $requiredFields) {
    $parts = $field.Path -split '\.'
    $value = $config
    foreach ($part in $parts) {
        if ($null -eq $value -or -not $value.ContainsKey($part)) {
            $value = $null
            break
        }
        $value = $value[$part]
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $missingFields += "$($field.Path): $($field.Description)"
    }
}

if ($missingFields.Count -gt 0) {
    Write-Error "Missing required configuration fields:`n$($missingFields -join "`n")"
    exit 1
}

# Apply defaults
if (-not $config.network) { $config.network = @{} }
if (-not $config.network.portgroup_name) { $config.network.portgroup_name = "LAN" }
if (-not $config.network.dhcp) { $config.network.dhcp = $true }

if (-not $config.vm_sizing) { $config.vm_sizing = @{} }
if (-not $config.vm_sizing.external) { $config.vm_sizing.external = @{} }
if (-not $config.vm_sizing.external.cpu) { $config.vm_sizing.external.cpu = 2 }
if (-not $config.vm_sizing.external.memory_gb) { $config.vm_sizing.external.memory_gb = 8 }
if (-not $config.vm_sizing.external.disk_gb) { $config.vm_sizing.external.disk_gb = 200 }

if (-not $config.vm_sizing.internal) { $config.vm_sizing.internal = @{} }
if (-not $config.vm_sizing.internal.cpu) { $config.vm_sizing.internal.cpu = 2 }
if (-not $config.vm_sizing.internal.memory_gb) { $config.vm_sizing.internal.memory_gb = 8 }
if (-not $config.vm_sizing.internal.disk_gb) { $config.vm_sizing.internal.disk_gb = 200 }

if (-not $config.internal_services) { $config.internal_services = @{} }
if (-not $config.internal_services.service_user) { $config.internal_services.service_user = "rpmops" }
if (-not $config.internal_services.data_dir) { $config.internal_services.data_dir = "/srv/airgap/data" }
if (-not $config.internal_services.certs_dir) { $config.internal_services.certs_dir = "/srv/airgap/certs" }
if (-not $config.internal_services.ansible_dir) { $config.internal_services.ansible_dir = "/srv/airgap/ansible" }

if (-not $config.https_internal_repo) { $config.https_internal_repo = @{} }
if (-not $config.https_internal_repo.https_port) { $config.https_internal_repo.https_port = 8443 }
if (-not $config.https_internal_repo.http_port) { $config.https_internal_repo.http_port = 8080 }

if (-not $config.credentials.initial_admin_user) { 
    $config.credentials.initial_admin_user = "admin" 
}

if (-not $config.isos.iso_datastore_folder) {
    $config.isos.iso_datastore_folder = "isos"
}

# Return the config object
return $config
