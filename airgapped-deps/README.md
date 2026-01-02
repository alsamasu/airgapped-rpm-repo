# Airgapped Dependencies for Windows 11 Operator

This package contains all dependencies required to run the airgapped RPM
repository operator workflow on a Windows 11 laptop WITHOUT internet access.

## Contents

- `powershell/` - PowerShell 7.x MSI installer
- `powercli/` - VMware.PowerCLI module and dependencies
- `checksums/` - SHA256 verification files
- `install-deps.ps1` - Offline installer script
- `isos/` - Bootable ISOs for RPM server deployment
  - `boot-external.iso` - Boot ISO for rpm-external server (338 MB)
  - `boot-internal.iso` - Boot ISO for rpm-internal server (338 MB)
  - `ks-external.cfg` - Kickstart file (embedded in boot-external.iso)
  - `ks-internal.cfg` - Kickstart file (embedded in boot-internal.iso)

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

## Deploying RPM Servers (rpm-external and rpm-internal)

The ISOs in the `isos/` directory are **REQUIRED** to deploy the rpm-external and
rpm-internal RHEL 9.6 servers. These ISOs contain embedded kickstart configurations
that automate the installation.

### Why Custom Boot ISOs Are Required

RHEL 9.6 does not auto-detect kickstart files from OEMDRV-labeled volumes without
explicit kernel boot parameters. These custom ISOs include:
- RHEL 9.6 kernel and initrd (extracted from DVD)
- Modified GRUB configuration with `inst.ks=hd:LABEL=OEMDRV:/ks.cfg`
- Embedded kickstart file for fully automated installation

### Prerequisites

1. RHEL 9.6 DVD ISO uploaded to vSphere datastore (e.g., `[datastore] isos/rhel-9.6-x86_64-dvd.iso`)
2. Boot ISOs uploaded to vSphere datastore:
   - `[datastore] isos/boot-external.iso`
   - `[datastore] isos/boot-internal.iso`

### Deployment Steps

1. **Upload ISOs to vSphere Datastore**
   ```powershell
   # Connect to vSphere
   Connect-VIServer -Server <vcenter-ip>

   # Create PSDrive for datastore access
   $ds = Get-Datastore -Name "<datastore-name>"
   New-PSDrive -Name ds -Location $ds -PSProvider VimDatastore -Root "\"

   # Upload boot ISOs
   Copy-DatastoreItem -Item "C:\src\airgapped-deps\isos\boot-external.iso" -Destination "ds:\isos\"
   Copy-DatastoreItem -Item "C:\src\airgapped-deps\isos\boot-internal.iso" -Destination "ds:\isos\"
   ```

2. **Create VMs with Dual CD Drives**

   Each VM requires TWO CD drives:
   - **CD Drive 1**: Boot ISO (boot-external.iso or boot-internal.iso)
   - **CD Drive 2**: RHEL 9.6 DVD ISO

   ```powershell
   # Example for rpm-external
   $vm = New-VM -Name "rpm-external" -ResourcePool (Get-ResourcePool) -Datastore $ds `
       -NumCpu 2 -MemoryGB 4 -DiskGB 200 -GuestId "rhel9_64Guest"

   # Add CD drives
   $bootIso = "[$($ds.Name)] isos/boot-external.iso"
   $rhelDvd = "[$($ds.Name)] isos/rhel-9.6-x86_64-dvd.iso"

   New-CDDrive -VM $vm -IsoPath $bootIso -StartConnected:$true
   New-CDDrive -VM $vm -IsoPath $rhelDvd -StartConnected:$true

   # Start VM - installation is fully automated
   Start-VM -VM $vm
   ```

3. **Wait for Installation**

   The kickstart installation takes approximately 10-15 minutes. The VM will:
   - Boot from the boot ISO
   - Load kernel/initrd and find the kickstart file
   - Install RHEL 9.6 from the DVD
   - Configure networking (DHCP), users, and services
   - Reboot automatically when complete

4. **Verify Deployment**
   ```powershell
   # Check VM has IP address (indicates successful installation)
   $vm = Get-VM -Name "rpm-external"
   $vm.Guest.IPAddress

   # SSH to verify
   ssh admin@<ip-address>  # Password: 12qwaszx!@QWASZX
   ```

### Default Credentials

The kickstart files configure these default credentials:
- **root**: `12qwaszx!@QWASZX`
- **admin** (sudo): `12qwaszx!@QWASZX`

### Installed Packages

The RPM servers are pre-configured with:
- httpd (Apache web server)
- createrepo_c (repository metadata tools)
- dnf-utils (repository management)
- python3

### Network Configuration

Both servers use DHCP. After installation, configure static IPs as needed for
your airgapped network environment.

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
