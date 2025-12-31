# Airgapped Dependencies for Windows 11 Operator

This package contains all dependencies required to run the airgapped RPM
repository operator workflow on a Windows 11 laptop WITHOUT internet access.

## Contents

- `powershell/` - PowerShell 7.x MSI installer
- `powercli/` - VMware.PowerCLI module and dependencies
- `checksums/` - SHA256 verification files
- `install-deps.ps1` - Offline installer script

## IMPORTANT: Forbidden Tools

The following tools are NOT included and MUST NOT be installed:

- **Git** - Not required; use ZIP-based delivery
- **Python** - Not required; all scripts are PowerShell
- **powershell-yaml** - Not required; native PowerShell YAML parsing
- **Windows ADK / WinPE** - Not required for operator workflow
- **WSL** - Not required; SSH via standard Windows tools
- **GNU Make** - Not required; PowerShell scripts only

## Prerequisites

The operator laptop must have:
- Windows 11 (or Windows 10 with PowerShell 5.1)
- Administrator access (for MSI installation)
- Sufficient disk space (~500MB)

## Installation

1. Extract this ZIP to `C:\src\airgapped-deps`
2. Open PowerShell **as Administrator**
3. Run:
   ```powershell
   cd C:\src\airgapped-deps
   .\install-deps.ps1
   ```

4. If prompted for a reboot, restart and verify installation completed.

## Verification

To verify checksums before installation:
```powershell
.\checksums\verify.ps1
```

## Installation Options

```powershell
# Standard installation (with checksum verification)
.\install-deps.ps1

# Force reinstall all components
.\install-deps.ps1 -Force

# Skip checksum verification (not recommended)
.\install-deps.ps1 -SkipChecksumVerification
```

## After Installation

1. Open a new PowerShell 7 terminal (type `pwsh`)
2. Verify PowerShell version:
   ```powershell
   $PSVersionTable.PSVersion
   ```
3. Verify PowerCLI:
   ```powershell
   Get-Module -ListAvailable VMware.PowerCLI
   ```

## Next Steps

After installation, extract the repository ZIP and run:
```powershell
cd C:\src\airgapped-rpm-repo
.\scripts\operator.ps1 validate-spec
```

## Troubleshooting

### Installation fails
- Ensure you're running as Administrator
- Check `install.log` in this directory for details

### PowerShell 7 not found after install
- A reboot may be required
- Try opening a new terminal

### PowerCLI module not found
- Verify installation path: `$env:ProgramFiles\PowerShell\Modules`
- Try: `Import-Module VMware.PowerCLI -Force`

## Support

If installation fails, check `install.log` in this directory for details.
