<#
.SYNOPSIS
    Build airgapped-deps.zip for offline Windows 11 operator installation.

.DESCRIPTION
    This script runs on an INTERNET-CONNECTED Windows machine to download
    and package all dependencies required for air-gapped operator deployment.

    Downloads:
    - PowerShell 7.x MSI installer
    - VMware.PowerCLI module and all dependencies

    Produces:
    - airgapped-deps.zip ready for hand-carry to air-gapped environment

.NOTES
    FORBIDDEN TOOLS (must NOT be included):
    - Git
    - Python
    - powershell-yaml
    - Windows ADK / WinPE
    - WSL
    - GNU Make

.EXAMPLE
    .\build-airgapped-deps.ps1 -OutputPath C:\builds\airgapped-deps.zip
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ".\airgapped-deps.zip",

    [Parameter()]
    [string]$WorkDir = ".\airgapped-deps-build",

    [Parameter()]
    [string]$PowerShellVersion = "7.4.6",

    [Parameter()]
    [string]$PowerCLIVersion = "13.3.0"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

Write-Log "=== Airgapped Dependencies Builder ===" -Level SUCCESS
Write-Log "Output: $OutputPath"
Write-Log "Work Directory: $WorkDir"

# Clean and create work directory
if (Test-Path $WorkDir) {
    Write-Log "Cleaning existing work directory..."
    Remove-Item -Recurse -Force $WorkDir
}

$structure = @(
    "$WorkDir",
    "$WorkDir\powershell",
    "$WorkDir\powercli",
    "$WorkDir\powercli\offline-repo",
    "$WorkDir\checksums"
)

foreach ($dir in $structure) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

Write-Log "Created directory structure"

# Download PowerShell 7 MSI
$psUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion/PowerShell-$PowerShellVersion-win-x64.msi"
$psMsi = "$WorkDir\powershell\PowerShell-$PowerShellVersion-win-x64.msi"

Write-Log "Downloading PowerShell $PowerShellVersion MSI..."
try {
    Invoke-WebRequest -Uri $psUrl -OutFile $psMsi -UseBasicParsing
    Write-Log "Downloaded: $psMsi" -Level SUCCESS
} catch {
    Write-Log "Failed to download PowerShell MSI: $_" -Level ERROR
    exit 1
}

# Download VMware.PowerCLI and dependencies
Write-Log "Downloading VMware.PowerCLI $PowerCLIVersion and dependencies..."

# Use Save-Module to get the module and all dependencies
$powerCliPath = "$WorkDir\powercli\offline-repo"

try {
    # Save the module and all its dependencies
    Save-Module -Name VMware.PowerCLI -Path $powerCliPath -Force -Repository PSGallery
    Write-Log "Downloaded VMware.PowerCLI and dependencies" -Level SUCCESS

    # List what was downloaded
    $modules = Get-ChildItem -Path $powerCliPath -Directory
    Write-Log "Downloaded $($modules.Count) module(s):"
    foreach ($mod in $modules) {
        Write-Log "  - $($mod.Name)"
    }
} catch {
    Write-Log "Failed to download VMware.PowerCLI: $_" -Level ERROR
    exit 1
}

# Generate checksums
Write-Log "Generating SHA256 checksums..."
$checksumFile = "$WorkDir\checksums\sha256.txt"
$files = Get-ChildItem -Path $WorkDir -Recurse -File | Where-Object {
    $_.Extension -in @('.msi', '.nupkg', '.psd1', '.psm1', '.dll')
}

$checksums = @()
foreach ($file in $files) {
    $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
    $relativePath = $file.FullName.Replace("$WorkDir\", "").Replace("\", "/")
    $checksums += "$hash  $relativePath"
    Write-Log "  $($file.Name): $hash"
}

$checksums | Out-File -FilePath $checksumFile -Encoding utf8
Write-Log "Checksums written to sha256.txt" -Level SUCCESS

# Create verify.ps1
$verifyScript = @'
<#
.SYNOPSIS
    Verify checksums of airgapped-deps contents.
.DESCRIPTION
    Validates all files against sha256.txt before installation.
#>

param(
    [string]$BasePath = $PSScriptRoot
)

$checksumFile = Join-Path $BasePath "checksums\sha256.txt"
if (-not (Test-Path $checksumFile)) {
    Write-Error "Checksum file not found: $checksumFile"
    exit 1
}

$errors = @()
$verified = 0

Get-Content $checksumFile | ForEach-Object {
    if ($_ -match '^([A-Fa-f0-9]{64})\s+(.+)$') {
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
                $errors += $relativePath
            }
        } else {
            Write-Host "[MISSING] $relativePath" -ForegroundColor Red
            $errors += $relativePath
        }
    }
}

