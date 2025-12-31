<#
.SYNOPSIS
    Validate build-airgapped-deps.ps1 script.

.DESCRIPTION
    Tests the online builder script for:
    - Valid PowerShell syntax
    - Required parameters
    - No forbidden tool references
    - Correct output structure

.EXAMPLE
    .\test-build-script.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "../../scripts/build-airgapped-deps.ps1")
)

$ErrorActionPreference = "Stop"
$errors = @()

Write-Host "=== Build Script Validation Test ===" -ForegroundColor Cyan
Write-Host "Script: $ScriptPath" -ForegroundColor Cyan
Write-Host ""

# Check script exists
if (-not (Test-Path $ScriptPath)) {
    Write-Host "[FAIL] Script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$ScriptPath = Resolve-Path $ScriptPath

# Test 1: Syntax validation
Write-Host "Test 1: PowerShell syntax validation" -ForegroundColor Yellow

try {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref]$null,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -eq 0) {
        Write-Host "  [OK] No syntax errors" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Syntax errors found:" -ForegroundColor Red
        foreach ($err in $parseErrors) {
            Write-Host "    Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Red
        }
        $errors += "Syntax errors in build script"
    }
} catch {
    Write-Host "  [FAIL] Could not parse script: $_" -ForegroundColor Red
    $errors += "Could not parse build script"
}

# Test 2: Required components
Write-Host ""
Write-Host "Test 2: Required components" -ForegroundColor Yellow

$content = Get-Content $ScriptPath -Raw

$requiredComponents = @(
    @{ pattern = 'PowerShell.*MSI'; name = "PowerShell MSI download" },
    @{ pattern = 'VMware\.PowerCLI'; name = "VMware.PowerCLI download" },
    @{ pattern = 'Save-Module'; name = "Save-Module usage" },
    @{ pattern = 'Compress-Archive'; name = "ZIP creation" },
    @{ pattern = 'SHA256|Get-FileHash'; name = "Checksum generation" },
    @{ pattern = 'verify\.ps1'; name = "Verify script generation" },
    @{ pattern = 'install-deps\.ps1'; name = "Install script generation" }
)

foreach ($check in $requiredComponents) {
    if ($content -match $check.pattern) {
        Write-Host "  [OK] $($check.name)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($check.name) not found" -ForegroundColor Red
        $errors += "Missing required component: $($check.name)"
    }
}

# Test 3: Forbidden tools are NOT being downloaded/installed
Write-Host ""
Write-Host "Test 3: Forbidden tool exclusion" -ForegroundColor Yellow

$forbiddenDownloads = @(
    @{ pattern = 'Install-Module.*powershell-yaml'; name = "powershell-yaml" },
    @{ pattern = 'Download.*Python|python.*\.msi|python.*\.exe'; name = "Python" },
    @{ pattern = 'Download.*Git|Git.*\.exe'; name = "Git" },
    @{ pattern = 'Windows.*ADK|WinPE'; name = "Windows ADK" }
)

$hasForbidden = $false
foreach ($check in $forbiddenDownloads) {
    if ($content -match $check.pattern) {
        Write-Host "  [FAIL] Script downloads/installs $($check.name)" -ForegroundColor Red
        $errors += "Forbidden tool in downloads: $($check.name)"
        $hasForbidden = $true
    }
}

if (-not $hasForbidden) {
    Write-Host "  [OK] No forbidden tools in downloads" -ForegroundColor Green
}

# Test 4: FORBIDDEN TOOLS comment present
Write-Host ""
Write-Host "Test 4: Forbidden tools documentation" -ForegroundColor Yellow

if ($content -match 'FORBIDDEN.*TOOLS|MUST NOT') {
    Write-Host "  [OK] Forbidden tools warning present" -ForegroundColor Green
} else {
    Write-Host "  [WARN] No explicit forbidden tools warning" -ForegroundColor Yellow
}

# Test 5: Parameters
Write-Host ""
Write-Host "Test 5: Script parameters" -ForegroundColor Yellow

$expectedParams = @("OutputPath", "WorkDir", "PowerShellVersion", "PowerCLIVersion")
foreach ($param in $expectedParams) {
    if ($content -match "\`$$param") {
        Write-Host "  [OK] Parameter: $param" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Expected parameter not found: $param" -ForegroundColor Yellow
    }
}

# Summary
Write-Host ""
Write-Host "=== Test Summary ===" -ForegroundColor Cyan

if ($errors.Count -eq 0) {
    Write-Host "All tests PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED with $($errors.Count) error(s):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    exit 1
}
