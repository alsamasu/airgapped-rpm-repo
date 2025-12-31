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

.EXAMPLE
    .\install-deps.ps1 -Force
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

    # Create module path if it doesn't exist
    if (-not (Test-Path $modulePath)) {
        New-Item -ItemType Directory -Force -Path $modulePath | Out-Null
        Write-Log "Created module directory: $modulePath"
    }

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
