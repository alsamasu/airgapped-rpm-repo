<#
.SYNOPSIS
    Discover vSphere environment and generate spec.yaml defaults.

.DESCRIPTION
    Connects to vSphere and discovers:
    - Datacenters, clusters, hosts
    - Datastores (selects largest free space as default)
    - Validates LAN port group exists
    - Produces JSON defaults and a rendered spec template

.PARAMETER Server
    vCenter/ESXi server address. If not provided, reads from spec.yaml or prompts.

.PARAMETER OutputDir
    Directory for output artifacts.

.EXAMPLE
    ./discover-vsphere-defaults.ps1

.OUTPUTS
    automation/artifacts/vsphere-defaults.json
    automation/artifacts/spec.detected.yaml
#>

[CmdletBinding()]
param(
    [string]$Server = $env:VMWARE_SERVER,
    [string]$User = $env:VMWARE_USER,
    [string]$Password = $env:VMWARE_PASSWORD,
    [string]$OutputDir = (Join-Path $PSScriptRoot "../artifacts"),
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml")
)

$ErrorActionPreference = "Stop"

Write-Host @"

===============================================================================
  VSPHERE ENVIRONMENT DISCOVERY
===============================================================================

  Discovering vSphere infrastructure to generate spec.yaml defaults.

===============================================================================

"@ -ForegroundColor Cyan

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Try to read server from existing spec.yaml if not provided
if (-not $Server -and (Test-Path $SpecPath)) {
    try {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue
        $existingSpec = Get-Content $SpecPath -Raw | ConvertFrom-Yaml
        if ($existingSpec.vcenter.server) {
            $Server = $existingSpec.vcenter.server
            Write-Host "Using server from spec.yaml: $Server" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Could not read existing spec.yaml" -ForegroundColor Gray
    }
}

if (-not $Server) {
    Write-Error "No vCenter/ESXi server specified. Set VMWARE_SERVER environment variable or provide -Server parameter."
    exit 1
}

# Get credentials
if (-not $User) {
    $User = Read-Host "vCenter Username"
}
if (-not $Password) {
    $secPassword = Read-Host "vCenter Password" -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPassword)
    )
}

# Configure PowerCLI
Write-Host "Configuring PowerCLI..." -ForegroundColor Cyan
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

# Connect to vSphere
Write-Host "Connecting to $Server..." -ForegroundColor Cyan
try {
    $conn = Connect-VIServer -Server $Server -User $User -Password $Password -ErrorAction Stop
    Write-Host "[OK] Connected to $($conn.Name) ($($conn.ProductLine) $($conn.Version))" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# Initialize discovery results
$discovery = @{
    timestamp = (Get-Date -Format "o")
    server = $Server
    product = $conn.ProductLine
    version = $conn.Version
    datacenters = @()
    clusters = @()
    hosts = @()
    datastores = @()
    networks = @()
    recommended = @{
        datacenter = $null
        cluster = $null
        host = $null
        datastore = $null
        portgroup = $null
        portgroup_exists = $false
    }
}

# Discover datacenters
Write-Host "`n=== Discovering Datacenters ===" -ForegroundColor Cyan
$datacenters = Get-Datacenter
foreach ($dc in $datacenters) {
    Write-Host "  - $($dc.Name)" -ForegroundColor White
    $discovery.datacenters += @{
        name = $dc.Name
        id = $dc.Id
    }
}
if ($datacenters.Count -gt 0) {
    $discovery.recommended.datacenter = $datacenters[0].Name
}

# Discover clusters
Write-Host "`n=== Discovering Clusters ===" -ForegroundColor Cyan
$clusters = Get-Cluster -ErrorAction SilentlyContinue
foreach ($cluster in $clusters) {
    Write-Host "  - $($cluster.Name)" -ForegroundColor White
    $discovery.clusters += @{
        name = $cluster.Name
        id = $cluster.Id
        ha_enabled = $cluster.HAEnabled
        drs_enabled = $cluster.DrsEnabled
    }
}
if ($clusters.Count -gt 0) {
    $discovery.recommended.cluster = $clusters[0].Name
}

# Discover hosts
Write-Host "`n=== Discovering Hosts ===" -ForegroundColor Cyan
$vmHosts = Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" }
foreach ($vmHost in $vmHosts) {
    Write-Host "  - $($vmHost.Name) (State: $($vmHost.ConnectionState))" -ForegroundColor White
    $discovery.hosts += @{
        name = $vmHost.Name
        state = $vmHost.ConnectionState.ToString()
        version = $vmHost.Version
        cpu_total_mhz = $vmHost.CpuTotalMhz
        memory_total_gb = [math]::Round($vmHost.MemoryTotalGB, 2)
    }
}
if ($vmHosts.Count -gt 0 -and -not $discovery.recommended.cluster) {
    $discovery.recommended.host = $vmHosts[0].Name
}

# Discover datastores
Write-Host "`n=== Discovering Datastores ===" -ForegroundColor Cyan
$datastores = Get-Datastore | Sort-Object -Property FreeSpaceGB -Descending
foreach ($ds in $datastores) {
    $freeGB = [math]::Round($ds.FreeSpaceGB, 2)
    $capacityGB = [math]::Round($ds.CapacityGB, 2)
    $pctFree = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1)
    Write-Host "  - $($ds.Name): $freeGB GB free / $capacityGB GB ($pctFree% free)" -ForegroundColor White
    $discovery.datastores += @{
        name = $ds.Name
        type = $ds.Type
        capacity_gb = $capacityGB
        free_gb = $freeGB
        percent_free = $pctFree
    }
}
# Select largest free space
if ($datastores.Count -gt 0) {
    $discovery.recommended.datastore = $datastores[0].Name
    Write-Host "  [Recommended: $($datastores[0].Name) with $([math]::Round($datastores[0].FreeSpaceGB, 0)) GB free]" -ForegroundColor Green
}

