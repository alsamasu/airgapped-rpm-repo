<#
.SYNOPSIS
    Airgapped RPM Repository - Windows Operator Entrypoint

.DESCRIPTION
    Single canonical PowerShell entrypoint for Windows 11 laptop operators.
    Provides subcommands mapping to automation workflows without requiring GNU make.

    Subcommands:
      init-spec       - Discover vSphere and initialize spec.yaml
      validate-spec   - Validate spec.yaml configuration
      deploy-servers  - Deploy External and Internal RPM servers
      report-servers  - Report VM status and DHCP IPs
      destroy-servers - Destroy all deployed VMs
      build-ovas      - Build OVAs from running VMs
      guide-validate  - Validate operator guides against implementation
      e2e             - Run full end-to-end test suite

.PARAMETER Command
    The subcommand to execute.

.PARAMETER SpecPath
    Path to spec.yaml. Defaults to config/spec.yaml.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER KeepVMs
    For e2e: Keep VMs after test completion.

.PARAMETER CleanupExisting
    For deploy-servers: Remove existing VMs before deploying.

.PARAMETER SkipDeploy
    For e2e: Skip VM deployment (use existing VMs).

.PARAMETER Verbose
    Enable verbose output.

.PARAMETER WhatIf
    Show what would be done without executing.

.PARAMETER Help
    Show help information.

.EXAMPLE
    .\operator.ps1 validate-spec

.EXAMPLE
    .\operator.ps1 deploy-servers -Force

.EXAMPLE
    .\operator.ps1 e2e -KeepVMs

.NOTES
    Requires: PowerShell 7+, VMware PowerCLI, powershell-yaml module
    Configuration: config/spec.yaml
    Artifacts: automation/artifacts/operator/
#>

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init-spec", "validate-spec", "deploy-servers", "report-servers",
                 "destroy-servers", "build-ovas", "guide-validate", "e2e", "help", "")]
    [string]$Command = "",

    [Alias("Spec")]
    [string]$SpecPath,

    [switch]$Force,

    [switch]$KeepVMs,

    [switch]$CleanupExisting,

    [switch]$SkipDeploy,

    [switch]$Help
)

# Script setup
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$PowerCLIDir = Join-Path $ProjectRoot "automation/powercli"
$ScriptsDir = Join-Path $ProjectRoot "automation/scripts"
$ArtifactsDir = Join-Path $ProjectRoot "automation/artifacts"
$OperatorArtifacts = Join-Path $ArtifactsDir "operator"

# Default spec path
if (-not $SpecPath) {
    $SpecPath = Join-Path $ProjectRoot "config/spec.yaml"
}

# Ensure artifacts directory exists
if (-not (Test-Path $OperatorArtifacts)) {
    New-Item -ItemType Directory -Path $OperatorArtifacts -Force | Out-Null
}

# Initialize log file
$LogFile = Join-Path $OperatorArtifacts "run.log"
$ReportFile = Join-Path $OperatorArtifacts "report.json"

# Import shared module
$ModulePath = Join-Path $PowerCLIDir "lib/AirgappedRepo.psm1"
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
}

#region Helper Functions

