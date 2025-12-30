# External Builder Server Setup Guide

## RHEL 9.6 Repository Sync and OVF/OVA Build System

---

## 1) Overview

### What This Server Is

The **External Builder Server** is an internet-connected RHEL 9.6 system that:

- Subscribes to Red Hat CDN via subscription-manager
- Syncs RPM repositories (BaseOS, AppStream, etc.)
- Creates signed, encrypted bundles for airgap transfer
- Builds VMware OVF/OVA images using Packer
- Computes update calculations against host manifests

### What It Will Provide After Setup

- Automated repository synchronization from Red Hat CDN
- GPG-signed repository bundles for secure transfer
- Packer templates for building internal server OVA images
- Update calculation reports showing available patches per host
- Bill of Materials (BOM) for compliance tracking

### What It Will NOT Do

- Serve repositories to clients (that's the internal server's job)
- Operate in an airgapped environment
- Run continuously (typically run on-demand for sync/build operations)

---

## 2) Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Disk | 500 GB | 1 TB+ |
| Network | Internet access | High-bandwidth internet |

### Software Requirements

| Component | Version | Purpose |
|-----------|---------|---------|
| RHEL | 9.6 | Base operating system |
| Subscription | Active | Red Hat CDN access |
| Podman | 4.x | Container runtime |
| Packer | 1.9+ | OVA image building |
| VMware ovftool | 4.6+ | OVA packaging |

### Required Access

- Red Hat Customer Portal credentials
- Red Hat Subscription with RHEL entitlements
- VMware vCenter credentials (for Packer builds)
- GPG key pair for bundle signing

### Required Files

| File | Source |
|------|--------|
| RHEL 9.6 ISO | Red Hat Customer Portal |
| This repository | `git clone` or transferred archive |

---

## 3) Install Base Operating System

### 3.1) Boot from RHEL 9.6 ISO

1. Boot the server from RHEL 9.6 installation media
2. Select **Install Red Hat Enterprise Linux 9.6**

### 3.2) Installation Options

| Setting | Value |
|---------|-------|
| Software Selection | Minimal Install |
| Installation Destination | Use entire disk, LVM |
| Root Password | Set strong password |
| User Creation | Create admin user with sudo |

### 3.3) Partition Layout

| Mount Point | Size | Purpose |
|-------------|------|---------|
| `/boot` | 1 GB | Boot partition |
| `/boot/efi` | 600 MB | EFI partition |
| `/` | 50 GB | Root filesystem |
| `/var` | 100 GB | Logs, containers |
| `/srv/builder` | Remaining | Repository mirror, bundles |

### 3.4) Complete Installation

1. Click **Begin Installation**
2. Wait for installation to complete
3. Click **Reboot System**

### Verify: OS Installed

```bash
cat /etc/redhat-release
```

**Expected output:**
```
Red Hat Enterprise Linux release 9.6 (Plow)
```

---

## 4) Register System and Enable Repositories

### 4.1) Register with Subscription Manager

```bash
subscription-manager register --username=YOUR_RH_USERNAME --password=YOUR_RH_PASSWORD
```

**Expected output:**
```
The system has been registered with ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### 4.2) Attach Subscription

```bash
subscription-manager attach --auto
```

**Expected output:**
```
Installed Product Current Status:
Product Name: Red Hat Enterprise Linux for x86_64
Status:       Subscribed
```

### 4.3) Enable Required Repositories

```bash
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms
subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms
subscription-manager repos --enable=codeready-builder-for-rhel-9-x86_64-rpms
```

### 4.4) Update System

```bash
dnf update -y
reboot
```

### Verify: Repositories Enabled

```bash
subscription-manager repos --list-enabled
```

**Expected output:**
```
+----------------------------------------------------------+
    Available Repositories in /etc/yum.repos.d/redhat.repo
+----------------------------------------------------------+
Repo ID:   rhel-9-for-x86_64-baseos-rpms
Repo Name: Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)
Repo URL:  https://cdn.redhat.com/content/dist/rhel9/$releasever/x86_64/baseos/os
Enabled:   1
...
```

---

## 5) Install Required Packages

### 5.1) Install Development Tools

```bash
dnf groupinstall -y "Development Tools"
```

### 5.2) Install Repository Tools

```bash
dnf install -y \
    createrepo_c \
    dnf-utils \
    yum-utils \
    reposync \
    gnupg2 \
    pinentry \
    python3 \
    python3-pip \
    python3-dnf \
    rsync \
    tar \
    gzip \
    xz \
    openssl \
    jq \
    git \
    podman \
    buildah \
    skopeo
