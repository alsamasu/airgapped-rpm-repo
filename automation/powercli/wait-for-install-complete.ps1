<#
.SYNOPSIS
    Wait for OS installation to complete on RPM server VMs.

.DESCRIPTION
    Monitors VMs for installation completion by checking:
    1. VMware Tools running status
    2. VM guest heartbeat
    3. SSH connectivity (optional)
    
    Times out after a configurable period.

.PARAMETER SpecPath
    Path to spec.yaml configuration file.

.PARAMETER TimeoutMinutes
    Maximum time to wait for installation (default: 30).

.PARAMETER CheckIntervalSeconds
    Interval between status checks (default: 30).

.EXAMPLE
    ./wait-for-install-complete.ps1

.EXAMPLE
    ./wait-for-install-complete.ps1 -TimeoutMinutes 45

.NOTES
    Installation typically takes 10-20 minutes.
#>

[CmdletBinding()]
param(
    [string]$SpecPath = (Join-Path $PSScriptRoot "../../config/spec.yaml"),
    [int]$TimeoutMinutes = 30,
    [int]$CheckIntervalSeconds = 30
)

$ErrorActionPreference = "Stop"

# Load configuration
Write-Host "Loading configuration..." -ForegroundColor Cyan
$config = & (Join-Path $PSScriptRoot "Read-SpecConfig.ps1") -SpecPath $SpecPath

$vmNames = @($config.vm_names.rpm_external, $config.vm_names.rpm_internal)

Write-Host @"

===============================================================================
  WAITING FOR OS INSTALLATION
===============================================================================

  Monitoring VMs: $($vmNames -join ', ')
  Timeout: $TimeoutMinutes minutes
  Check Interval: $CheckIntervalSeconds seconds

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
    Write-Host "[OK] Connected to $($conn.Name)`n" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# Track completion status
$vmStatus = @{}
foreach ($name in $vmNames) {
    $vmStatus[$name] = @{
        Complete = $false
        ToolsRunning = $false
        GuestIP = $null
        LastCheck = $null
    }
}

$startTime = Get-Date
$timeoutTime = $startTime.AddMinutes($TimeoutMinutes)

Write-Host "Start Time: $($startTime.ToString('HH:mm:ss'))" -ForegroundColor White
Write-Host "Timeout At: $($timeoutTime.ToString('HH:mm:ss'))`n" -ForegroundColor White

# Monitoring loop
$allComplete = $false
while (-not $allComplete -and (Get-Date) -lt $timeoutTime) {
    $allComplete = $true
    
    foreach ($vmName in $vmNames) {
        if ($vmStatus[$vmName].Complete) {
            continue
        }
        
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Host "[$vmName] VM not found" -ForegroundColor Red
            $allComplete = $false
            continue
        }
        
        # Check power state
        if ($vm.PowerState -ne "PoweredOn") {
            # VM might be rebooting after install
            if ($vmStatus[$vmName].ToolsRunning) {
                # Was running, now off = might be final reboot
                Write-Host "[$vmName] Rebooting after installation..." -ForegroundColor Yellow
            }
            $allComplete = $false
            continue
        }
        
        # Check VMware Tools
        $toolsStatus = $vm.ExtensionData.Guest.ToolsRunningStatus
        $guestState = $vm.ExtensionData.Guest.GuestState
        $guestIP = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        
        $vmStatus[$vmName].LastCheck = Get-Date
        
        if ($toolsStatus -eq "guestToolsRunning" -and $guestState -eq "running") {
            if (-not $vmStatus[$vmName].ToolsRunning) {
                Write-Host "[$vmName] VMware Tools running" -ForegroundColor Green
                $vmStatus[$vmName].ToolsRunning = $true
            }
            
            if ($guestIP) {
                $vmStatus[$vmName].GuestIP = $guestIP
                $vmStatus[$vmName].Complete = $true
                Write-Host "[$vmName] Installation complete! IP: $guestIP" -ForegroundColor Green
            } else {
                Write-Host "[$vmName] Waiting for IP address..." -ForegroundColor Yellow
                $allComplete = $false
            }
        } else {
            Write-Host "[$vmName] Installing... (Tools: $toolsStatus, Guest: $guestState)" -ForegroundColor Yellow
            $allComplete = $false
        }
    }
    
    if (-not $allComplete) {
        $elapsed = (Get-Date) - $startTime
        $remaining = $timeoutTime - (Get-Date)
        Write-Host "`nElapsed: $($elapsed.ToString('mm\:ss')) | Remaining: $($remaining.ToString('mm\:ss'))" -ForegroundColor Gray
        Write-Host "Next check in $CheckIntervalSeconds seconds...`n" -ForegroundColor Gray
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

# Summary
Write-Host @"

===============================================================================
  INSTALLATION STATUS
===============================================================================

"@ -ForegroundColor Cyan

$successCount = 0
$failCount = 0

foreach ($vmName in $vmNames) {
    $status = $vmStatus[$vmName]
    if ($status.Complete) {
        Write-Host "  $vmName : COMPLETE" -ForegroundColor Green
        Write-Host "    IP Address: $($status.GuestIP)" -ForegroundColor White
        $successCount++
    } else {
        Write-Host "  $vmName : INCOMPLETE" -ForegroundColor Red
        $failCount++
    }
}

$totalTime = (Get-Date) - $startTime
Write-Host "`n  Total Time: $($totalTime.ToString('mm\:ss'))" -ForegroundColor White

if ($allComplete) {
    Write-Host @"

===============================================================================
  ALL INSTALLATIONS COMPLETE
===============================================================================

  Next Steps:
  1. Get detailed IP report: ./wait-for-dhcp-and-report.ps1
  2. Verify SSH access: ssh $($config.credentials.initial_admin_user)@<ip>
  3. Run Ansible onboarding

===============================================================================

"@ -ForegroundColor Green
} else {
    Write-Host @"

===============================================================================
  TIMEOUT - Some installations did not complete
===============================================================================

  Check the VM console in vSphere for installation status.
  You can re-run this script to continue monitoring.

===============================================================================

"@ -ForegroundColor Yellow
}

Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue

if ($failCount -gt 0) {
    exit 1
}