function Write-Banner {
    Write-Host @"

================================================================================
  AIRGAPPED RPM REPOSITORY - OPERATOR CLI
================================================================================
  PowerShell 7+ | Windows 11 Laptop Entrypoint
  Configuration: $SpecPath
  Artifacts:     $OperatorArtifacts
================================================================================

"@ -ForegroundColor Cyan
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "STEP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue

    $color = switch ($Level) {
        "INFO" { "White" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        "STEP" { "Cyan" }
        default { "White" }
    }

    if ($Level -eq "STEP") {
        Write-Host ""
        Write-Host "=== $Message ===" -ForegroundColor $color
    } else {
        Write-Host "[$Level] $Message" -ForegroundColor $color
    }
}

function Write-HelpText {
    Write-Host @"

USAGE:
    .\operator.ps1 <command> [options]

COMMANDS:
    init-spec           Discover vSphere environment and initialize spec.yaml
    validate-spec       Validate spec.yaml configuration
    deploy-servers      Deploy External and Internal RPM servers via kickstart
    report-servers      Report VM status and retrieve DHCP IP addresses
    destroy-servers     Destroy all deployed VMs (with confirmation)
    build-ovas          Export running VMs as OVA appliances
    guide-validate      Validate operator guides against implementation
    e2e                 Run full end-to-end test suite

OPTIONS:
    -SpecPath <path>    Path to spec.yaml (default: config/spec.yaml)
    -Force              Skip confirmation prompts
    -KeepVMs            Keep VMs after e2e test (don't cleanup)
    -CleanupExisting    Remove existing VMs before deploy-servers
    -SkipDeploy         Skip deployment in e2e (use existing VMs)
    -Verbose            Enable verbose output
    -WhatIf             Show what would be done without executing
    -Help               Show this help message

EXAMPLES:
    # Initialize configuration from vSphere discovery
    .\operator.ps1 init-spec

    # Validate configuration
    .\operator.ps1 validate-spec

    # Deploy servers (with confirmation)
    .\operator.ps1 deploy-servers

    # Deploy servers (skip confirmation)
    .\operator.ps1 deploy-servers -Force

    # Run E2E tests and keep VMs for inspection
    .\operator.ps1 e2e -KeepVMs

    # Validate operator guides
    .\operator.ps1 guide-validate

ENVIRONMENT VARIABLES:
    VMWARE_USER         vCenter/ESXi username
    VMWARE_PASSWORD     vCenter/ESXi password

PREREQUISITES:
    - PowerShell 7.0 or later
    - VMware PowerCLI module: Install-Module VMware.PowerCLI -Scope CurrentUser
    - powershell-yaml module: Install-Module powershell-yaml -Scope CurrentUser
    - Windows ADK (for ISO creation): oscdimg.exe
    - Python 3 with PyYAML (for inventory rendering)

"@ -ForegroundColor White
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..." -Level STEP

    $issues = @()

    # PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $issues += "PowerShell 7+ required (current: $($PSVersionTable.PSVersion))"
    } else {
        Write-Log "PowerShell $($PSVersionTable.PSVersion) - OK" -Level SUCCESS
    }

    # powershell-yaml module
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        $issues += "powershell-yaml module not found. Install: Install-Module powershell-yaml -Scope CurrentUser"
    } else {
        Write-Log "powershell-yaml module - OK" -Level SUCCESS
    }

    # VMware PowerCLI (optional for some commands)
    $powerCLI = Get-Module -ListAvailable -Name VMware.PowerCLI
    if ($powerCLI) {
        Write-Log "VMware PowerCLI $($powerCLI.Version) - OK" -Level SUCCESS
    } else {
        Write-Log "VMware PowerCLI not found (required for VMware operations)" -Level WARN
    }

    # Python (for inventory rendering)
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command python -ErrorAction SilentlyContinue
    }
    if ($python) {
        Write-Log "Python found: $($python.Source) - OK" -Level SUCCESS
    } else {
        Write-Log "Python not found (required for inventory rendering)" -Level WARN
    }

    if ($issues.Count -gt 0) {
        Write-Log "Prerequisites check failed:" -Level ERROR
        foreach ($issue in $issues) {
            Write-Log "  - $issue" -Level ERROR
        }
        return $false
    }

    Write-Log "All prerequisites satisfied" -Level SUCCESS
    return $true
}

function Initialize-OperatorRun {
    param([string]$CommandName)

    # Clear previous log for new run
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Set-Content -Path $LogFile -Value "Operator Run Log`n================`nCommand: $CommandName`nStarted: $timestamp`nSpec: $SpecPath`n"

    Write-Banner
    Write-Log "Starting command: $CommandName" -Level INFO
}

