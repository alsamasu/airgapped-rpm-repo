<#
.SYNOPSIS
    Verify checksums of airgapped-deps contents.

.DESCRIPTION
    Validates all files against sha256.txt before installation.
    This script must be run from the airgapped-deps root directory.

.PARAMETER BasePath
    Base path to verify files from. Defaults to parent directory of checksums folder.

.EXAMPLE
    .\verify.ps1

.EXAMPLE
    .\verify.ps1 -BasePath C:\src\airgapped-deps
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BasePath = (Split-Path -Parent $PSScriptRoot)
)

$checksumFile = Join-Path $PSScriptRoot "sha256.txt"
if (-not (Test-Path $checksumFile)) {
    Write-Error "Checksum file not found: $checksumFile"
    exit 1
}

Write-Host "Verifying checksums from: $checksumFile" -ForegroundColor Cyan
Write-Host "Base path: $BasePath" -ForegroundColor Cyan
Write-Host ""

$errors = @()
$verified = 0
$total = 0

Get-Content $checksumFile | ForEach-Object {
    if ($_ -match '^([A-Fa-f0-9]{64})\s+(.+)$') {
        $total++
        $expectedHash = $Matches[1]
        $relativePath = $Matches[2]
        $fullPath = Join-Path $BasePath $relativePath

        if (Test-Path $fullPath) {
            $actualHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
            if ($actualHash -eq $expectedHash) {
                Write-Host "[OK] $relativePath" -ForegroundColor Green
                $verified++
            } else {
                Write-Host "[FAIL] $relativePath - hash mismatch" -ForegroundColor Red
                Write-Host "       Expected: $expectedHash" -ForegroundColor Red
                Write-Host "       Actual:   $actualHash" -ForegroundColor Red
                $errors += $relativePath
            }
        } else {
            Write-Host "[MISSING] $relativePath" -ForegroundColor Red
            $errors += $relativePath
        }
    }
}

Write-Host ""
Write-Host "=" * 50 -ForegroundColor Cyan
Write-Host "Verified: $verified / $total files" -ForegroundColor Cyan

if ($errors.Count -gt 0) {
    Write-Host "Errors: $($errors.Count) files" -ForegroundColor Red
    Write-Host ""
    Write-Host "VERIFICATION FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All checksums verified successfully." -ForegroundColor Green
    exit 0
}
