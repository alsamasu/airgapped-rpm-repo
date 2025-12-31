<#
.SYNOPSIS
    Windows vSphere Operator Test Harness

.DESCRIPTION
    TESTING ONLY - This script runs operator.ps1 commands from a Windows 11 VM
    deployed in vSphere for CI-like validation.

    This is NOT part of the production operator workflow.
    The primary workflow uses a Windows 11 laptop directly.

.PARAMETER VMName
    Name of existing Windows 11 VM to use for testing.
    If not specified, will look for VMs matching "win11-operator-*".

.PARAMETER TemplateVM
    Name of Windows 11 template to clone if no VM exists.

.PARAMETER DeployNew
    Deploy a new VM from template even if existing VMs are found.

.PARAMETER SkipVMDeploy
    Skip VM deployment/selection and run tests locally (for development).

.PARAMETER WaitSeconds
    Seconds to wait after new VM deployment before running tests.
    Default: 180 (3 minutes for Windows boot and SSH availability).

.PARAMETER SSHUser
    SSH username for connecting to the Windows VM.

.PARAMETER SSHKeyPath
    Path to SSH private key for authentication.

.EXAMPLE
    .\run.ps1 -VMName "win11-test-01"

.EXAMPLE
    .\run.ps1 -SkipVMDeploy

.NOTES
    TESTING ONLY - Not for production use.
    Artifacts written to: automation/artifacts/windows-vsphere-test/
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$VMName,
    [string]$TemplateVM = "win11-operator-template",
    [switch]$DeployNew,
    [switch]$SkipVMDeploy,
    [int]$WaitSeconds = 180,
    [string]$SSHUser = "operator",
    [string]$SSHKeyPath
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
$ArtifactsDir = Join-Path $ProjectRoot "automation/artifacts/windows-vsphere-test"

# Ensure artifacts directory exists
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

$LogFile = Join-Path $ArtifactsDir "test-run.log"
$ReportFile = Join-Path $ArtifactsDir "report.json"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

Write-Host @"

================================================================================
  WINDOWS vSPHERE OPERATOR TEST HARNESS
================================================================================

  WARNING: This is a TESTING-ONLY harness for CI-like validation.
           It is NOT part of the production operator workflow.

  Artifacts: $ArtifactsDir

================================================================================

"@ -ForegroundColor Yellow

# Initialize log
Set-Content -Path $LogFile -Value "Windows vSphere Operator Test Harness`nStarted: $(Get-Date -Format 'o')`n"

$testResults = @{
    timestamp = (Get-Date).ToString("o")
    tests = @()
    vm_used = $null
    local_mode = $SkipVMDeploy
}