# Discover networks and validate LAN
Write-Host "`n=== Discovering Networks ===" -ForegroundColor Cyan
$networks = Get-VirtualPortGroup -ErrorAction SilentlyContinue
$lanFound = $false
foreach ($net in $networks) {
    $isLan = $net.Name -eq "LAN"
    $marker = if ($isLan) { " [TARGET]" } else { "" }
    Write-Host "  - $($net.Name)$marker" -ForegroundColor $(if ($isLan) { "Green" } else { "White" })
    $discovery.networks += @{
        name = $net.Name
        vlan_id = $net.VLanId
        is_lan = $isLan
    }
    if ($isLan) {
        $lanFound = $true
        $discovery.recommended.portgroup = "LAN"
        $discovery.recommended.portgroup_exists = $true
    }
}

# Validate LAN exists
Write-Host "`n=== Validating LAN Port Group ===" -ForegroundColor Cyan
if ($lanFound) {
    Write-Host "[OK] LAN port group exists" -ForegroundColor Green
} else {
    Write-Host "[FAIL] LAN port group NOT FOUND" -ForegroundColor Red
    Write-Host "       Available networks: $($networks.Name -join ', ')" -ForegroundColor Yellow
    # Don't exit, just warn - operator may create it
}

# Write JSON output
$jsonPath = Join-Path $OutputDir "vsphere-defaults.json"
$discovery | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath
Write-Host "`n[OK] Wrote: $jsonPath" -ForegroundColor Green

# Generate spec.detected.yaml
Write-Host "`n=== Generating spec.detected.yaml ===" -ForegroundColor Cyan

$specTemplate = @"
# config/spec.yaml
# Airgapped RPM Repository System - Auto-Discovered Configuration
#
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# vSphere: $($conn.Name) ($($conn.ProductLine) $($conn.Version))
#
# This file was auto-generated by discover-vsphere-defaults.ps1
# Review and modify as needed before deployment.

# =============================================================================
# VMware vCenter/ESXi Connection
# =============================================================================
vcenter:
  server: "$Server"
  datacenter: "$($discovery.recommended.datacenter)"
  cluster: "$($discovery.recommended.cluster)"
  # host: "$($discovery.recommended.host)"  # Use if no cluster
  datastore: "$($discovery.recommended.datastore)"
  folder: ""
  resource_pool: ""