function Complete-OperatorRun {
    param(
        [bool]$Success,
        [hashtable]$Results = @{}
    )

    $endTime = Get-Date
    $status = if ($Success) { "SUCCESS" } else { "FAILED" }

    # Write report.json
    $report = @{
        timestamp = $endTime.ToString("o")
        command = $Command
        status = $status
        spec_path = $SpecPath
        results = $Results
    }
    $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportFile -Encoding utf8

    if ($Success) {
        Write-Log "Command completed successfully" -Level SUCCESS
    } else {
        Write-Log "Command failed - see $LogFile for details" -Level ERROR
    }

    Write-Host ""
    Write-Host "Artifacts: $OperatorArtifacts" -ForegroundColor Cyan
    Write-Host ""

    return $Success
}

#endregion

#region Command Implementations

function Invoke-InitSpec {
    <#
    .SYNOPSIS
        Discover vSphere environment and initialize spec.yaml
    #>
    Initialize-OperatorRun -CommandName "init-spec"

    if (-not (Test-Prerequisites)) {
        return Complete-OperatorRun -Success $false
    }

    Write-Log "Discovering vSphere environment..." -Level STEP

    $discoverScript = Join-Path $PowerCLIDir "discover-vsphere-defaults.ps1"
    if (-not (Test-Path $discoverScript)) {
        Write-Log "Discovery script not found: $discoverScript" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    try {
        & $discoverScript -OutputDir $ArtifactsDir

        $detectedSpec = Join-Path $ArtifactsDir "spec.detected.yaml"
        if (Test-Path $detectedSpec) {
            Write-Log "Discovery completed" -Level SUCCESS
            Write-Log "Generated: $detectedSpec" -Level INFO

            # Backup existing spec if present
            if (Test-Path $SpecPath) {
                $backupPath = "$SpecPath.bak"
                Copy-Item $SpecPath $backupPath -Force
                Write-Log "Backed up existing spec to: $backupPath" -Level WARN
            }

            # Copy detected spec
            Copy-Item $detectedSpec $SpecPath -Force
            Write-Log "Initialized: $SpecPath" -Level SUCCESS

            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Yellow
            Write-Host "  1. Review and customize: $SpecPath" -ForegroundColor White
            Write-Host "  2. Validate: .\operator.ps1 validate-spec" -ForegroundColor White
            Write-Host ""

            return Complete-OperatorRun -Success $true -Results @{
                detected_spec = $detectedSpec
                initialized_spec = $SpecPath
            }
        } else {
            Write-Log "Discovery did not produce spec.detected.yaml" -Level ERROR
            return Complete-OperatorRun -Success $false
        }
    } catch {
        Write-Log "Discovery failed: $_" -Level ERROR
        return Complete-OperatorRun -Success $false
    }
}

function Invoke-ValidateSpec {
    <#
    .SYNOPSIS
        Validate spec.yaml configuration
    #>
    Initialize-OperatorRun -CommandName "validate-spec"

    Write-Log "Validating spec.yaml..." -Level STEP

    if (-not (Test-Path $SpecPath)) {
        Write-Log "Spec file not found: $SpecPath" -Level ERROR
        Write-Host ""
        Write-Host "Run 'operator.ps1 init-spec' to initialize configuration." -ForegroundColor Yellow
        return Complete-OperatorRun -Success $false
    }

    $validateScript = Join-Path $PowerCLIDir "validate-spec.ps1"
    if (Test-Path $validateScript) {
        try {
            & $validateScript -SpecPath $SpecPath
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                return Complete-OperatorRun -Success $true -Results @{ validation = "passed" }
            } else {
                return Complete-OperatorRun -Success $false -Results @{ validation = "failed"; exit_code = $exitCode }
            }
        } catch {
            Write-Log "Validation script error: $_" -Level ERROR
            return Complete-OperatorRun -Success $false
        }
    } else {
        # Fallback: basic YAML validation
        Write-Log "Using basic YAML validation (PowerCLI script not found)" -Level WARN

        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $yaml = Get-Content $SpecPath -Raw | ConvertFrom-Yaml

            # Check required fields
            $required = @("vcenter.server", "vcenter.datastore", "vm_names.rpm_external", "vm_names.rpm_internal")
            $missing = @()

            foreach ($field in $required) {
                $parts = $field -split '\.'
                $value = $yaml
                foreach ($part in $parts) {
                    if ($value -and $value.ContainsKey($part)) {
                        $value = $value[$part]
                    } else {
                        $value = $null
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $missing += $field
                }
            }

            if ($missing.Count -gt 0) {
                Write-Log "Missing required fields:" -Level ERROR
                foreach ($m in $missing) {
                    Write-Log "  - $m" -Level ERROR
                }
                return Complete-OperatorRun -Success $false -Results @{ missing_fields = $missing }
            }

            Write-Log "Spec validation passed" -Level SUCCESS
            return Complete-OperatorRun -Success $true -Results @{ validation = "passed" }

        } catch {
            Write-Log "YAML parse error: $_" -Level ERROR
            return Complete-OperatorRun -Success $false
        }
    }
}