Write-Host ""
Write-Host "Verified: $verified files" -ForegroundColor Cyan

if ($errors.Count -gt 0) {
    Write-Host "Errors: $($errors.Count) files" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All checksums verified successfully." -ForegroundColor Green
    exit 0
}
'@

$verifyScript | Out-File -FilePath "$WorkDir\checksums\verify.ps1" -Encoding utf8
Write-Log "Created verify.ps1"

# Create install-deps.ps1
$installScript = @'
<#
.SYNOPSIS
    Install airgapped dependencies on Windows 11 operator laptop.

.DESCRIPTION
    Offline installer for PowerShell 7 and VMware.PowerCLI.
    Runs without internet access using pre-packaged dependencies.

    FORBIDDEN TOOLS (will NOT be installed):
    - Git
    - Python
    - powershell-yaml
    - Windows ADK / WinPE
    - WSL
    - GNU Make

.NOTES
    Must be run as Administrator for PowerShell MSI installation.
    All actions are logged to install.log in the script directory.

.EXAMPLE
    .\install-deps.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipChecksumVerification,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$BasePath = $PSScriptRoot
$LogFile = Join-Path $BasePath "install.log"

# Logging function
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    # Write to console
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host $logLine -ForegroundColor $color

    # Append to log file
    $logLine | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# Initialize log
"=" * 60 | Out-File -FilePath $LogFile -Encoding utf8
Write-Log "Airgapped Dependencies Installer Started"
Write-Log "Base Path: $BasePath"

# Step 1: Verify checksums
if (-not $SkipChecksumVerification) {
    Write-Log "Verifying checksums..."
    $verifyScript = Join-Path $BasePath "checksums\verify.ps1"

    if (-not (Test-Path $verifyScript)) {
        Write-Log "Checksum verification script not found!" -Level ERROR
        exit 1
    }

    & $verifyScript -BasePath $BasePath
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Checksum verification FAILED - aborting installation" -Level ERROR
        exit 1
    }
    Write-Log "Checksum verification passed" -Level SUCCESS
} else {
    Write-Log "Skipping checksum verification (not recommended)" -Level WARN
}

# Step 2: Check/Install PowerShell 7
Write-Log "Checking PowerShell 7..."

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
$needsPwsh = $false

if ($pwsh) {
    $version = & pwsh -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Log "Found PowerShell: $version"

    # Check if version is 7.x
    if ($version -notmatch '^7\.') {
        $needsPwsh = $true
        Write-Log "PowerShell 7+ required, found $version" -Level WARN
    }
} else {
    $needsPwsh = $true
    Write-Log "PowerShell 7 not found" -Level WARN
}