```

### 5.3) Install Packer

```bash
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
dnf install -y packer
```

### Verify: Packer Installed

```bash
packer --version
```

**Expected output:**
```
1.9.x
```

### 5.4) Install VMware ovftool

Download ovftool from VMware Customer Connect and install:

```bash
chmod +x VMware-ovftool-4.6.0-xxxxx-lin.x86_64.bundle
./VMware-ovftool-4.6.0-xxxxx-lin.x86_64.bundle --eulas-agreed
```

### Verify: ovftool Installed

```bash
ovftool --version
```

**Expected output:**
```
VMware ovftool 4.6.0 (build-xxxxx)
```

### 5.5) Install Python Dependencies

```bash
pip3 install --user \
    pyyaml \
    jinja2 \
    requests
```

### Verify: All Packages Installed

```bash
which createrepo_c reposync packer ovftool gpg
```

**Expected output:**
```
/usr/bin/createrepo_c
/usr/bin/reposync
/usr/bin/packer
/usr/local/bin/ovftool
/usr/bin/gpg
```

---

## 6) Create Directory Structure

### 6.1) Create Base Directories

```bash
mkdir -p /srv/builder/{mirror,bundles,manifests,keys,staging,packer,iso}
mkdir -p /srv/builder/mirror/{rhel9,rhel8}
mkdir -p /srv/builder/mirror/rhel9/{x86_64,aarch64}
mkdir -p /srv/builder/mirror/rhel9/x86_64/{baseos,appstream}
mkdir -p /srv/builder/bundles/{outgoing,archive}
mkdir -p /srv/builder/manifests/{incoming,processed}
```

### 6.2) Create Builder User

```bash
useradd -r -m -d /srv/builder -s /bin/bash builder
chown -R builder:builder /srv/builder
chmod 755 /srv/builder
```

### 6.3) Set Permissions

```bash
chmod 700 /srv/builder/keys
chmod 755 /srv/builder/mirror
chmod 755 /srv/builder/bundles
chmod 755 /srv/builder/manifests
```

### Verify: Directory Structure

```bash
ls -la /srv/builder/
```

**Expected output:**
```
drwxr-xr-x. builder builder bundles
drwx------. builder builder keys
drwxr-xr-x. builder builder manifests
drwxr-xr-x. builder builder mirror
drwxr-xr-x. builder builder packer
drwxr-xr-x. builder builder staging
drwxr-xr-x. builder builder iso
```

---

## 7) Generate GPG Signing Key

### 7.1) Switch to Builder User

```bash
su - builder
```

### 7.2) Configure GPG

```bash
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg
cat > ~/.gnupg/gpg.conf << 'EOF'
personal-digest-preferences SHA512
cert-digest-algo SHA512
default-preference-list SHA512 SHA384 SHA256 SHA224 AES256 AES192 AES CAST5 ZLIB BZIP2 ZIP Uncompressed
EOF
```

### 7.3) Generate Key Pair

```bash
gpg --full-generate-key
```

**Select the following options:**
- Key type: `(1) RSA and RSA`
- Key size: `4096`
- Expiration: `2y` (2 years)
- Real name: `Internal RPM Repository`
- Email: `rpm-repo@example.com`
- Comment: `Bundle Signing Key`
- Passphrase: Set a strong passphrase

### 7.4) Export Public Key

```bash
gpg --armor --export "Internal RPM Repository" > /srv/builder/keys/RPM-GPG-KEY-internal
```

### 7.5) Export Private Key (for backup)

```bash
gpg --armor --export-secret-keys "Internal RPM Repository" > /srv/builder/keys/RPM-GPG-KEY-internal.secret
chmod 600 /srv/builder/keys/RPM-GPG-KEY-internal.secret
```

### 7.6) Create RPM Signing Macro

```bash
cat > ~/.rpmmacros << 'EOF'
%_signature gpg
%_gpg_name Internal RPM Repository
%__gpg /usr/bin/gpg
EOF
```

### Verify: GPG Key Created

```bash
gpg --list-keys "Internal RPM Repository"
```

**Expected output:**
```
pub   rsa4096 2025-12-30 [SC] [expires: 2027-12-30]
      XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