function Invoke-DeployServers {
    <#
    .SYNOPSIS
        Deploy External and Internal RPM servers
    #>
    Initialize-OperatorRun -CommandName "deploy-servers"

    if (-not (Test-Prerequisites)) {
        return Complete-OperatorRun -Success $false
    }

    # Validate spec first
    Write-Log "Pre-flight: Validating spec..." -Level STEP
    if (-not (Test-Path $SpecPath)) {
        Write-Log "Spec file not found: $SpecPath" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    # Confirmation
    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ""
        Write-Host "This will deploy VMs to your vSphere environment." -ForegroundColor Yellow
        Write-Host "Configuration: $SpecPath" -ForegroundColor White
        Write-Host ""
        $confirm = Read-Host "Proceed? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Log "Deployment cancelled by user" -Level WARN
            return Complete-OperatorRun -Success $false -Results @{ cancelled = $true }
        }
    }

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would deploy servers using $SpecPath" -Level INFO
        return Complete-OperatorRun -Success $true -Results @{ whatif = $true }
    }

    Write-Log "Deploying servers..." -Level STEP

    $deployScript = Join-Path $PowerCLIDir "deploy-rpm-servers.ps1"
    if (-not (Test-Path $deployScript)) {
        Write-Log "Deploy script not found: $deployScript" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    try {
        $params = @("-SpecPath", $SpecPath)
        if ($Force) { $params += "-Force" }

        & $deployScript @params
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Yellow
            Write-Host "  1. Wait for installation: .\operator.ps1 report-servers" -ForegroundColor White
            Write-Host "  2. Monitor via vSphere console" -ForegroundColor White
            Write-Host ""
            return Complete-OperatorRun -Success $true
        } else {
            return Complete-OperatorRun -Success $false -Results @{ exit_code = $exitCode }
        }
    } catch {
        Write-Log "Deployment failed: $_" -Level ERROR
        return Complete-OperatorRun -Success $false
    }
}

