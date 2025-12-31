<#
.SYNOPSIS
    Validate airgapped-deps structure and scripts.

.DESCRIPTION
    Tests that all required files exist and are properly formatted.
    Does NOT test actual installation (that requires Windows).

.EXAMPLE
    .\test-structure.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BasePath = (Join-Path $PSScriptRoot "../../airgapped-deps")
)

$ErrorActionPreference = "Stop"
$errors = @()
$warnings = @()

Write-Host "=== Airgapped-Deps Structure Test ===" -ForegroundColor Cyan
Write-Host "Base Path: $BasePath" -ForegroundColor Cyan
Write-Host ""

# Resolve path
$BasePath = Resolve-Path $BasePath -ErrorAction SilentlyContinue
if (-not $BasePath) {
    Write-Host "[FAIL] Base path does not exist" -ForegroundColor Red
    exit 1
}

# Required files
$requiredFiles = @(
    "install-deps.ps1",
    "README.md",
    "checksums/verify.ps1",
    "checksums/sha256.txt"
)

Write-Host "Checking required files..." -ForegroundColor Yellow
foreach ($file in $requiredFiles) {
    $path = Join-Path $BasePath $file
    if (Test-Path $path) {
        Write-Host "  [OK] $file" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $file not found" -ForegroundColor Red
        $errors += "Missing required file: $file"
    }
}

# Required directories
$requiredDirs = @(
    "powershell",
    "powercli",
    "checksums"
)

Write-Host ""
Write-Host "Checking required directories..." -ForegroundColor Yellow
foreach ($dir in $requiredDirs) {
    $path = Join-Path $BasePath $dir
    if (Test-Path $path -PathType Container) {
        Write-Host "  [OK] $dir/" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $dir/ not found" -ForegroundColor Red
        $errors += "Missing required directory: $dir"
    }
}

# Validate install-deps.ps1 syntax
Write-Host ""
Write-Host "Validating PowerShell syntax..." -ForegroundColor Yellow

$psFiles = @(
    "install-deps.ps1",
    "checksums/verify.ps1"
)

foreach ($file in $psFiles) {
    $path = Join-Path $BasePath $file
    if (Test-Path $path) {
        try {
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$null,
                [ref]$parseErrors
            )
            if ($parseErrors.Count -eq 0) {
                Write-Host "  [OK] $file - valid syntax" -ForegroundColor Green
            } else {
                Write-Host "  [FAIL] $file - syntax errors" -ForegroundColor Red
                foreach ($err in $parseErrors) {
                    Write-Host "    $($err.Message)" -ForegroundColor Red
                }
                $errors += "Syntax errors in $file"
            }
        } catch {
            Write-Host "  [WARN] $file - could not parse" -ForegroundColor Yellow
            $warnings += "Could not validate syntax: $file"
        }
    }
}

# Check for forbidden tool references
Write-Host ""
Write-Host "Checking for forbidden tool references..." -ForegroundColor Yellow

$forbiddenPatterns = @(
    @{ pattern = '\bgit\b'; name = "Git" },
    @{ pattern = '\bpython\b'; name = "Python" },
    @{ pattern = '\bpowershell-yaml\b'; name = "powershell-yaml" },
    @{ pattern = '\bWindows ADK\b'; name = "Windows ADK" },
    @{ pattern = '\bWinPE\b'; name = "WinPE" },
    @{ pattern = '\bwsl\b'; name = "WSL" },
    @{ pattern = '\bGNU Make\b'; name = "GNU Make" }
)

$filesToCheck = Get-ChildItem -Path $BasePath -Recurse -Include "*.ps1", "*.md" -File

foreach ($file in $filesToCheck) {
    $content = Get-Content $file.FullName -Raw
    $relativePath = $file.FullName.Replace("$BasePath\", "").Replace("$BasePath/", "")

    foreach ($check in $forbiddenPatterns) {
        # Skip if it's in the "NOT included" or "FORBIDDEN" context
        if ($content -match "(?i)$($check.pattern)" -and
            $content -notmatch "(?i)(NOT included|FORBIDDEN|NOT REQUIRED).*$($check.pattern)" -and
            $content -notmatch "(?i)$($check.pattern).*(NOT included|FORBIDDEN|NOT REQUIRED)") {
            # More refined check - look for actual usage, not just mentions in docs
            if ($relativePath -like "*.ps1") {
                Write-Host "  [WARN] $relativePath references $($check.name)" -ForegroundColor Yellow
                $warnings += "$relativePath may reference $($check.name)"
            }
        }
    }
}

if ($warnings.Count -eq 0) {
    Write-Host "  [OK] No forbidden tool usage detected" -ForegroundColor Green
}

# Summary
Write-Host ""
Write-Host "=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Errors: $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Warnings: $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { "Yellow" } else { "Green" })

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    exit 1
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor Yellow
    foreach ($warn in $warnings) {
        Write-Host "  - $warn" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Structure test PASSED" -ForegroundColor Green
exit 0