uid           [ultimate] Internal RPM Repository (Bundle Signing Key) <rpm-repo@example.com>
sub   rsa4096 2025-12-30 [E] [expires: 2027-12-30]
```

---

## 8) Clone and Configure Repository Scripts

### 8.1) Clone Repository (or transfer archive)

As the builder user:

```bash
cd /srv/builder
git clone https://github.com/YOUR_ORG/airgapped-rpm-repo.git repo
```

Or if transferring an archive:

```bash
tar -xzf airgapped-rpm-repo.tar.gz -C /srv/builder/
mv /srv/builder/airgapped-rpm-repo /srv/builder/repo
```

### 8.2) Make Scripts Executable

```bash
chmod +x /srv/builder/repo/scripts/external/*.sh
chmod +x /srv/builder/repo/scripts/common/*.sh
```

### 8.3) Create Configuration File

```bash
cat > /srv/builder/config.env << 'EOF'
# External Builder Configuration

# Directories
BUILDER_BASE_DIR=/srv/builder
MIRROR_DIR=/srv/builder/mirror
BUNDLE_DIR=/srv/builder/bundles
MANIFEST_DIR=/srv/builder/manifests
STAGING_DIR=/srv/builder/staging
KEY_DIR=/srv/builder/keys

# GPG Settings
GPG_KEY_ID="Internal RPM Repository"

# Sync Settings
SYNC_BASEOS=1
SYNC_APPSTREAM=1
SYNC_CODEREADY=0

# Architecture
ARCH=x86_64

# RHEL Versions to sync
RHEL_VERSIONS="9"

# Retention (days)
BUNDLE_RETENTION_DAYS=90
EOF
```

### 8.4) Source Configuration

```bash
echo 'source /srv/builder/config.env' >> ~/.bashrc
source /srv/builder/config.env
```

### Verify: Scripts Ready

```bash
ls -la /srv/builder/repo/scripts/external/
```

**Expected output:**
```
-rwxr-xr-x. sync_repos.sh
-rwxr-xr-x. export_bundle.sh
-rwxr-xr-x. compute_updates.sh
-rwxr-xr-x. ingest_manifests.sh
...
```

---

## 9) Synchronize Repositories

### 9.1) Run Initial Sync

```bash
/srv/builder/repo/scripts/external/sync_repos.sh
```

**This will take several hours on first run (downloading ~30-50 GB).**

**Expected output:**
```
[INFO] Starting repository synchronization...
[INFO] Syncing rhel-9-for-x86_64-baseos-rpms...
[INFO] Downloaded: 5000 packages
[INFO] Syncing rhel-9-for-x86_64-appstream-rpms...
[INFO] Downloaded: 8000 packages
[OK] Repository sync complete
```

### 9.2) Monitor Sync Progress

In another terminal:

```bash
watch -n 10 'du -sh /srv/builder/mirror/rhel9/x86_64/*'
```

### Verify: Repositories Synced

```bash
ls -la /srv/builder/mirror/rhel9/x86_64/baseos/Packages/ | head -20
```

**Expected output:** List of RPM files.

```bash
ls -la /srv/builder/mirror/rhel9/x86_64/baseos/repodata/
```

**Expected output:**
```
-rw-r--r--. repomd.xml
-rw-r--r--. *-primary.xml.gz
-rw-r--r--. *-filelists.xml.gz
-rw-r--r--. *-other.xml.gz
...
```

---

## 10) Create Repository Bundle

### 10.1) Generate Bundle

```bash
/srv/builder/repo/scripts/external/export_bundle.sh
```

**Expected output:**
```
[INFO] Creating bundle...
[INFO] Generating checksums...
[INFO] Creating Bill of Materials...
[INFO] Signing bundle...
[OK] Bundle created: /srv/builder/bundles/outgoing/bundle-20251230-120000.tar.gz.gpg
```

### 10.2) Verify Bundle Contents

```bash
ls -la /srv/builder/bundles/outgoing/
```

**Expected output:**
```
-rw-r--r--. bundle-20251230-120000.tar.gz.gpg
-rw-r--r--. bundle-20251230-120000.tar.gz.gpg.sig
-rw-r--r--. bundle-20251230-120000.bom.json
-rw-r--r--. bundle-20251230-120000.sha256
```

### 10.3) Verify GPG Signature

```bash
gpg --verify /srv/builder/bundles/outgoing/bundle-20251230-120000.tar.gz.gpg.sig \
    /srv/builder/bundles/outgoing/bundle-20251230-120000.tar.gz.gpg
```

**Expected output:**
```
gpg: Signature made Mon 30 Dec 2025 12:00:00 PM UTC
gpg:                using RSA key XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
gpg: Good signature from "Internal RPM Repository (Bundle Signing Key) <rpm-repo@example.com>"
```

### Verify: Bundle Ready for Transfer

```bash
ls -lh /srv/builder/bundles/outgoing/bundle-*.tar.gz.gpg
```

**Expected output:**
```
-rw-r--r--. 15G bundle-20251230-120000.tar.gz.gpg
```

---

## 11) Configure Packer for OVA Builds

### 11.1) Copy ISO to Builder

```bash
cp /path/to/rhel-9.6-x86_64-dvd.iso /srv/builder/iso/
```

### 11.2) Create Packer Variables File

```bash
cat > /srv/builder/packer/variables.pkrvars.hcl << 'EOF'
# VMware vCenter Connection
vcenter_server       = "vcenter.example.com"
vcenter_username     = "administrator@vsphere.local"
vcenter_password     = "YOUR_VCENTER_PASSWORD"
vcenter_datacenter   = "Datacenter"
vcenter_cluster      = "Cluster"
vcenter_datastore    = "datastore1"
vcenter_network      = "VM Network"
vcenter_folder       = "Templates"

# ISO Configuration
iso_url              = "/srv/builder/iso/rhel-9.6-x86_64-dvd.iso"
iso_checksum         = "sha256:COMPUTE_THIS_CHECKSUM"

# VM Configuration
vm_name              = "airgap-internal-rpm-server"
vm_cpus              = 4
vm_memory            = 8192
vm_disk_size         = 102400

# SSH Configuration (for Packer provisioning)
ssh_username         = "root"
ssh_password         = "PACKER_BUILD_PASSWORD"
ssh_timeout          = "30m"

# Output
output_directory     = "/srv/builder/packer/output"
EOF
```

### 11.3) Compute ISO Checksum

```bash
sha256sum /srv/builder/iso/rhel-9.6-x86_64-dvd.iso
```

Update `iso_checksum` in variables file with the result.

### 11.4) Copy Packer Template

```bash
cp /srv/builder/repo/packer/internal-server.pkr.hcl /srv/builder/packer/
cp -r /srv/builder/repo/packer/http /srv/builder/packer/
```

### Verify: Packer Configuration

```bash
cd /srv/builder/packer
packer validate -var-file=variables.pkrvars.hcl internal-server.pkr.hcl
```

**Expected output:**
```
The configuration is valid.
```

---

## 12) Build OVA Image

### 12.1) Run Packer Build

```bash
cd /srv/builder/packer
packer build -var-file=variables.pkrvars.hcl internal-server.pkr.hcl
```

**This will take 30-60 minutes.**

**Expected output:**
```
==> vmware-iso.internal-server: Creating VM...
==> vmware-iso.internal-server: Uploading ISO...
==> vmware-iso.internal-server: Starting VM...
==> vmware-iso.internal-server: Waiting for SSH...
==> vmware-iso.internal-server: Connected to SSH!
==> vmware-iso.internal-server: Provisioning...
==> vmware-iso.internal-server: Stopping VM...
==> vmware-iso.internal-server: Exporting to OVF...
Build 'vmware-iso.internal-server' finished.

==> Builds finished. The artifacts of successful builds are:
--> vmware-iso.internal-server: VM files in directory: /srv/builder/packer/output
```

### 12.2) Verify OVA Output

```bash
ls -la /srv/builder/packer/output/
```

**Expected output:**
```
-rw-r--r--. airgap-internal-rpm-server.ovf
-rw-r--r--. airgap-internal-rpm-server-disk1.vmdk
-rw-r--r--. airgap-internal-rpm-server.mf
```

### 12.3) Convert to Single OVA File (Optional)

```bash
ovftool /srv/builder/packer/output/airgap-internal-rpm-server.ovf \
    /srv/builder/packer/output/airgap-internal-rpm-server.ova
```

### Verify: OVA Valid

```bash
ovftool --verifyOnly /srv/builder/packer/output/airgap-internal-rpm-server.ova
```

**Expected output:**
```
Completed successfully
```

---

## 13) Process Host Manifests

### 13.1) Receive Manifests from Internal Server

Manifests are collected by Ansible on the internal server and transferred here:

```bash
scp -r rpmops@internal-server:/opt/ansible/manifests/* /srv/builder/manifests/incoming/
```

### 13.2) Process Manifests

```bash
/srv/builder/repo/scripts/external/ingest_manifests.sh
```

**Expected output:**
```
[INFO] Processing manifests...
[INFO] Found 5 host manifests
[OK] Processed: server1-prod-01
[OK] Processed: server2-prod-02
...
[OK] All manifests processed
```

### 13.3) Compute Available Updates

```bash
/srv/builder/repo/scripts/external/compute_updates.sh
```

**Expected output:**
```
[INFO] Computing updates for 5 hosts...
[INFO] server1-prod-01: 23 updates available
[INFO] server2-prod-02: 18 updates available
...
[OK] Update report: /srv/builder/manifests/update-report-20251230.json
```

### Verify: Update Report Generated

```bash
cat /srv/builder/manifests/update-report-20251230.json | jq '.summary'
```

**Expected output:**
```json
{
  "total_hosts": 5,
  "hosts_with_updates": 5,
  "total_updates_available": 85,
  "generated_at": "2025-12-30T12:00:00Z"
}
```

---

## 14) Transfer Artifacts to Airgapped Network

### 14.1) Files to Transfer

| File | Destination | Purpose |
|------|-------------|---------|
| `bundle-*.tar.gz.gpg` | Internal server | Repository content |
| `bundle-*.bom.json` | Internal server | Compliance tracking |
| `RPM-GPG-KEY-internal` | Internal server + clients | Package verification |
| `*.ova` | VMware admin | New VM deployment |
| `update-report-*.json` | Operations team | Patching planning |

### 14.2) Copy to Transfer Media

```bash
TRANSFER_DIR=/mnt/transfer

# Repository bundle
cp /srv/builder/bundles/outgoing/bundle-*.tar.gz.gpg $TRANSFER_DIR/
cp /srv/builder/bundles/outgoing/bundle-*.bom.json $TRANSFER_DIR/
cp /srv/builder/bundles/outgoing/bundle-*.sha256 $TRANSFER_DIR/

# GPG public key
cp /srv/builder/keys/RPM-GPG-KEY-internal $TRANSFER_DIR/

# OVA image (if building new internal server)
cp /srv/builder/packer/output/*.ova $TRANSFER_DIR/

# Update report
cp /srv/builder/manifests/update-report-*.json $TRANSFER_DIR/
```

### 14.3) Verify Transfer Integrity

Create checksums for verification:

```bash
cd $TRANSFER_DIR
sha256sum * > CHECKSUMS.sha256
```

### Verify: Files Ready for Transfer

```bash
cat $TRANSFER_DIR/CHECKSUMS.sha256
```

---

## 15) Scheduled Operations

### 15.1) Create Sync Cron Job

```bash
crontab -e
```

Add the following line for weekly sync (Sunday at 2 AM):

```
0 2 * * 0 /srv/builder/repo/scripts/external/sync_repos.sh >> /var/log/repo-sync.log 2>&1
```

### 15.2) Create Bundle Cron Job

Add the following line for weekly bundle (Sunday at 6 AM):

```
0 6 * * 0 /srv/builder/repo/scripts/external/export_bundle.sh >> /var/log/bundle-export.log 2>&1
```

### 15.3) Create Cleanup Cron Job

Add the following line for monthly cleanup:

```
0 0 1 * * find /srv/builder/bundles/archive -mtime +90 -delete
```

### Verify: Cron Jobs Active

```bash
crontab -l
```

---

## 16) Troubleshooting

### 16.1) Subscription Manager Issues

**Check subscription status:**
```bash
subscription-manager status
```

**Re-register if needed:**
```bash
subscription-manager unregister
subscription-manager register --username=YOUR_USERNAME --password=YOUR_PASSWORD
subscription-manager attach --auto
```

### 16.2) Repository Sync Failures

**Check reposync logs:**
```bash
cat /var/log/repo-sync.log | tail -100
```

**Test repository access:**
```bash
dnf repolist
dnf makecache
```

**Manual sync single repo:**
```bash
reposync --repoid=rhel-9-for-x86_64-baseos-rpms --download-path=/srv/builder/mirror/rhel9/x86_64/baseos --downloadcomps --download-metadata
```

### 16.3) GPG Signing Failures

**Check GPG agent:**
```bash
gpg-agent --daemon
```

**List available keys:**
```bash
gpg --list-secret-keys
```

**Test signing:**
```bash
echo "test" | gpg --clearsign
```

### 16.4) Packer Build Failures

**Enable debug logging:**
```bash
PACKER_LOG=1 packer build -var-file=variables.pkrvars.hcl internal-server.pkr.hcl
```

**Check vCenter connectivity:**
```bash
curl -k https://vcenter.example.com/sdk
```

**Verify ISO checksum:**
```bash
sha256sum /srv/builder/iso/rhel-9.6-x86_64-dvd.iso
```

### 16.5) Disk Space Issues

**Check disk usage:**
```bash
df -h /srv/builder
du -sh /srv/builder/*
```

**Clear old bundles:**
```bash
find /srv/builder/bundles/archive -mtime +30 -delete
```

**Clear old syncs (keep only latest):**
```bash
# Only do this if you need to reclaim space urgently
rm -rf /srv/builder/mirror/rhel9/x86_64/baseos/Packages/*.rpm
# Then re-run sync
```

---

## 17) Security Considerations

### 17.1) Protect GPG Private Key

```bash
chmod 600 /srv/builder/keys/RPM-GPG-KEY-internal.secret
```

Store a backup of the private key in a secure location (HSM, vault, safe).

### 17.2) Secure vCenter Credentials

Do not store vCenter password in plain text. Use environment variables:

```bash
export PKR_VAR_vcenter_password="YOUR_PASSWORD"
```

Or use HashiCorp Vault:

```bash
packer build -var "vcenter_password=$(vault kv get -field=password secret/vcenter)" ...
```

### 17.3) Audit Logging

Enable audit logging for bundle creation:

```bash
cat >> /etc/audit/rules.d/builder.rules << 'EOF'
-w /srv/builder/bundles -p wa -k bundle_creation
-w /srv/builder/keys -p r -k gpg_key_access
EOF

augenrules --load
```

### 17.4) Network Segmentation

The external builder should be on a network segment that:
- Has internet access to Red Hat CDN
- Can connect to vCenter (for Packer builds)
- Is isolated from production systems
- Has controlled access from administrators only

---

## 18) Quick Reference

| Task | Command |
|------|---------|
| Sync repos | `/srv/builder/repo/scripts/external/sync_repos.sh` |
| Create bundle | `/srv/builder/repo/scripts/external/export_bundle.sh` |
| Process manifests | `/srv/builder/repo/scripts/external/ingest_manifests.sh` |
| Compute updates | `/srv/builder/repo/scripts/external/compute_updates.sh` |
| Build OVA | `packer build -var-file=variables.pkrvars.hcl internal-server.pkr.hcl` |
| Check subscription | `subscription-manager status` |
| List GPG keys | `gpg --list-keys` |
| Check disk space | `df -h /srv/builder` |

---

## 19) File Locations Summary

| Path | Contents |
|------|----------|
| `/srv/builder/mirror/` | Synced repository content |
| `/srv/builder/bundles/outgoing/` | Ready-to-transfer bundles |
| `/srv/builder/bundles/archive/` | Historical bundles |
| `/srv/builder/manifests/incoming/` | Received host manifests |
| `/srv/builder/manifests/processed/` | Processed manifests |
| `/srv/builder/keys/` | GPG keys |
| `/srv/builder/packer/output/` | Built OVA images |
| `/srv/builder/iso/` | RHEL installation ISOs |
| `/srv/builder/repo/` | This repository (scripts) |

---

**Document Version:** 1.0  
**Last Updated:** 2025-12-30  
**Applies To:** Airgapped RPM Repository System - External Builder