# =============================================================================
# Network Configuration
# =============================================================================
network:
  # Port group for VM network adapters (LAN required for lab)
  portgroup_name: "LAN"
  
  # Network mode: dhcp (lab default) or static (production)
  # For static, additional fields required (see production override section)
  mode: "dhcp"
  
  # Production static network override (uncomment and fill if needed):
  # mode: "static"
  # static:
  #   ip_address: "192.168.1.100"
  #   prefix: 24
  #   gateway: "192.168.1.1"
  #   dns_servers:
  #     - "192.168.1.1"
  #     - "8.8.8.8"

# =============================================================================
# ISO Paths
# =============================================================================
isos:
  # Path to RHEL 9.6 ISO (local path or datastore path)
  rhel96_iso_path: "[$($discovery.recommended.datastore)] isos/rhel-9.6-x86_64-dvd.iso"
  iso_datastore_folder: "isos"

# =============================================================================
# VM Names and Sizing
# =============================================================================
vm_names:
  rpm_external: "rpm-external"
  rpm_internal: "rpm-internal"

vm_sizing:
  external:
    cpu: 2
    memory_gb: 8
    disk_gb: 200
  internal:
    cpu: 2
    memory_gb: 8
    disk_gb: 200

# =============================================================================
# Bootstrap Credentials (CHANGE AFTER DEPLOYMENT!)
# =============================================================================
credentials:
  initial_root_password: "AirgapLab2025!"
  initial_admin_user: "admin"
  initial_admin_password: "AirgapLab2025!"

# =============================================================================
# Internal Server Services
# =============================================================================
internal_services:
  service_user: "rpmops"
  data_dir: "/srv/airgap/data"
  certs_dir: "/srv/airgap/certs"
  ansible_dir: "/srv/airgap/ansible"

# =============================================================================
# HTTPS Repository Configuration
# =============================================================================
https_internal_repo:
  hostname: ""
  https_port: 8443
  http_port: 8080
  self_signed:
    country: "US"
    state: "Virginia"
    locality: "Arlington"
    organization: "Airgap Ops"
    organizational_unit: "Infrastructure"
    common_name: ""
    san_entries: []
    validity_days: 365

# =============================================================================
# Syslog TLS Forwarding (Optional - comment out if not needed)
# =============================================================================
syslog_tls:
  target_host: ""
  target_port: 6514
  ca_bundle_local_path: ""

# =============================================================================
# Ansible Configuration
# =============================================================================
ansible:
  ssh_username: "admin"
  ssh_password: "AirgapLab2025!"
  host_inventory:
    rhel9_hosts: []
    rhel8_hosts: []

# =============================================================================
# Lifecycle Environments
# =============================================================================
lifecycle:
  default_env: "stable"
  environments:
    - "testing"
    - "stable"

# =============================================================================
# Compliance Configuration
# =============================================================================
compliance:
  enable_fips: true
  stig_profile: "xccdf_org.ssgproject.content_profile_stig"
  generate_ckl: true

# =============================================================================
# Manifest Collection
# =============================================================================
manifests:
  output_dir: "./artifacts/manifests"
  include_full_details: true
"@

$specYamlPath = Join-Path $OutputDir "spec.detected.yaml"
$specTemplate | Set-Content -Path $specYamlPath
Write-Host "[OK] Wrote: $specYamlPath" -ForegroundColor Green

# Summary
Write-Host @"

===============================================================================
  DISCOVERY SUMMARY
===============================================================================

  vSphere Server:    $Server
  Product:           $($conn.ProductLine) $($conn.Version)
  
  Recommended Defaults:
  ---------------------
  Datacenter:        $($discovery.recommended.datacenter)
  Cluster:           $($discovery.recommended.cluster)
  Host:              $($discovery.recommended.host)
  Datastore:         $($discovery.recommended.datastore)
  Port Group:        $($discovery.recommended.portgroup) $(if ($lanFound) { "(EXISTS)" } else { "(NOT FOUND)" })
  
  Artifacts:
  ----------
  JSON:              $jsonPath
  Spec Template:     $specYamlPath

  Next Steps:
  -----------
  1. Review spec.detected.yaml
  2. Copy to config/spec.yaml: make spec-init
  3. Validate: make validate-spec
  4. Deploy: make servers-deploy

===============================================================================

"@ -ForegroundColor Cyan

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

# Return success status
if (-not $lanFound) {
    Write-Warning "LAN port group not found. Create it before deployment."
    exit 1
}

exit 0
