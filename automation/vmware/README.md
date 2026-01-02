# VMware RPM Server Deployment

This directory contains documentation for deploying RHEL 9.6 RPM servers using VMware vSphere.

## Boot ISO Method (Required for RHEL 9.6)

**IMPORTANT**: RHEL 9.6 does NOT auto-detect kickstart files from OEMDRV-labeled volumes
without explicit kernel boot parameters. The traditional two-CD method (RHEL DVD + OEMDRV ISO)
will NOT work for automated installations.

### Solution: Custom Boot ISOs

Pre-built boot ISOs are included in `airgapped-deps.zip`:

| ISO | Purpose | Size |
|-----|---------|------|
| `boot-external.iso` | Boot ISO for rpm-external server | 338 MB |
| `boot-internal.iso` | Boot ISO for rpm-internal server | 338 MB |

These ISOs contain:
- RHEL 9.6 kernel and initrd (extracted from DVD)
- Modified GRUB configuration with `inst.ks=hd:LABEL=OEMDRV:/ks.cfg`
- Embedded kickstart file for fully automated installation

## How It Works

VMware VMs are configured with TWO CD/DVD drives:

1. **CD/DVD #1**: Custom boot ISO (boot-external.iso or boot-internal.iso)
   - Provides bootloader with kickstart parameters
   - Contains kernel, initrd, and embedded kickstart

2. **CD/DVD #2**: Official RHEL 9.6 installation DVD
   - Provides `inst.stage2` (installation image)
   - Provides all RPM packages

### Boot Sequence

1. VM boots from boot ISO (CD #1)
2. GRUB loads with pre-configured `inst.ks=hd:LABEL=OEMDRV:/ks.cfg`
3. Kernel and initrd load from boot ISO
4. Anaconda finds stage2 on RHEL DVD (CD #2) via `inst.stage2=hd:LABEL=RHEL-9-6-0-BaseOS-x86_64`
5. Anaconda finds kickstart on boot ISO (OEMDRV label)
6. Installation proceeds automatically
7. System reboots when complete

## Deployment Steps

### 1. Upload ISOs to Datastore

```powershell
# Connect to vSphere
$cred = Get-Credential
Connect-VIServer -Server <vcenter-ip> -Credential $cred

# Access datastore
$ds = Get-Datastore -Name "<datastore-name>"
New-PSDrive -Name ds -Location $ds -PSProvider VimDatastore -Root "\"

# Upload boot ISOs (from airgapped-deps.zip)
Copy-DatastoreItem -Item "C:\src\airgapped-deps\isos\boot-external.iso" -Destination "ds:\isos\"
Copy-DatastoreItem -Item "C:\src\airgapped-deps\isos\boot-internal.iso" -Destination "ds:\isos\"

# Ensure RHEL DVD is also on datastore
# Copy-DatastoreItem -Item "C:\path\to\rhel-9.6-x86_64-dvd.iso" -Destination "ds:\isos\"
```

### 2. Create and Configure VMs

```powershell
# Create VM
$vm = New-VM -Name "rpm-external" -ResourcePool (Get-ResourcePool) -Datastore $ds `
    -NumCpu 2 -MemoryGB 4 -DiskGB 200 -GuestId "rhel9_64Guest" -NetworkName "VM Network"

# Add CD drive 1 with boot ISO
New-CDDrive -VM $vm -IsoPath "[$($ds.Name)] isos/boot-external.iso" -StartConnected:$true

# Add CD drive 2 with RHEL DVD
New-CDDrive -VM $vm -IsoPath "[$($ds.Name)] isos/rhel-9.6-x86_64-dvd.iso" -StartConnected:$true

# Start VM - installation is fully automated
Start-VM -VM $vm
```

### 3. Monitor Installation

Installation takes 10-15 minutes. Monitor progress:

```powershell
# Check for IP address (indicates installation complete)
do {
    Start-Sleep -Seconds 30
    $vm = Get-VM -Name "rpm-external"
    $ip = $vm.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    Write-Host "Waiting for IP... Current: $ip"
} while (-not $ip)

Write-Host "Installation complete. IP: $ip"
```

### 4. Verify Installation

```powershell
# SSH to the new server
ssh admin@$ip  # Password: 12qwaszx!@QWASZX

# On the server, verify services
systemctl status httpd
systemctl status sshd
```

## Default Credentials

The kickstart files configure:

| User | Password | Notes |
|------|----------|-------|
| root | `12qwaszx!@QWASZX` | Direct root login |
| admin | `12qwaszx!@QWASZX` | Sudo access via wheel group |

**Change these passwords immediately after deployment in production environments.**

## Kickstart Configuration

### External Server (rpm-external)

- Hostname: `rpm-external`
- Packages: httpd, python3, dnf-utils, createrepo_c
- Services: httpd, sshd, chronyd
- Firewall: disabled (configure as needed)
- SELinux: permissive

### Internal Server (rpm-internal)

- Hostname: `rpm-internal`
- Packages: httpd, python3, dnf-utils, createrepo_c
- Services: httpd, sshd, chronyd
- Firewall: disabled (configure as needed)
- SELinux: permissive

## Customizing Kickstart Files

Source kickstart files are in `airgapped-deps/isos/`:
- `ks-external.cfg`
- `ks-internal.cfg`

To rebuild ISOs with modified kickstart:

```bash
# Extract boot files from RHEL DVD
mount /dev/sr0 /mnt
cp -r /mnt/images/pxeboot /tmp/rhel-boot/
cp -r /mnt/EFI/BOOT /tmp/rhel-boot/EFI/
cp -r /mnt/isolinux /tmp/rhel-boot/

# Modify kickstart as needed
vim /tmp/rhel-boot/ks.cfg

# Create GRUB config with kickstart parameter
cat > /tmp/rhel-boot/EFI/BOOT/grub.cfg << 'EOF'
set timeout=5
set default=0

menuentry "Install RHEL 9.6 (Kickstart)" {
    linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=RHEL-9-6-0-BaseOS-x86_64 inst.ks=hd:LABEL=OEMDRV:/ks.cfg quiet
    initrd /images/pxeboot/initrd.img
}
EOF

# Build ISO
genisoimage -o boot-custom.iso \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e EFI/BOOT/BOOTX64.EFI -no-emul-boot \
    -V "OEMDRV" -R -J /tmp/rhel-boot/
```

## Troubleshooting

### VM Boots to GRUB Shell

- Verify boot ISO is in CD drive 1 (first CD)
- Check ISO was built with correct boot sectors

### Kickstart Not Found

- Verify boot ISO has `OEMDRV` volume label
- Check `inst.ks=hd:LABEL=OEMDRV:/ks.cfg` in GRUB config

### Stage2 Not Found

- Verify RHEL DVD is in CD drive 2
- Check DVD label matches `inst.stage2=hd:LABEL=RHEL-9-6-0-BaseOS-x86_64`

### Installation Hangs

- Check VM console for error messages
- Verify both CDs are connected (not just configured)
- Ensure adequate disk space (200GB recommended)

### No Network After Install

- Verify VM network adapter is connected
- Check DHCP server is available on the network
- Review `/var/log/anaconda/` for network errors

## Legacy OEMDRV Method (Does NOT Work with RHEL 9.6)

The traditional two-ISO method where:
1. CD #1 = RHEL DVD
2. CD #2 = Small OEMDRV-labeled ISO with ks.cfg

**Does NOT work** with RHEL 9.6 because Anaconda requires explicit `inst.ks=` kernel
parameter to find the kickstart file. The auto-detection of OEMDRV volumes no longer
functions without this parameter.

Use the boot ISO method described above instead.