function Invoke-ReportServers {
    <#
    .SYNOPSIS
        Report VM status and DHCP IPs
    #>
    Initialize-OperatorRun -CommandName "report-servers"

    Write-Log "Reporting server status..." -Level STEP

    $reportScript = Join-Path $PowerCLIDir "wait-for-dhcp-and-report.ps1"
    if (-not (Test-Path $reportScript)) {
        Write-Log "Report script not found: $reportScript" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    try {
        $outputFile = Join-Path $OperatorArtifacts "servers.json"
        & $reportScript -SpecPath $SpecPath -WaitForIP:$false -OutputFormat json -OutputFile $outputFile

        if (Test-Path $outputFile) {
            Write-Log "Server report written to: $outputFile" -Level SUCCESS
            $servers = Get-Content $outputFile | ConvertFrom-Json
            return Complete-OperatorRun -Success $true -Results @{ servers = $servers }
        }
        return Complete-OperatorRun -Success $true
    } catch {
        Write-Log "Report failed: $_" -Level ERROR
        return Complete-OperatorRun -Success $false
    }
}

function Invoke-DestroyServers {
    <#
    .SYNOPSIS
        Destroy all deployed VMs
    #>
    Initialize-OperatorRun -CommandName "destroy-servers"

    # Confirmation (always required unless -Force)
    if (-not $Force) {
        Write-Host ""
        Write-Host "WARNING: This will PERMANENTLY DELETE the following VMs:" -ForegroundColor Red
        Write-Host "  - rpm-external" -ForegroundColor Yellow
        Write-Host "  - rpm-internal" -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type 'destroy' to confirm"
        if ($confirm -ne "destroy") {
            Write-Log "Destroy cancelled by user" -Level WARN
            return Complete-OperatorRun -Success $false -Results @{ cancelled = $true }
        }
    }

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would destroy servers" -Level INFO
        return Complete-OperatorRun -Success $true -Results @{ whatif = $true }
    }

    Write-Log "Destroying servers..." -Level STEP

    $destroyScript = Join-Path $PowerCLIDir "destroy-rpm-servers.ps1"
    if (-not (Test-Path $destroyScript)) {
        Write-Log "Destroy script not found: $destroyScript" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    try {
        & $destroyScript -SpecPath $SpecPath -Force
        return Complete-OperatorRun -Success ($LASTEXITCODE -eq 0)
    } catch {
        Write-Log "Destroy failed: $_" -Level ERROR
        return Complete-OperatorRun -Success $false
    }
}

function Invoke-BuildOvas {
    <#
    .SYNOPSIS
        Build OVAs from running VMs
    #>
    Initialize-OperatorRun -CommandName "build-ovas"

    Write-Log "Building OVAs..." -Level STEP

    $buildScript = Join-Path $PowerCLIDir "build-ovas.ps1"
    $ovaDir = Join-Path $ArtifactsDir "ovas"

    if (-not (Test-Path $buildScript)) {
        Write-Log "Build script not found: $buildScript" -Level ERROR
        return Complete-OperatorRun -Success $false
    }

    if ($WhatIfPreference) {
        Write-Log "WhatIf: Would build OVAs to $ovaDir" -Level INFO
        return Complete-OperatorRun -Success $true -Results @{ whatif = $true }
    }

    try {
        & $buildScript -SpecPath $SpecPath -OutputDir $ovaDir
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "OVAs built successfully" -Level SUCCESS
            Write-Log "Output: $ovaDir" -Level INFO
            return Complete-OperatorRun -Success $true -Results @{ output_dir = $ovaDir }
        }
        return Complete-OperatorRun -Success $false -Results @{ exit_code = $exitCode }
    } catch {
        Write-Log "OVA build failed: $_" -Level ERROR
        return Complete-OperatorRun -Success $false
    }
}

