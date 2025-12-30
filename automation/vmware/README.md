# VMware Kickstart ISO Injection

This directory contains documentation and layout for the kickstart ISO injection method used for automated RHEL installation.

## How It Works

VMware supports mounting multiple CD/DVD drives to a VM. We use this to provide:

1. **CD/DVD #1**: Official RHEL 9.6 installation ISO
2. **CD/DVD #2**: Custom kickstart ISO (labeled `OEMDRV`)

When Anaconda (the RHEL installer) boots, it automatically searches for a volume labeled `OEMDRV` and loads the `ks.cfg` file from it. This enables fully automated installation without any boot menu timing or manual intervention.

## KS ISO Layout

The kickstart ISO has the following structure:

```
ks-iso/
├── ks.cfg              # Main kickstart configuration file
└── (optional additional files)
```

## Volume Label

The ISO **must** be labeled `OEMDRV` for Anaconda to auto-detect it:

```bash
# Linux (genisoimage/mkisofs)
genisoimage -o ks.iso -V "OEMDRV" -R -J /path/to/ks-files/

# Windows (oscdimg from Windows ADK)
oscdimg -l"OEMDRV" -o -m /path/to/ks-files ks.iso
```

## Kickstart Files

Two kickstart configurations are generated from templates:

| File | Purpose |
|------|---------|
| `rhel96_external.ks` | External RPM server (internet-connected) |
| `rhel96_internal.ks` | Internal RPM server (airgapped, FIPS, rootless podman) |

Templates are in `automation/kickstart/` and use placeholders replaced by values from `config/spec.yaml`.

## Placeholders

| Placeholder | Source |
|-------------|--------|
| `{{HOSTNAME}}` | `vm_names.rpm_external` or `vm_names.rpm_internal` |
| `{{ROOT_PASSWORD}}` | `credentials.initial_root_password` |
| `{{ADMIN_USER}}` | `credentials.initial_admin_user` |
| `{{ADMIN_PASSWORD}}` | `credentials.initial_admin_password` |
| `{{SERVICE_USER}}` | `internal_services.service_user` |
| `{{DATA_DIR}}` | `internal_services.data_dir` |
| `{{CERTS_DIR}}` | `internal_services.certs_dir` |
| `{{ANSIBLE_DIR}}` | `internal_services.ansible_dir` |
| `{{FIPS_ENABLED}}` | `compliance.enable_fips` |
| `{{HTTP_PORT}}` | `https_internal_repo.http_port` |
| `{{HTTPS_PORT}}` | `https_internal_repo.https_port` |

## Generation Process

1. `generate-ks-iso.ps1` reads `config/spec.yaml`
2. Loads kickstart template from `automation/kickstart/`
3. Replaces placeholders with configuration values
4. Creates staging directory with `ks.cfg`
5. Builds ISO with `OEMDRV` volume label
6. Outputs to `output/ks-isos/`

## Verification

After ISO generation, verify contents:

```bash
# Mount and check (Linux)
sudo mount -o loop ks-external.iso /mnt
cat /mnt/ks.cfg
sudo umount /mnt

# Check label
isoinfo -d -i ks-external.iso | grep "Volume id"
# Should show: Volume id: OEMDRV
```

## Boot Process

1. VM boots from RHEL ISO (CD #1)
2. Anaconda starts and detects `OEMDRV` volume (CD #2)
3. Kickstart file is loaded automatically
4. Installation proceeds without user interaction
5. System reboots and ejects CDs
6. VMware Tools start, indicating completion

## Troubleshooting

### Kickstart Not Loading

- Verify ISO has `OEMDRV` label
- Check both CD drives are connected at boot
- Verify kickstart syntax: `ksvalidator ks.cfg`

### Installation Fails

- Check VM console for Anaconda error messages
- Verify disk space meets kickstart requirements
- Ensure network connectivity for DHCP

### VMware Tools Not Running

- Installation may still be in progress
- Check if FIPS mode reboot is pending (internal VM)
- Verify open-vm-tools package was installed
