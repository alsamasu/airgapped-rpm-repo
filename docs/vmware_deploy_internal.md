# VMware Deployment Guide - Internal Publisher

This document describes how to build and deploy the Internal Publisher as a VMware OVA for production use.

## Prerequisites

### Build System

- Linux or macOS system with:
  - [Packer](https://www.packer.io/) 1.9.0+
  - VMware Workstation or Fusion (for local builds)
  - At least 250GB free disk space
- RHEL 9.6 installation ISO
- Valid ISO checksum

### Target Environment

- VMware ESXi 7.0 U2+ or vSphere 7.0+
- Datastore with at least 300GB available
- Network with DHCP (or static IP configuration)

## Obtaining RHEL 9.6 ISO

1. Log in to [Red Hat Customer Portal](https://access.redhat.com/downloads/content/rhel)
2. Download: `rhel-9.6-x86_64-dvd.iso`
3. Verify checksum:
   ```bash
   sha256sum rhel-9.6-x86_64-dvd.iso
   ```

## Building the OVA

### 1. Configure Variables

```bash
cd packer

# Copy example configuration
cp variables.pkrvars.hcl.example variables.pkrvars.hcl

# Edit configuration
vim variables.pkrvars.hcl
```

**Required variables:**

```hcl
iso_path     = "/path/to/rhel-9.6-x86_64-dvd.iso"
iso_checksum = "sha256:your_checksum_here"
version      = "1.0.0"
```

**Optional variables:**

```hcl
vm_name         = "rhel9-internal-publisher"
cpus            = 2
memory          = 4096       # MB
disk_size       = 102400     # MB (100GB for OS)
data_disk_size  = 204800     # MB (200GB for /data)
ssh_username    = "root"
ssh_password    = "changeme"  # Change for security
headless        = true
output_directory = "output"
```

### 2. Initialize Packer

```bash
# Initialize plugins
packer init rhel9-internal.pkr.hcl
```

### 3. Validate Configuration

```bash
make packer-validate ISO_PATH=/path/to/rhel.iso ISO_CHECKSUM=sha256:...

# Or directly
packer validate -var-file=variables.pkrvars.hcl rhel9-internal.pkr.hcl
```

### 4. Build OVA

```bash
make packer-build-internal ISO_PATH=/path/to/rhel.iso ISO_CHECKSUM=sha256:...

# Or directly
packer build -var-file=variables.pkrvars.hcl rhel9-internal.pkr.hcl
```

**Build time:** Approximately 30-60 minutes.

### 5. Verify Output

```bash
ls -la output/rhel9-internal-publisher/
# rhel9-internal-publisher.ova
# rhel9-internal-publisher.sha256
```

## Deploying to vSphere

### Method 1: vSphere Client (Web UI)

1. Open vSphere Client
2. Navigate to target host or cluster
3. Right-click → **Deploy OVF Template**
4. Select the OVA file
5. Configure:
   - Name: `internal-publisher`
   - Folder: Select appropriate folder
   - Compute resource: Select host/cluster
   - Storage: Select datastore (thin provisioned recommended)
   - Network: Select production network
6. Review and **Finish**

### Method 2: OVFTool (CLI)

```bash
ovftool \
  --acceptAllEulas \
  --name="internal-publisher" \
  --datastore="<datastore>" \
  --network="<network>" \
  --vmFolder="<folder>" \
  --powerOn \
  output/rhel9-internal-publisher/rhel9-internal-publisher.ova \
  'vi://username:password@vcenter.example.com/Datacenter/host/Cluster'
```

### Method 3: govc (CLI)

```bash
export GOVC_URL="vcenter.example.com"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="password"
export GOVC_INSECURE=true

govc import.ova \
  -name="internal-publisher" \
  -ds="<datastore>" \
  -folder="<folder>" \
  output/rhel9-internal-publisher/rhel9-internal-publisher.ova

govc vm.power -on internal-publisher
```

## Post-Deployment Configuration

### 1. First Boot

The VM will boot and run initial configuration. Wait for SSH to become available.

### 2. Set Static IP (if needed)

```bash
# SSH to VM
ssh root@<dhcp-assigned-ip>

# Configure static IP
nmcli con mod "System eth0" \
  ipv4.method manual \
  ipv4.addresses "192.168.1.100/24" \
  ipv4.gateway "192.168.1.1" \
  ipv4.dns "192.168.1.10"

nmcli con up "System eth0"
```

### 3. Configure Hostname

```bash
hostnamectl set-hostname internal-publisher.internal.local
```

### 4. Configure SSH Keys

```bash
# On admin workstation
ssh-copy-id root@internal-publisher

# On VM: disable password auth
sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

### 5. Import GPG Key

```bash
# Copy GPG key from hand-carry media
cp /mnt/usb/RPM-GPG-KEY-internal /data/keys/

# Import into keyring
/opt/rpmserver/scripts/common/gpg_functions.sh import /data/keys/RPM-GPG-KEY-internal
```

### 6. Start Repository Service

```bash
# Enable and start service
systemctl enable --now rpmserver.service

# Verify
curl http://localhost:8080/repos/
```

### 7. Configure Firewall

```bash
# Verify ports are open
firewall-cmd --list-all

# If needed, add ports
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --reload
```

## Persistent Storage

The OVA includes a secondary disk for `/data`. This disk:
- Is automatically formatted and mounted during installation
- Contains all repository data, bundles, and keys
- Should be backed up regularly

### Expanding /data

If more space is needed:

1. Add a new disk in vSphere
2. Extend the filesystem:

```bash
# Identify new disk
lsblk

# Create partition
parted /dev/sdc mklabel gpt
parted /dev/sdc mkpart primary xfs 0% 100%

# Extend LVM (if using LVM)
pvcreate /dev/sdc1
vgextend vg_data /dev/sdc1
lvextend -l +100%FREE /dev/vg_data/lv_data
xfs_growfs /data
```

## Backup and Recovery

### Backup

```bash
# Backup /data directory
tar -czf /backup/data-$(date +%Y%m%d).tar.gz /data

# Or use VMware snapshots for full VM backup
```

### Recovery

```bash
# Restore from backup
systemctl stop rpmserver
tar -xzf /backup/data-YYYYMMDD.tar.gz -C /
systemctl start rpmserver
```

## Compliance Validation

After deployment, run compliance checks:

```bash
# Run OpenSCAP evaluation
/opt/rpmserver/scripts/run_openscap.sh

# Generate STIG checklist
/opt/rpmserver/scripts/generate_ckl.sh

# View results
ls /opt/rpmserver/compliance/html/
```

## Troubleshooting

### VM Won't Boot

- Verify hardware compatibility in vSphere
- Check boot order in VM settings
- Review VM console for errors

### Network Issues

```bash
# Check network status
nmcli device status
ip addr show

# Check DNS
nslookup internal-publisher.internal.local
```

### Service Issues

```bash
# Check service status
systemctl status rpmserver

# Check logs
journalctl -u rpmserver -f
tail -f /var/log/rpmserver/httpd-error.log
```

### SELinux Issues

```bash
# Check SELinux status
getenforce

# Check for denials
ausearch -m avc -ts recent

# Fix contexts
restorecon -Rv /data
```

## Hardware Recommendations

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 2 vCPU | 4 vCPU |
| Memory | 4 GB | 8 GB |
| OS Disk | 50 GB | 100 GB |
| Data Disk | 100 GB | 500 GB |
| Network | 1 Gbps | 10 Gbps |

## Related Documentation

- [Architecture](architecture.md)
- [Internal Workflow](internal_workflow.md)
- [STIG Hardening](stig_hardening_internal.md)
- [Operations](operations.md)