if ($SkipVMDeploy) {
    Write-Log "Running in local mode (SkipVMDeploy)" -Level WARN
    Write-Log "Tests will run against local operator.ps1" -Level INFO

    # Test 1: operator.ps1 --help
    Write-Log "Test: operator.ps1 -Help" -Level INFO
    try {
        $helpOutput = & pwsh -File (Join-Path $ProjectRoot "scripts/operator.ps1") -Help 2>&1
        if ($LASTEXITCODE -eq 0) {
            $testResults.tests += @{ name = "operator-help"; status = "PASS" }
            Write-Log "  [PASS] operator.ps1 -Help" -Level SUCCESS
        } else {
            $testResults.tests += @{ name = "operator-help"; status = "FAIL"; error = "Exit code: $LASTEXITCODE" }
            Write-Log "  [FAIL] operator.ps1 -Help" -Level ERROR
        }
    } catch {
        $testResults.tests += @{ name = "operator-help"; status = "FAIL"; error = $_.ToString() }
        Write-Log "  [FAIL] operator.ps1 -Help: $_" -Level ERROR
    }

    # Test 2: validate-spec
    Write-Log "Test: operator.ps1 validate-spec" -Level INFO
    try {
        $validateOutput = & pwsh -File (Join-Path $ProjectRoot "scripts/operator.ps1") validate-spec 2>&1
        if ($LASTEXITCODE -eq 0) {
            $testResults.tests += @{ name = "validate-spec"; status = "PASS" }
            Write-Log "  [PASS] validate-spec" -Level SUCCESS
        } else {
            $testResults.tests += @{ name = "validate-spec"; status = "FAIL"; error = "Exit code: $LASTEXITCODE" }
            Write-Log "  [FAIL] validate-spec" -Level ERROR
        }
    } catch {
        $testResults.tests += @{ name = "validate-spec"; status = "FAIL"; error = $_.ToString() }
        Write-Log "  [FAIL] validate-spec: $_" -Level ERROR
    }

    # Test 3: guide-validate
    Write-Log "Test: operator.ps1 guide-validate" -Level INFO
    try {
        $guideOutput = & pwsh -File (Join-Path $ProjectRoot "scripts/operator.ps1") guide-validate 2>&1
        if ($LASTEXITCODE -eq 0) {
            $testResults.tests += @{ name = "guide-validate"; status = "PASS" }
            Write-Log "  [PASS] guide-validate" -Level SUCCESS
        } else {
            $testResults.tests += @{ name = "guide-validate"; status = "FAIL"; error = "Exit code: $LASTEXITCODE" }
            Write-Log "  [FAIL] guide-validate" -Level ERROR
        }
    } catch {
        $testResults.tests += @{ name = "guide-validate"; status = "FAIL"; error = $_.ToString() }
        Write-Log "  [FAIL] guide-validate: $_" -Level ERROR
    }

} else {
    # VM-based testing
    Write-Log "VM-based testing mode" -Level INFO

    # Check for PowerCLI
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        Write-Log "VMware.PowerCLI module required for VM-based testing" -Level ERROR
        exit 1
    }

    Import-Module VMware.PowerCLI -ErrorAction Stop

    # Connect to vCenter
    $specPath = Join-Path $ProjectRoot "config/spec.yaml"
    if (-not (Test-Path $specPath)) {
        Write-Log "spec.yaml not found - cannot determine vCenter connection" -Level ERROR
        exit 1
    }

    Import-Module powershell-yaml
    $spec = Get-Content $specPath -Raw | ConvertFrom-Yaml

    $vcServer = $spec.vcenter.server
    $vcUser = $env:VMWARE_USER
    $vcPassword = $env:VMWARE_PASSWORD

    if (-not $vcUser -or -not $vcPassword) {
        Write-Log "VMWARE_USER and VMWARE_PASSWORD environment variables required" -Level ERROR
        exit 1
    }

    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    Connect-VIServer -Server $vcServer -User $vcUser -Password $vcPassword | Out-Null
    Write-Log "Connected to vCenter: $vcServer" -Level SUCCESS

    # Find or deploy Windows 11 VM
    $targetVM = $null

    if ($VMName) {
        $targetVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $targetVM) {
            Write-Log "VM not found: $VMName" -Level ERROR
            Disconnect-VIServer -Confirm:$false
            exit 1
        }
    } else {
        # Look for existing Windows 11 operator VMs
        $existingVMs = Get-VM -Name "win11-operator-*" -ErrorAction SilentlyContinue
        if ($existingVMs -and -not $DeployNew) {
            $targetVM = $existingVMs | Where-Object { $_.PowerState -eq "PoweredOn" } | Select-Object -First 1
            if (-not $targetVM) {
                $targetVM = $existingVMs | Select-Object -First 1
                Write-Log "Starting VM: $($targetVM.Name)" -Level INFO
                Start-VM -VM $targetVM | Out-Null
            }
        }
    }

    if (-not $targetVM -and $DeployNew) {
        # Deploy from template
        $template = Get-VM -Name $TemplateVM -ErrorAction SilentlyContinue
        if (-not $template) {
            Write-Log "Template VM not found: $TemplateVM" -Level ERROR
            Disconnect-VIServer -Confirm:$false
            exit 1
        }

        $newVMName = "win11-operator-test-$(Get-Date -Format 'yyyyMMddHHmm')"
        Write-Log "Deploying new VM from template: $newVMName" -Level INFO

        $targetVM = New-VM -Name $newVMName -VM $template -Datastore $spec.vcenter.datastore
        Start-VM -VM $targetVM | Out-Null

        Write-Log "Waiting $WaitSeconds seconds for VM to boot..." -Level INFO
        Start-Sleep -Seconds $WaitSeconds
    }

    if (-not $targetVM) {
        Write-Log "No Windows 11 VM available for testing" -Level ERROR
        Disconnect-VIServer -Confirm:$false
        exit 1
    }

    $testResults.vm_used = $targetVM.Name
    Write-Log "Using VM: $($targetVM.Name)" -Level SUCCESS

    # Get VM IP
    $vmIP = ($targetVM | Get-VMGuest).IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if (-not $vmIP) {
        Write-Log "Could not get VM IP address" -Level ERROR
        Disconnect-VIServer -Confirm:$false
        exit 1
    }

    Write-Log "VM IP: $vmIP" -Level INFO

    # Run tests via SSH
    $sshArgs = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=30")
    if ($SSHKeyPath) {
        $sshArgs += @("-i", $SSHKeyPath)
    }

    # Test: operator.ps1 -Help
    Write-Log "Test: operator.ps1 -Help (via SSH)" -Level INFO
    try {
        $result = ssh @sshArgs "${SSHUser}@${vmIP}" "pwsh -File C:\airgapped-rpm-repo\scripts\operator.ps1 -Help"
        if ($LASTEXITCODE -eq 0) {
            $testResults.tests += @{ name = "operator-help-ssh"; status = "PASS" }
            Write-Log "  [PASS] operator.ps1 -Help" -Level SUCCESS
        } else {
            $testResults.tests += @{ name = "operator-help-ssh"; status = "FAIL" }
            Write-Log "  [FAIL] operator.ps1 -Help" -Level ERROR
        }
    } catch {
        $testResults.tests += @{ name = "operator-help-ssh"; status = "FAIL"; error = $_.ToString() }
        Write-Log "  [FAIL] SSH test failed: $_" -Level ERROR
    }

    Disconnect-VIServer -Confirm:$false
}

# Generate summary
$passed = ($testResults.tests | Where-Object { $_.status -eq "PASS" }).Count
$failed = ($testResults.tests | Where-Object { $_.status -eq "FAIL" }).Count
$testResults.summary = @{
    passed = $passed
    failed = $failed
    total = $testResults.tests.Count
}
$testResults.status = if ($failed -eq 0) { "PASS" } else { "FAIL" }

# Write report
$testResults | ConvertTo-Json -Depth 5 | Out-File $ReportFile -Encoding utf8

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  TEST SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed:  $passed" -ForegroundColor Green
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "White" })
Write-Host "  Total:   $($testResults.tests.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  Report:  $ReportFile" -ForegroundColor Cyan
Write-Host "  Log:     $LogFile" -ForegroundColor Cyan
Write-Host ""

if ($failed -gt 0) {
    Write-Host "TEST HARNESS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "TEST HARNESS PASSED" -ForegroundColor Green
    exit 0
}