function Invoke-GuideValidate {
    <#
    .SYNOPSIS
        Validate operator guides against implementation
    #>
    Initialize-OperatorRun -CommandName "guide-validate"

    Write-Log "Validating operator guides..." -Level STEP

    $validateScript = Join-Path $ScriptsDir "validate-operator-guide.sh"
    $outputDir = Join-Path $ArtifactsDir "guide-validate"

    # Ensure output directory exists
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Check if bash is available (for the shell script)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        # Try using Git Bash on Windows
        $gitBash = "C:\Program Files\Git\bin\bash.exe"
        if (Test-Path $gitBash) {
            $bash = Get-Command $gitBash
        }
    }

    if ($bash -and (Test-Path $validateScript)) {
        try {
            Push-Location $ProjectRoot
            $guides = "docs/deployment_guide.md,docs/administration_guide.md"

            if ($bash.Source -match "Git") {
                # Git Bash - convert paths
                & $bash.Source -c "./automation/scripts/validate-operator-guide.sh --guides '$guides' --spec '$SpecPath' --output-dir '$outputDir'"
            } else {
                # Native bash
                & bash $validateScript --guides $guides --spec $SpecPath --output-dir $outputDir
            }
            $exitCode = $LASTEXITCODE
            Pop-Location

            if ($exitCode -eq 0) {
                Write-Log "Guide validation passed" -Level SUCCESS
                return Complete-OperatorRun -Success $true -Results @{ output_dir = $outputDir }
            } else {
                Write-Log "Guide validation failed" -Level ERROR
                return Complete-OperatorRun -Success $false -Results @{ exit_code = $exitCode; output_dir = $outputDir }
            }
        } catch {
            Pop-Location
            Write-Log "Guide validation error: $_" -Level ERROR
            return Complete-OperatorRun -Success $false
        }
    } else {
        # Fallback: PowerShell-native validation
        Write-Log "Using PowerShell-native guide validation" -Level INFO

        $guides = @(
            (Join-Path $ProjectRoot "docs/deployment_guide.md"),
            (Join-Path $ProjectRoot "docs/administration_guide.md")
        )

        $errors = @()
        $warnings = @()

        foreach ($guide in $guides) {
            if (-not (Test-Path $guide)) {
                $errors += "Guide not found: $guide"
                continue
            }

            Write-Log "Checking: $(Split-Path $guide -Leaf)" -Level INFO

            $content = Get-Content $guide -Raw

            # Check for make targets
            $makeTargets = [regex]::Matches($content, 'make ([a-z][a-z0-9_-]+)')
            $makefile = Join-Path $ProjectRoot "Makefile"

            if (Test-Path $makefile) {
                $makefileContent = Get-Content $makefile -Raw
                foreach ($match in $makeTargets) {
                    $target = $match.Groups[1].Value
                    if ($makefileContent -notmatch "^${target}:" -and $makefileContent -notmatch "`n${target}:") {
                        $errors += "Makefile target not found: $target (in $guide)"
                    }
                }
            }

            # Check for referenced files
            $fileRefs = [regex]::Matches($content, '(automation|config|scripts)/[a-zA-Z0-9_/./-]+\.(ps1|sh|yaml|yml)')
            foreach ($match in $fileRefs) {
                $filePath = Join-Path $ProjectRoot $match.Value
                if (-not (Test-Path $filePath)) {
                    # Check if it's a runtime artifact
                    if ($match.Value -match "artifacts|generated|detected") {
                        $warnings += "Runtime file (may not exist yet): $($match.Value)"
                    } else {
                        $errors += "Referenced file not found: $($match.Value)"
                    }
                }
            }
        }

        # Write report
        $report = @{
            timestamp = (Get-Date).ToString("o")
            status = if ($errors.Count -eq 0) { "PASSED" } else { "FAILED" }
            errors = $errors
            warnings = $warnings
        }
        $report | ConvertTo-Json -Depth 5 | Out-File (Join-Path $outputDir "report.json") -Encoding utf8

        if ($errors.Count -gt 0) {
            Write-Log "Validation errors:" -Level ERROR
            foreach ($err in $errors) {
                Write-Log "  - $err" -Level ERROR
            }
            return Complete-OperatorRun -Success $false -Results @{ errors = $errors; warnings = $warnings }
        }

        if ($warnings.Count -gt 0) {
            foreach ($warn in $warnings) {
                Write-Log "  - $warn" -Level WARN
            }
        }

        Write-Log "Guide validation passed" -Level SUCCESS
        return Complete-OperatorRun -Success $true -Results @{ warnings = $warnings }
    }
}

