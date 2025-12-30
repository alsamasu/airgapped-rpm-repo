<#
.SYNOPSIS
    Report DHCP IP addresses for RPM server VMs.

.DESCRIPTION
    Queries VMware for guest IP addresses and generates a report
    suitable for updating Ansible inventory and DNS.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER OutputFormat
    Output format: 'table', 'json', 'yaml', 'ansible' (default: table).

.PARAMETER OutputFile
    Optional file path to write the report.

.PARAMETER WaitForIP
    Wait for all VMs to have IP addresses (default: true).

.PARAMETER TimeoutMinutes
    Maximum time to wait for IPs (default: 5).

.EXAMPLE
    ./wait-for-dhcp-and-report.ps1

.EXAMPLE
    ./wait-for-dhcp-and-report.ps1 -OutputFormat ansible -OutputFile ./inventory.yml
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [ValidateSet("table", "json", "yaml", "ansible")]
    [string]$OutputFormat = "table",
    [string]$OutputFile,
    [switch]$WaitForIP = $true,
    [int]$TimeoutMinutes = 5
)

$ErrorActionPreference = "Stop"

# Load configuration
$config = & (Join-Path $PSScriptRoot "Read-SpecConfig.ps1") -SpecPath $SpecPath

$vmNames = @($config.vm_names.rpm_external, $config.vm_names.rpm_internal)

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
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# Collect VM information
$vmInfo = @()
$startTime = Get-Date
$timeoutTime = $startTime.AddMinutes($TimeoutMinutes)

foreach ($vmName in $vmNames) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "VM not found: $vmName"
        continue
    }
    
    $guestIP = $null
    
    if ($WaitForIP) {
        while (-not $guestIP -and (Get-Date) -lt $timeoutTime) {
            $vm = Get-VM -Name $vmName
            $guestIP = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' } | Select-Object -First 1
            
            if (-not $guestIP) {
                Write-Host "Waiting for IP on $vmName..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
        }
    } else {
        $guestIP = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' } | Select-Object -First 1
    }
    
    $info = @{
        Name = $vmName
        PowerState = $vm.PowerState.ToString()
        ToolsStatus = $vm.ExtensionData.Guest.ToolsRunningStatus
        IPAddress = $guestIP
        Hostname = $vm.ExtensionData.Guest.HostName
        GuestOS = $vm.ExtensionData.Guest.GuestFullName
        Type = if ($vmName -eq $config.vm_names.rpm_external) { "external" } else { "internal" }
    }
    
    $vmInfo += [PSCustomObject]$info
}

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

# Generate output
$output = ""

switch ($OutputFormat) {
    "table" {
        Write-Host @"

===============================================================================
  RPM SERVER IP ADDRESSES
===============================================================================

"@ -ForegroundColor Cyan
        
        foreach ($vm in $vmInfo) {
            $statusColor = if ($vm.IPAddress) { "Green" } else { "Yellow" }
            Write-Host "  $($vm.Name)" -ForegroundColor White
            Write-Host "    Type:       $($vm.Type)" -ForegroundColor Gray
            Write-Host "    Power:      $($vm.PowerState)" -ForegroundColor Gray
            Write-Host "    IP Address: $($vm.IPAddress ?? 'Not available')" -ForegroundColor $statusColor
            Write-Host "    Hostname:   $($vm.Hostname ?? 'Not available')" -ForegroundColor Gray
            Write-Host ""
        }
        
        Write-Host @"
===============================================================================
  SSH Access Commands
===============================================================================

"@ -ForegroundColor Cyan
        
        foreach ($vm in $vmInfo) {
            if ($vm.IPAddress) {
                Write-Host "  ssh $($config.credentials.initial_admin_user)@$($vm.IPAddress)  # $($vm.Name)" -ForegroundColor White
            }
        }
        
        Write-Host ""
    }
    
    "json" {
        $output = $vmInfo | ConvertTo-Json -Depth 5
        Write-Host $output
    }
    
    "yaml" {
        # Simple YAML output
        $output = "# RPM Server Information`n"
        $output += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
        $output += "servers:`n"
        foreach ($vm in $vmInfo) {
            $output += "  - name: $($vm.Name)`n"
            $output += "    type: $($vm.Type)`n"
            $output += "    ip_address: $($vm.IPAddress)`n"
            $output += "    hostname: $($vm.Hostname)`n"
            $output += "    power_state: $($vm.PowerState)`n"
        }
        Write-Host $output
    }
    
    "ansible" {
        $external = $vmInfo | Where-Object { $_.Type -eq "external" }
        $internal = $vmInfo | Where-Object { $_.Type -eq "internal" }
        
        $output = @"
# Ansible inventory generated from VMware
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

all:
  vars:
    ansible_user: $($config.credentials.initial_admin_user)
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
    
    internal_repo_host: $($internal.IPAddress)
    internal_repo_https_port: $($config.https_internal_repo.https_port)
    internal_repo_url: "https://$($internal.IPAddress):$($config.https_internal_repo.https_port)"

  children:
    external_servers:
      hosts:
        $($config.vm_names.rpm_external):
          ansible_host: $($external.IPAddress)
          airgap_host_id: rpm-external-01

    internal_servers:
      hosts:
        $($config.vm_names.rpm_internal):
          ansible_host: $($internal.IPAddress)
          airgap_host_id: rpm-internal-01

    rpm_servers:
      children:
        external_servers:
        internal_servers:
"@
        Write-Host $output
    }
}

# Write to file if specified
if ($OutputFile) {
    $output | Out-File -FilePath $OutputFile -Encoding UTF8
    Write-Host "`nOutput written to: $OutputFile" -ForegroundColor Green
}

# Exit with error if any VM is missing an IP
$missingIPs = $vmInfo | Where-Object { -not $_.IPAddress }
if ($missingIPs.Count -gt 0) {
    Write-Warning "Some VMs do not have IP addresses"
    exit 1
}