if ($needsPwsh -or $Force) {
    Write-Log "Installing PowerShell 7..."

    $msiFiles = Get-ChildItem -Path (Join-Path $BasePath "powershell") -Filter "*.msi"
    if ($msiFiles.Count -eq 0) {
        Write-Log "No PowerShell MSI found in powershell\ directory" -Level ERROR
        exit 1
    }

    $msiPath = $msiFiles[0].FullName
    Write-Log "Using MSI: $msiPath"

    # Check for admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "Administrator rights required for MSI installation" -Level ERROR
        Write-Log "Please run this script as Administrator" -Level ERROR
        exit 1
    }

    # Silent install
    $msiArgs = "/i `"$msiPath`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=0 ENABLE_MU=0"
    Write-Log "Running: msiexec $msiArgs"

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($process.ExitCode -eq 0) {
        Write-Log "PowerShell 7 installed successfully" -Level SUCCESS
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log "PowerShell 7 installed - reboot required" -Level WARN
    } else {
        Write-Log "PowerShell 7 installation failed with exit code: $($process.ExitCode)" -Level ERROR
        exit 1
    }
} else {
    Write-Log "PowerShell 7 already installed" -Level SUCCESS
}

# Step 3: Check/Install VMware.PowerCLI
Write-Log "Checking VMware.PowerCLI..."

# Use pwsh if available, otherwise current shell
$checkCmd = {
    $mod = Get-Module -ListAvailable -Name VMware.PowerCLI
    if ($mod) { $mod.Version.ToString() } else { "NOT_FOUND" }
}

$powerCLIVersion = "NOT_FOUND"
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshPath) {
    $powerCLIVersion = & pwsh -Command $checkCmd.ToString()
} else {
    $powerCLIVersion = & $checkCmd
}

$needsPowerCLI = ($powerCLIVersion -eq "NOT_FOUND")

if ($needsPowerCLI -or $Force) {
    Write-Log "Installing VMware.PowerCLI from offline repository..."

    $offlineRepo = Join-Path $BasePath "powercli\offline-repo"
    if (-not (Test-Path $offlineRepo)) {
        Write-Log "Offline repository not found: $offlineRepo" -Level ERROR
        exit 1
    }

    # Determine module install path
    $modulePath = if ($pwshPath) {
        # PowerShell 7 module path
        "$env:ProgramFiles\PowerShell\Modules"
    } else {
        # Windows PowerShell module path
        "$env:ProgramFiles\WindowsPowerShell\Modules"
    }

    Write-Log "Module install path: $modulePath"

    # Copy modules from offline repo
    $moduleCount = 0
    Get-ChildItem -Path $offlineRepo -Directory | ForEach-Object {
        $moduleName = $_.Name
        $destPath = Join-Path $modulePath $moduleName

        Write-Log "  Installing module: $moduleName"
        if (Test-Path $destPath) {
            if ($Force) {
                Remove-Item -Recurse -Force $destPath
            } else {
                Write-Log "    Already exists, skipping (use -Force to overwrite)" -Level WARN
                return
            }
        }

        Copy-Item -Path $_.FullName -Destination $destPath -Recurse -Force
        $moduleCount++
    }

    Write-Log "Installed $moduleCount module(s)" -Level SUCCESS
} else {
    Write-Log "VMware.PowerCLI $powerCLIVersion already installed" -Level SUCCESS
}

# Final verification
Write-Log ""
Write-Log "=== Installation Summary ===" -Level SUCCESS

# Verify PowerShell 7
$pwshCheck = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCheck) {
    $ver = & pwsh -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Log "PowerShell: $ver" -Level SUCCESS
} else {
    Write-Log "PowerShell 7: Not found (may require reboot)" -Level WARN
}

# Verify PowerCLI
if ($pwshCheck) {
    $pcliVer = & pwsh -Command '(Get-Module -ListAvailable VMware.PowerCLI | Select-Object -First 1).Version.ToString()'
    if ($pcliVer) {
        Write-Log "VMware.PowerCLI: $pcliVer" -Level SUCCESS
    } else {
        Write-Log "VMware.PowerCLI: Not found" -Level WARN
    }
}

Write-Log ""
Write-Log "Installation complete. See $LogFile for details."
Write-Log "You may now proceed with: C:\src\airgapped-rpm-repo\scripts\operator.ps1"
'@

$installScript | Out-File -FilePath "$WorkDir\install-deps.ps1" -Encoding utf8
Write-Log "Created install-deps.ps1"

# Create README.md
$readme = @"
# Airgapped Dependencies for Windows 11 Operator

This package contains all dependencies required to run the airgapped RPM
repository operator workflow on a Windows 11 laptop WITHOUT internet access.

## Contents

- ``powershell/`` - PowerShell 7.x MSI installer
- ``powercli/`` - VMware.PowerCLI module and dependencies
- ``checksums/`` - SHA256 verification files
- ``install-deps.ps1`` - Offline installer script

## IMPORTANT: Forbidden Tools

The following tools are NOT included and MUST NOT be installed:
- Git
- Python
- powershell-yaml
- Windows ADK / WinPE
- WSL
- GNU Make

## Installation

1. Extract this ZIP to ``C:\src\airgapped-deps``
2. Open PowerShell **as Administrator**
3. Run:
   ```powershell
   cd C:\src\airgapped-deps
   .\install-deps.ps1
   ```

4. If prompted, reboot and re-run if needed.

## Verification

To verify checksums before installation:
```powershell
.\checksums\verify.ps1
```

## Next Steps

After installation, extract the repository ZIP and run:
```powershell
cd C:\src\airgapped-rpm-repo
.\scripts\operator.ps1 validate-spec
```

## Support

If installation fails, check ``install.log`` in this directory.
"@

$readme | Out-File -FilePath "$WorkDir\README.md" -Encoding utf8
Write-Log "Created README.md"

# Create the ZIP
Write-Log "Creating airgapped-deps.zip..."

if (Test-Path $OutputPath) {
    Remove-Item -Force $OutputPath
}

Compress-Archive -Path "$WorkDir\*" -DestinationPath $OutputPath -Force
Write-Log "Created: $OutputPath" -Level SUCCESS

# Summary
$zipSize = (Get-Item $OutputPath).Length / 1MB
Write-Log ""
Write-Log "=== Build Complete ===" -Level SUCCESS
Write-Log "Output: $OutputPath"
Write-Log "Size: $([math]::Round($zipSize, 2)) MB"
Write-Log ""
Write-Log "Contents:"
Write-Log "  - PowerShell 7 MSI"
Write-Log "  - VMware.PowerCLI + dependencies"
Write-Log "  - Checksum verification"
Write-Log "  - Offline installer"
Write-Log ""
Write-Log "Forbidden tools NOT included: Git, Python, powershell-yaml, ADK, WSL, Make"