function Invoke-E2E {
    <#
    .SYNOPSIS
        Run full end-to-end test suite
    #>
    Initialize-OperatorRun -CommandName "e2e"

    if (-not (Test-Prerequisites)) {
        return Complete-OperatorRun -Success $false
    }

    Write-Log "Running E2E test suite..." -Level STEP

    $e2eScript = Join-Path $ScriptsDir "run-e2e-tests.sh"
    $e2eDir = Join-Path $ArtifactsDir "e2e"

    # Ensure output directory
    if (-not (Test-Path $e2eDir)) {
        New-Item -ItemType Directory -Path $e2eDir -Force | Out-Null
    }

    # Check for bash
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        $gitBash = "C:\Program Files\Git\bin\bash.exe"
        if (Test-Path $gitBash) {
            $bash = Get-Command $gitBash
        }
    }

    if ($bash -and (Test-Path $e2eScript)) {
        try {
            Push-Location $ProjectRoot

            $args = @()
            if ($SkipDeploy) { $args += "--skip-deploy" }
            if (-not $KeepVMs) { $args += "--cleanup" }

            if ($bash.Source -match "Git") {
                $argString = $args -join " "
                & $bash.Source -c "./automation/scripts/run-e2e-tests.sh $argString"
            } else {
                & bash $e2eScript @args
            }
            $exitCode = $LASTEXITCODE
            Pop-Location

            if ($exitCode -eq 0) {
                Write-Log "E2E tests passed" -Level SUCCESS
                return Complete-OperatorRun -Success $true -Results @{ output_dir = $e2eDir }
            } else {
                Write-Log "E2E tests failed" -Level ERROR
                return Complete-OperatorRun -Success $false -Results @{ exit_code = $exitCode; output_dir = $e2eDir }
            }
        } catch {
            Pop-Location
            Write-Log "E2E test error: $_" -Level ERROR
            return Complete-OperatorRun -Success $false
        }
    } else {
        # PowerShell-native E2E (simplified)
        Write-Log "Running PowerShell-native E2E tests" -Level INFO

        $testResults = @{
            timestamp = (Get-Date).ToString("o")
            tests = @()
        }

        # Test 1: Spec validation
        Write-Log "Test: Spec validation" -Level INFO
        try {
            $validateScript = Join-Path $PowerCLIDir "validate-spec.ps1"
            if (Test-Path $validateScript) {
                & $validateScript -SpecPath $SpecPath 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $testResults.tests += @{ name = "spec-validation"; status = "PASS" }
                    Write-Log "  [PASS] Spec validation" -Level SUCCESS
                } else {
                    $testResults.tests += @{ name = "spec-validation"; status = "FAIL" }
                    Write-Log "  [FAIL] Spec validation" -Level ERROR
                }
            }
        } catch {
            $testResults.tests += @{ name = "spec-validation"; status = "FAIL"; error = $_.ToString() }
        }

        # Test 2: Guide validation
        Write-Log "Test: Guide validation" -Level INFO
        $guideResult = Invoke-GuideValidate
        if ($guideResult) {
            $testResults.tests += @{ name = "guide-validation"; status = "PASS" }
        } else {
            $testResults.tests += @{ name = "guide-validation"; status = "FAIL" }
        }

        # Summary
        $passed = ($testResults.tests | Where-Object { $_.status -eq "PASS" }).Count
        $failed = ($testResults.tests | Where-Object { $_.status -eq "FAIL" }).Count
        $testResults.summary = @{ passed = $passed; failed = $failed; total = $testResults.tests.Count }
        $testResults.status = if ($failed -eq 0) { "PASS" } else { "FAIL" }

        # Write report
        $testResults | ConvertTo-Json -Depth 5 | Out-File (Join-Path $e2eDir "report.json") -Encoding utf8

        Write-Host ""
        Write-Host "E2E Summary: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

        return Complete-OperatorRun -Success ($failed -eq 0) -Results $testResults
    }
}

#endregion

#region Main Entry Point

# Show help if requested or no command
if ($Help -or [string]::IsNullOrEmpty($Command) -or $Command -eq "help") {
    Write-Banner
    Write-HelpText
    exit 0
}

# Route to command handler
$result = switch ($Command) {
    "init-spec"       { Invoke-InitSpec }
    "validate-spec"   { Invoke-ValidateSpec }
    "deploy-servers"  { Invoke-DeployServers }
    "report-servers"  { Invoke-ReportServers }
    "destroy-servers" { Invoke-DestroyServers }
    "build-ovas"      { Invoke-BuildOvas }
    "guide-validate"  { Invoke-GuideValidate }
    "e2e"             { Invoke-E2E }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Write-HelpText
        exit 1
    }
}

# Exit with appropriate code
if ($result) {
    exit 0
} else {
    exit 1
}

#endregion
