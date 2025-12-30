# Airgapped RPM Repository System - Operator Guide

## Table of Contents

1. [Purpose and System Overview](#1-purpose-and-system-overview)
2. [Roles and Responsibilities](#2-roles-and-responsibilities)
3. [Environment Components](#3-environment-components)
4. [Initial Setup](#4-initial-setup)
5. [External RPM Server Operations](#5-external-rpm-server-operations)
6. [Internal RPM Server Operations](#6-internal-rpm-server-operations)
7. [Ansible Control Plane Operations](#7-ansible-control-plane-operations)
8. [Monthly Patch Cycle](#8-monthly-patch-cycle)
9. [TLS, Certificates, and Trust](#9-tls-certificates-and-trust)
10. [Logging, Auditing, and Compliance](#10-logging-auditing-and-compliance)
11. [Troubleshooting Guide](#11-troubleshooting-guide)
12. [Backup, Recovery, and Rollback](#12-backup-recovery-and-rollback)
13. [What This System Does NOT Do](#13-what-this-system-does-not-do)
14. [Quick Reference (Cheat Sheet)](#14-quick-reference-cheat-sheet)

---

## 1. Purpose and System Overview

### What This System Does

The Airgapped RPM Repository System provides secure, controlled software distribution to RHEL 8 and RHEL 9 hosts in airgapped (network-isolated) environments. The system:

- Synchronizes RPM packages from upstream sources on an internet-connected server
- Creates cryptographically signed bundles for physical transfer across the airgap
- Imports and validates bundles on an internal server within the airgapped network
- Publishes packages through lifecycle environments (testing → stable)
- Enables managed hosts to receive patches without direct internet access

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INTERNET-CONNECTED ZONE                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      External RPM Server                             │   │
│  │  - Syncs from Red Hat CDN, EPEL, custom repos                       │   │
│  │  - Creates GPG-signed export bundles                                │   │
│  │  - Generates Bill of Materials (BOM)                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Physical Transfer
                                      │ (USB, DVD, approved media)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            AIRGAPPED ZONE                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      Internal RPM Server                             │   │
│  │  - Imports and verifies bundles                                     │   │
│  │  - Publishes via HTTPS (self-signed cert)                          │   │
│  │  - Lifecycle: testing → stable                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                       Managed RHEL Hosts                             │   │
│  │  - RHEL 8 and RHEL 9 systems                                        │   │
│  │  - Configured via Ansible                                           │   │
│  │  - Receive patches from internal repository                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Lifecycle Environments

Packages flow through controlled lifecycle environments:

| Environment | Purpose | Typical Use |
|-------------|---------|-------------|
| `testing` | Initial import destination | Validation before production |
| `stable` | Production packages | Consumed by managed hosts |

Managed hosts are configured to use the `stable` environment by default. The `repo_lifecycle_env` variable controls which environment a host uses.

---

## 2. Roles and Responsibilities

### External RPM Server Operator

**Location**: Internet-connected zone (outside airgap)

**Responsibilities**:
- Register system with Red Hat Subscription Manager
- Enable required RHEL repositories
- Execute package synchronization from upstream sources
- Build repository metadata with GPG signing
- Create export bundles with cryptographic signatures
- Prepare media for physical transfer across airgap
- Maintain GPG signing keys for bundle authentication

### Internal RPM Server Operator

**Location**: Airgapped zone (inside secure network)

**Responsibilities**:
- Receive and verify incoming bundles
- Import validated bundles into testing environment
- Test package availability and integrity
- Promote packages from testing to stable
- Manage the rpm-publisher container
- Maintain TLS certificates for HTTPS access
- Ensure high availability of repository services

### Ansible Operator

**Location**: Airgapped zone with network access to managed hosts

**Responsibilities**:
- Onboard new hosts to the repository infrastructure
- Configure repository access and trust
- Execute monthly patching cycles
- Collect and archive host package manifests
- Configure syslog forwarding to central collector
- Troubleshoot host connectivity issues

---

## 3. Environment Components

### External RPM Server

| Component | Description |
|-----------|-------------|
| Operating System | RHEL 8.10+ or RHEL 9.6+ |
| Subscription | Valid Red Hat subscription with access to BaseOS, AppStream, EPEL |
| Storage | Minimum 500GB for synchronized repositories |
| Software | `createrepo_c`, `gnupg2`, `tar`, `sha256sum` |

**Directory Structure**:
```
/data/
├── repos/                    # Synchronized repositories
│   ├── rhel8-baseos/
│   ├── rhel8-appstream/
│   ├── rhel9-baseos/
│   ├── rhel9-appstream/
│   └── epel9/
├── export/                   # Export bundles ready for transfer
├── gpg/                      # GPG keys for signing
└── logs/                     # Operation logs
```

### Internal RPM Server

| Component | Description |
|-----------|-------------|
| Operating System | RHEL 8.10+, RHEL 9.6+, or compatible (AlmaLinux, Rocky) |
| Container Runtime | Podman (rootless preferred) |
| Container Image | `rpm-publisher` (AlmaLinux 9 based) |
| Storage | Minimum 500GB for imported packages |
| Ports | 8080 (HTTP), 8443 (HTTPS) |

**Directory Structure**:
```
/data/
├── import/                   # Incoming bundles
├── lifecycle/
│   ├── testing/              # Testing environment
│   │   ├── rhel8/
│   │   └── rhel9/
│   └── stable/               # Production environment
│       ├── rhel8/
│       └── rhel9/
├── certs/                    # TLS certificates
├── gpg/                      # GPG public keys for verification
└── logs/                     # Container and operation logs
```

### Managed Hosts

| Component | Requirement |
|-----------|-------------|
| Operating System | RHEL 8.10+ or RHEL 9.6+ |
| Python | RHEL 9: `/usr/bin/python3`, RHEL 8: `/usr/bin/python3.11` |
| Network | Access to internal RPM server on ports 8080/8443 |
| Disk Space | Minimum 500MB free (configurable) |

**Critical Files on Managed Hosts**:
```
/etc/airgap/host-identity           # Unique host identifier
/etc/pki/rpm-gpg/RPM-GPG-KEY-airgap # Repository GPG key
/etc/yum.repos.d/airgap-*.repo      # Repository configuration
/etc/pki/tls/certs/airgap-ca.crt    # Repository CA certificate
```

---

## 4. Initial Setup

### 4.1 External RPM Server Setup

#### Step 1: Register with Red Hat Subscription Manager

```bash
# Register system with Red Hat
sudo subscription-manager register --username YOUR_RH_USERNAME --password YOUR_RH_PASSWORD

# Attach subscription
sudo subscription-manager attach --auto

# Verify registration
sudo subscription-manager status
```

**Expected Output**:
```
+-------------------------------------------+
   System Status Details
+-------------------------------------------+
Overall Status: Current
```

#### Step 2: Enable Required Repositories

For RHEL 9:
```bash
sudo subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms
sudo subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms
```

For RHEL 8:
```bash
sudo subscription-manager repos --enable=rhel-8-for-x86_64-baseos-rpms
sudo subscription-manager repos --enable=rhel-8-for-x86_64-appstream-rpms
```

**Verify enabled repositories**:
```bash
sudo subscription-manager repos --list-enabled
```

#### Step 3: Install Required Tools

```bash
sudo dnf install -y createrepo_c gnupg2 tar
```

#### Step 4: Create Directory Structure

```bash
sudo mkdir -p /data/{repos,export,gpg,logs}
sudo chown -R $(whoami):$(whoami) /data
```

#### Step 5: Generate GPG Signing Key

```bash
# Generate key (no passphrase for automated signing)
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Airgap RPM Signing Key
Name-Email: airgap@internal.local
Expire-Date: 2y
%commit
EOF

# Export public key for transfer to internal server
gpg --armor --export airgap@internal.local > /data/gpg/RPM-GPG-KEY-airgap

# Verify key was created
gpg --list-keys airgap@internal.local
```

**Expected Output**:
```
pub   rsa4096 2025-01-15 [SC] [expires: 2027-01-15]
      ABCD1234EFGH5678...
uid           [ultimate] Airgap RPM Signing Key <airgap@internal.local>
```

### 4.2 Internal RPM Server Setup

#### Step 1: Install Podman

```bash
sudo dnf install -y podman
```

#### Step 2: Create Directory Structure

```bash
sudo mkdir -p /data/{import,lifecycle/{testing,stable}/{rhel8,rhel9},certs,gpg,logs}
sudo chown -R 1001:1001 /data
```

#### Step 3: Import GPG Public Key

Copy the GPG public key from the external server (via approved media):
```bash
# Copy key to internal server
cp /media/transfer/RPM-GPG-KEY-airgap /data/gpg/

# Verify key
gpg --show-keys /data/gpg/RPM-GPG-KEY-airgap
```

#### Step 4: Build rpm-publisher Container

```bash
cd /path/to/airgapped-rpm-repo/containers/rpm-publisher

# Build container image
podman build -t rpm-publisher:latest .

# Verify image
podman images rpm-publisher
```

#### Step 5: Start rpm-publisher Container

```bash
podman run -d \
  --name rpm-publisher \
  --user 1001:1001 \
  -p 8080:8080 \
  -p 8443:8443 \
  -v /data:/data:Z \
  rpm-publisher:latest

# Verify container is running
podman ps

# Check logs for startup errors
podman logs rpm-publisher
```

**Expected Log Output**:
```
Starting rpm-publisher...
Generating self-signed certificate...
Starting nginx on ports 8080 (HTTP) and 8443 (HTTPS)...
```

#### Step 6: Verify HTTPS Access

```bash
# Test HTTPS endpoint (ignore certificate warning for self-signed)
curl -k https://localhost:8443/

# Expected: Directory listing or welcome page
```

### 4.3 Ansible Control Plane Setup

#### Step 1: Install Ansible

```bash
sudo dnf install -y ansible-core
```

#### Step 2: Configure Inventory

Edit `ansible/inventories/hosts.yml` with your environment:

```yaml
all:
  vars:
    ansible_user: admin
    ansible_become: yes

    # Internal repository settings
    internal_repo_host: rpm-internal.example.local
    internal_repo_https_port: 8443
    internal_repo_url: "https://{{ internal_repo_host }}:{{ internal_repo_https_port }}"
    repo_lifecycle_env: stable

    # Syslog settings
    syslog_tls_target_host: syslog.example.local
    syslog_tls_target_port: 6514
    syslog_tls_ca_bundle_path: /etc/pki/tls/certs/syslog-ca.crt

    # Onboarding settings
    onboard_disable_external_repos: true
    connectivity_retry_count: 3
    connectivity_retry_delay: 5
    preflight_check_disk_space_mb: 500

  children:
    rhel9_hosts:
      vars:
        ansible_python_interpreter: /usr/bin/python3
        repo_profile: rhel9
      hosts:
        server1.example.local:
          airgap_host_id: server1-prod-01
        server2.example.local:
          airgap_host_id: server2-prod-01

    rhel8_hosts:
      vars:
        ansible_python_interpreter: /usr/bin/python3.11
        repo_profile: rhel8
      hosts:
        legacy1.example.local:
          airgap_host_id: legacy1-prod-01
```

**Critical**: Every managed host MUST have a unique `airgap_host_id` value.

#### Step 3: Test Connectivity

```bash
# Test ping to all hosts
ansible -i ansible/inventories/hosts.yml all -m ping

# Expected output for each host:
# hostname | SUCCESS => {
#     "ping": "pong"
# }
```

---

## 5. External RPM Server Operations

### 5.1 Synchronize Repositories

#### Full Synchronization (All Packages)

```bash
cd /path/to/airgapped-rpm-repo

# Sync all configured repositories
make sync
```

This operation may take several hours on first run depending on network speed.

#### Verify Synchronization

```bash
# Check repository sizes
du -sh /data/repos/*

# List package counts
for repo in /data/repos/*/; do
  echo "$(basename $repo): $(find $repo -name '*.rpm' | wc -l) packages"
done
```

### 5.2 Build Repository Metadata

After synchronization, rebuild repository metadata with GPG signatures:

```bash
make build-repos
```

**Verify metadata**:
```bash
# Check repodata exists
ls -la /data/repos/rhel9-baseos/repodata/

# Expected files:
# repomd.xml
# repomd.xml.asc (GPG signature)
# *-primary.xml.gz
# *-filelists.xml.gz
# *-other.xml.gz
```

### 5.3 Create Export Bundle

#### Standard Bundle Creation

```bash
# Create bundle with timestamp name
make export BUNDLE_NAME=monthly-patch-$(date +%Y%m%d)
```

This creates:
- `/data/export/monthly-patch-YYYYMMDD.tar.gz` - The bundle archive
- `/data/export/monthly-patch-YYYYMMDD.tar.gz.sha256` - SHA256 checksum
- `/data/export/monthly-patch-YYYYMMDD.tar.gz.sig` - GPG signature
- `/data/export/monthly-patch-YYYYMMDD.bom.json` - Bill of Materials

#### Verify Bundle Creation

```bash
# Verify checksum
cd /data/export
sha256sum -c monthly-patch-YYYYMMDD.tar.gz.sha256

# Expected: monthly-patch-YYYYMMDD.tar.gz: OK

# Verify GPG signature
gpg --verify monthly-patch-YYYYMMDD.tar.gz.sig monthly-patch-YYYYMMDD.tar.gz

# Expected: Good signature from "Airgap RPM Signing Key"

# View BOM summary
cat monthly-patch-YYYYMMDD.bom.json | python3 -m json.tool | head -50
```

### 5.4 Prepare Media for Transfer

Copy all bundle files to approved transfer media:

```bash
# Mount approved USB device
sudo mount /dev/sdb1 /mnt/transfer

# Copy bundle files
cp /data/export/monthly-patch-YYYYMMDD.* /mnt/transfer/

# Include GPG public key for first-time setup
cp /data/gpg/RPM-GPG-KEY-airgap /mnt/transfer/

# Safely unmount
sync
sudo umount /mnt/transfer
```

**Transfer Checklist**:
- [ ] `.tar.gz` bundle file
- [ ] `.sha256` checksum file
- [ ] `.sig` GPG signature file
- [ ] `.bom.json` Bill of Materials
- [ ] `RPM-GPG-KEY-airgap` (first transfer only)

---

## 6. Internal RPM Server Operations

### 6.1 Receive and Verify Bundle

#### Step 1: Copy Bundle to Import Directory

```bash
# Mount transfer media
sudo mount /dev/sdb1 /mnt/transfer

# Copy to import directory
cp /mnt/transfer/monthly-patch-YYYYMMDD.* /data/import/

# Unmount media
sudo umount /mnt/transfer
```

#### Step 2: Verify Bundle Integrity

```bash
cd /data/import

# Verify SHA256 checksum
sha256sum -c monthly-patch-YYYYMMDD.tar.gz.sha256
```

**Expected Output**:
```
monthly-patch-YYYYMMDD.tar.gz: OK
```

**If verification fails**, do NOT proceed. The bundle may be corrupted. Request retransfer.

#### Step 3: Verify GPG Signature

```bash
# Import public key (first time only)
gpg --import /data/gpg/RPM-GPG-KEY-airgap

# Verify signature
gpg --verify monthly-patch-YYYYMMDD.tar.gz.sig monthly-patch-YYYYMMDD.tar.gz
```

**Expected Output**:
```
gpg: Signature made Mon 15 Jan 2025 10:30:00 AM EST
gpg:                using RSA key ABCD1234...
gpg: Good signature from "Airgap RPM Signing Key <airgap@internal.local>"
```

**If signature verification fails**, do NOT proceed. The bundle may be tampered.

### 6.2 Import Bundle

#### Import to Testing Environment

```bash
cd /path/to/airgapped-rpm-repo

# Import bundle to testing lifecycle
make import BUNDLE_PATH=/data/import/monthly-patch-YYYYMMDD.tar.gz
```

This operation:
1. Extracts bundle to `/data/lifecycle/testing/`
2. Rebuilds repository metadata
3. Makes packages available for testing

#### Verify Import

```bash
# Check testing environment has packages
ls /data/lifecycle/testing/rhel9/Packages/ | head

# Verify repository metadata
ls /data/lifecycle/testing/rhel9/repodata/
```

### 6.3 Test Package Availability

From a test host configured to use the testing lifecycle:

```bash
# Clean DNF cache
sudo dnf clean all

# List available packages
sudo dnf list available | head -20

# Test install a package (example)
sudo dnf install -y tree

# Verify installation
tree --version
```

### 6.4 Promote to Stable

After testing confirms packages are correct:

```bash
cd /path/to/airgapped-rpm-repo

# Promote from testing to stable
make promote FROM=testing TO=stable
```

#### Verify Promotion

```bash
# Verify stable has packages
ls /data/lifecycle/stable/rhel9/Packages/ | wc -l

# Compare package counts
echo "Testing: $(ls /data/lifecycle/testing/rhel9/Packages/ | wc -l)"
echo "Stable: $(ls /data/lifecycle/stable/rhel9/Packages/ | wc -l)"
```

### 6.5 Container Management

#### View Container Status

```bash
podman ps
```

#### View Container Logs

```bash
# Last 100 lines
podman logs --tail 100 rpm-publisher

# Follow logs in real-time
podman logs -f rpm-publisher
```

#### Restart Container

```bash
podman restart rpm-publisher

# Verify restart
podman ps
```

#### Rebuild Container

```bash
cd /path/to/airgapped-rpm-repo/containers/rpm-publisher

# Stop and remove existing
podman stop rpm-publisher
podman rm rpm-publisher

# Rebuild
podman build -t rpm-publisher:latest .

# Start new container
podman run -d \
  --name rpm-publisher \
  --user 1001:1001 \
  -p 8080:8080 \
  -p 8443:8443 \
  -v /data:/data:Z \
  rpm-publisher:latest
```

---

## 7. Ansible Control Plane Operations

### 7.1 Host Onboarding

#### Onboard All Managed Hosts

```bash
cd /path/to/airgapped-rpm-repo/ansible

ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml
```

#### Onboard Specific Host

```bash
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --limit server1.example.local
```

#### Onboard with Testing Lifecycle

```bash
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml -e repo_lifecycle_env=testing
```

#### Dry Run (Check Mode)

```bash
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --check
```

### 7.2 Verify Host Configuration

After onboarding, verify host is correctly configured:

```bash
# SSH to host and verify repository
ssh admin@server1.example.local

# List configured repositories
sudo dnf repolist

# Expected output shows airgap-* repos

# Test package installation
sudo dnf install -y vim-enhanced

# Verify host identity file
cat /etc/airgap/host-identity
```

### 7.3 Collect Package Manifests

#### Collect from All Hosts

```bash
ansible-playbook -i inventories/hosts.yml playbooks/collect_manifests.yml
```

#### View Collected Manifests

```bash
# List manifest files
ls -la artifacts/manifests/

# View specific host manifest
cat artifacts/manifests/server1-prod-01/packages.json | python3 -m json.tool | head -50
```

### 7.4 Configure Repository Access Only

```bash
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --tags repository
```

### 7.5 Configure Syslog Only

```bash
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --tags syslog
```

---

## 8. Monthly Patch Cycle

### Overview

The monthly patch cycle follows this workflow:

```
External: Sync → Build → Export → Transfer
                                    ↓
Internal: Import → Test → Promote → Patch Hosts
```

### 8.1 External Server: Prepare Patch Bundle

**Execute on External RPM Server**:

```bash
cd /path/to/airgapped-rpm-repo

# Step 1: Sync latest packages
make sync

# Step 2: Build repository metadata
make build-repos

# Step 3: Create export bundle
make export BUNDLE_NAME=patch-$(date +%Y%m)

# Step 4: Verify bundle
cd /data/export
sha256sum -c patch-$(date +%Y%m).tar.gz.sha256
gpg --verify patch-$(date +%Y%m).tar.gz.sig

# Step 5: Copy to transfer media
cp patch-$(date +%Y%m).* /mnt/transfer/
```

### 8.2 Internal Server: Import and Validate

**Execute on Internal RPM Server**:

```bash
cd /path/to/airgapped-rpm-repo

# Step 1: Copy from transfer media
cp /mnt/transfer/patch-*.* /data/import/

# Step 2: Verify bundle
cd /data/import
sha256sum -c patch-$(date +%Y%m).tar.gz.sha256
gpg --verify patch-$(date +%Y%m).tar.gz.sig

# Step 3: Import to testing
make import BUNDLE_PATH=/data/import/patch-$(date +%Y%m).tar.gz

# Step 4: Validate on test host
# (SSH to test host and run: dnf check-update)

# Step 5: Promote to stable
make promote FROM=testing TO=stable
```

### 8.3 Ansible: Execute Patching

**Execute on Ansible Control Plane**:

```bash
cd /path/to/airgapped-rpm-repo/ansible

# Step 1: Dry run - see what would be updated
ansible-playbook -i inventories/hosts.yml playbooks/patch_monthly_security.yml --check

# Step 2: Execute patching (with controlled rollout)
ansible-playbook -i inventories/hosts.yml playbooks/patch_monthly_security.yml
```

#### Patching Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `patch_serial` | `20%` | Percentage of hosts to patch concurrently |
| `patch_max_fail` | `10` | Maximum failure percentage before aborting |
| `patch_reboot` | `true` | Whether to reboot after patching |

```bash
# Example: Patch one host at a time, allow 5% failures
ansible-playbook -i inventories/hosts.yml playbooks/patch_monthly_security.yml \
  -e patch_serial=1 \
  -e patch_max_fail=5
```

### 8.4 Post-Patch Verification

```bash
# Verify all hosts are reachable
ansible -i inventories/hosts.yml all -m ping

# Check kernel versions
ansible -i inventories/hosts.yml all -m shell -a "uname -r"

# Collect updated manifests
ansible-playbook -i inventories/hosts.yml playbooks/collect_manifests.yml
```

---

## 9. TLS, Certificates, and Trust

### 9.1 Certificate Architecture

The system uses a self-signed certificate model:

```
┌─────────────────────────────────────────┐
│         rpm-publisher Container          │
│  - Self-signed certificate generated     │
│  - Valid for HTTPS on port 8443         │
└─────────────────────────────────────────┘
                    │
                    │ HTTPS with self-signed cert
                    ▼
┌─────────────────────────────────────────┐
│           Managed Hosts                  │
│  - Trust CA via /etc/pki/tls/certs/     │
│  - Repository configured for HTTPS      │
└─────────────────────────────────────────┘
```

### 9.2 Certificate Locations

| Location | Purpose |
|----------|---------|
| `/data/certs/server.crt` | Server certificate (on internal server) |
| `/data/certs/server.key` | Server private key (on internal server) |
| `/etc/pki/tls/certs/airgap-ca.crt` | CA certificate (on managed hosts) |

### 9.3 Generate New Self-Signed Certificate

If certificate expires or needs replacement:

```bash
# Stop container
podman stop rpm-publisher

# Generate new certificate
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /data/certs/server.key \
  -out /data/certs/server.crt \
  -subj "/CN=rpm-publisher/O=Airgap/C=US"

# Set permissions
chmod 600 /data/certs/server.key
chmod 644 /data/certs/server.crt
chown 1001:1001 /data/certs/*

# Restart container
podman start rpm-publisher
```

### 9.4 Distribute CA Certificate to Hosts

After generating new certificate, update all managed hosts:

```bash
# Copy new CA to Ansible files directory
cp /data/certs/server.crt ansible/roles/host_onboarding/files/airgap-ca.crt

# Re-run onboarding to distribute
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --tags repository
```

### 9.5 Syslog TLS Configuration

Syslog forwarding uses server-side TLS authentication (hosts verify server, not vice versa).

Required variables in inventory:
```yaml
syslog_tls_target_host: syslog.example.local
syslog_tls_target_port: 6514
syslog_tls_ca_bundle_path: /etc/pki/tls/certs/syslog-ca.crt
```

To enable syslog configuration during onboarding:
```yaml
onboard_configure_syslog: true
```

---

## 10. Logging, Auditing, and Compliance

### 10.1 Log Locations

#### External RPM Server

| Log File | Content |
|----------|---------|
| `/data/logs/sync.log` | Repository synchronization output |
| `/data/logs/export.log` | Bundle export operations |
| `/var/log/messages` | System messages |

#### Internal RPM Server

| Log File | Content |
|----------|---------|
| `/data/logs/import.log` | Bundle import operations |
| `/data/logs/promote.log` | Lifecycle promotions |
| `podman logs rpm-publisher` | Container output |

#### Managed Hosts

| Log File | Content |
|----------|---------|
| `/var/log/dnf.log` | Package installation/updates |
| `/var/log/messages` | System messages |
| `/var/log/secure` | Authentication events |

### 10.2 Audit Trail

#### Bundle Chain of Custody

Each bundle includes a Bill of Materials (BOM) with:
- Bundle creation timestamp
- Source repository information
- Package list with versions and checksums
- GPG signature information

View BOM:
```bash
cat /data/import/patch-202501.bom.json | python3 -m json.tool
```

#### Host Manifests

Package manifests are collected and stored in `artifacts/manifests/`:
```
artifacts/manifests/
├── server1-prod-01/
│   ├── onboarding.json      # Initial package state
│   ├── packages.json        # Current package list
│   └── history/
│       ├── 2025-01-15.json  # Historical snapshots
│       └── 2025-02-15.json
└── server2-prod-01/
    └── ...
```

### 10.3 Compliance Verification

#### Verify All Hosts Use Internal Repository

```bash
ansible -i inventories/hosts.yml managed_hosts -m shell -a "dnf repolist"
```

All hosts should show only `airgap-*` repositories.

#### Verify External Repositories Disabled

```bash
ansible -i inventories/hosts.yml managed_hosts -m shell -a "ls /etc/yum.repos.d/*.repo"
```

External repository files should be disabled (renamed to `.disabled`).

#### Generate Compliance Report

```bash
# Collect manifests
ansible-playbook -i inventories/hosts.yml playbooks/collect_manifests.yml

# Compare against baseline
# (Custom script required based on compliance requirements)
```

### 10.4 Syslog Forwarding

All managed hosts are configured to forward logs to a central syslog collector via TLS.

Verify syslog configuration:
```bash
ansible -i inventories/hosts.yml managed_hosts -m shell -a "cat /etc/rsyslog.d/airgap-forward.conf"
```

Test log forwarding:
```bash
ansible -i inventories/hosts.yml managed_hosts -m shell -a "logger -t airgap-test 'Compliance test message'"
```

---

## 11. Troubleshooting Guide

### 11.1 External RPM Server Issues

#### Sync Fails with Authentication Error

**Symptom**:
```
Error: Cannot retrieve repository metadata (repomd.xml) for repository: rhel-9-for-x86_64-baseos-rpms
```

**Resolution**:
```bash
# Verify subscription status
sudo subscription-manager status

# Re-register if needed
sudo subscription-manager register --force

# Verify repository is enabled
sudo subscription-manager repos --list-enabled | grep baseos
```

#### GPG Key Generation Fails

**Symptom**:
```
gpg: agent_genkey failed: No such file or directory
```

**Resolution**:
```bash
# Start gpg-agent
gpg-agent --daemon

# Or use direct key generation
gpg --batch --passphrase '' --quick-generate-key "Airgap RPM Signing Key <airgap@internal.local>" rsa4096 sign 2y
```

### 11.2 Internal RPM Server Issues

#### Container Fails to Start

**Symptom**:
```
Error: error creating container storage: ... permission denied
```

**Resolution**:
```bash
# Check directory ownership
ls -la /data/

# Fix ownership for rootless podman
sudo chown -R 1001:1001 /data/

# Restart container
podman start rpm-publisher
```

#### HTTPS Certificate Errors

**Symptom**:
```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

**Resolution**:
```bash
# For testing, ignore certificate:
curl -k https://localhost:8443/

# For production, ensure CA is distributed:
# Re-run onboarding with repository tag
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --tags repository
```

#### Bundle Import Fails

**Symptom**:
```
Error: Bundle checksum verification failed
```

**Resolution**:
```bash
# Verify file is complete
ls -la /data/import/

# Re-copy from transfer media
cp /mnt/transfer/patch-*.tar.gz /data/import/

# Verify checksum
sha256sum -c patch-*.sha256
```

### 11.3 Managed Host Issues

#### DNF Cannot Connect to Repository

**Symptom**:
```
Error: Failed to download metadata for repo 'airgap-rhel9-baseos'
```

**Resolution**:
```bash
# Test network connectivity
curl -k https://rpm-internal:8443/

# Verify repository configuration
cat /etc/yum.repos.d/airgap-rhel9-baseos.repo

# Check DNS resolution
nslookup rpm-internal

# Verify firewall
sudo firewall-cmd --list-all
```

#### Python Interpreter Not Found (RHEL 8)

**Symptom**:
```
FAILED! => {"msg": "The module failed to execute correctly, you probably need to set the Python interpreter."}
```

**Resolution**:
Ensure RHEL 8 hosts have correct Python interpreter in inventory:
```yaml
rhel8_hosts:
  vars:
    ansible_python_interpreter: /usr/bin/python3.11
```

Install Python 3.11 on RHEL 8:
```bash
sudo dnf install -y python3.11
```

#### Host Identity File Missing

**Symptom**:
```
FAILED! => {"msg": "airgap_host_id is not defined"}
```

**Resolution**:
Ensure each host has `airgap_host_id` defined in inventory:
```yaml
hosts:
  myhost.example.local:
    airgap_host_id: myhost-prod-01  # Add this line
```

### 11.4 Ansible Issues

#### SSH Connection Timeout

**Symptom**:
```
fatal: [server1]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```

**Resolution**:
```bash
# Test SSH manually
ssh admin@server1.example.local

# Check SSH key is distributed
ssh-copy-id admin@server1.example.local

# Verify inventory has correct credentials
cat ansible/inventories/hosts.yml | grep -A5 "ansible_"
```

#### Sudo Password Required

**Symptom**:
```
fatal: [server1]: FAILED! => {"msg": "Missing sudo password"}
```

**Resolution**:
Add become password to inventory or use `--ask-become-pass`:
```bash
ansible-playbook playbooks/onboard_hosts.yml --ask-become-pass

# Or configure in inventory:
# ansible_become_password: your_password
```

---

## 12. Backup, Recovery, and Rollback

### 12.1 What to Back Up

| Component | Location | Backup Frequency |
|-----------|----------|------------------|
| GPG signing keys | `/data/gpg/` (external) | Once, store securely |
| Repository data | `/data/repos/` (external) | After each sync |
| Lifecycle environments | `/data/lifecycle/` (internal) | After each import |
| TLS certificates | `/data/certs/` (internal) | After regeneration |
| Host manifests | `artifacts/manifests/` | After each collection |
| Ansible inventory | `ansible/inventories/` | After changes |

### 12.2 Backup Procedures

#### Back Up GPG Keys

```bash
# On external server
tar -czvf gpg-keys-backup-$(date +%Y%m%d).tar.gz /data/gpg/

# Store in secure offline location
```

#### Back Up Lifecycle Environments

```bash
# On internal server
tar -czvf lifecycle-backup-$(date +%Y%m%d).tar.gz /data/lifecycle/
```

### 12.3 Recovery Procedures

#### Restore Lifecycle Environment

```bash
# Stop container
podman stop rpm-publisher

# Restore from backup
cd /
tar -xzvf /backup/lifecycle-backup-20250115.tar.gz

# Fix ownership
chown -R 1001:1001 /data/lifecycle/

# Restart container
podman start rpm-publisher
```

#### Rebuild Repository Metadata

If metadata is corrupted:
```bash
# Rebuild metadata for all environments
for env in testing stable; do
  for profile in rhel8 rhel9; do
    createrepo_c --update /data/lifecycle/$env/$profile/
  done
done

# Restart container to reload
podman restart rpm-publisher
```

### 12.4 Rollback Procedures

#### Rollback to Previous Lifecycle State

If a bad package was promoted to stable:

```bash
# Option 1: Restore from backup
podman stop rpm-publisher
tar -xzvf /backup/lifecycle-backup-PREVIOUS.tar.gz -C /
chown -R 1001:1001 /data/lifecycle/
podman start rpm-publisher

# Option 2: Re-import previous bundle
make import BUNDLE_PATH=/data/import/previous-good-bundle.tar.gz
make promote FROM=testing TO=stable
```

#### Rollback Package on Managed Hosts

```bash
# Downgrade specific package
ansible -i inventories/hosts.yml managed_hosts -m shell -a "dnf downgrade -y PACKAGE_NAME"

# Or use DNF history
ansible -i inventories/hosts.yml managed_hosts -m shell -a "dnf history list"
ansible -i inventories/hosts.yml managed_hosts -m shell -a "dnf history undo TRANSACTION_ID"
```

---

## 13. What This System Does NOT Do

### Not Included in This System

1. **Automatic Internet Synchronization**
   - The system does NOT automatically pull updates from the internet
   - All updates require manual export, physical transfer, and import

2. **Real-Time Security Updates**
   - There is no automatic notification of new CVEs
   - Operators must monitor Red Hat security advisories independently

3. **Package Building**
   - The system does NOT compile or build RPM packages
   - It only mirrors existing packages from upstream sources

4. **User Authentication/Authorization**
   - Repository access is network-based, not user-based
   - Any host that can reach the internal server can access packages

5. **Windows Support**
   - Only RHEL 8 and RHEL 9 are supported
   - Windows, Ubuntu, and other distributions are not supported

6. **Dependency Resolution Intelligence**
   - The system mirrors complete repositories
   - It does not selectively include only needed dependencies

7. **High Availability**
   - Single internal server architecture
   - No built-in clustering or failover

8. **Bandwidth Optimization**
   - Full bundles are transferred each cycle
   - No delta/incremental bundle support

9. **Audit Log Aggregation**
   - Syslog forwarding is configured, but log aggregation server is external
   - No built-in log analysis or alerting

10. **Compliance Reporting**
    - Manifests are collected but compliance analysis is manual
    - No automatic compliance report generation

### External Dependencies

The following must be provided by your organization:

- Red Hat subscription for repository access
- Approved physical transfer media and procedures
- Syslog collection infrastructure
- Network infrastructure and DNS
- Backup storage systems
- Security monitoring and alerting

---

## 14. Quick Reference (Cheat Sheet)

### External RPM Server Commands

```bash
# Register with Red Hat
sudo subscription-manager register

# Sync all repositories
make sync

# Build repository metadata
make build-repos

# Create export bundle
make export BUNDLE_NAME=patch-$(date +%Y%m)

# Verify bundle
sha256sum -c BUNDLE.tar.gz.sha256
gpg --verify BUNDLE.tar.gz.sig BUNDLE.tar.gz
```

### Internal RPM Server Commands

```bash
# Check container status
podman ps

# View container logs
podman logs --tail 100 rpm-publisher

# Import bundle
make import BUNDLE_PATH=/data/import/BUNDLE.tar.gz

# Promote to stable
make promote FROM=testing TO=stable

# Restart container
podman restart rpm-publisher

# Rebuild container
podman stop rpm-publisher && podman rm rpm-publisher
podman build -t rpm-publisher:latest .
podman run -d --name rpm-publisher -p 8080:8080 -p 8443:8443 -v /data:/data:Z rpm-publisher
```

### Ansible Commands

```bash
# Test connectivity
ansible -i inventories/hosts.yml all -m ping

# Onboard all hosts
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml

# Onboard specific host
ansible-playbook -i inventories/hosts.yml playbooks/onboard_hosts.yml --limit HOSTNAME

# Dry run patching
ansible-playbook -i inventories/hosts.yml playbooks/patch_monthly_security.yml --check

# Execute patching
ansible-playbook -i inventories/hosts.yml playbooks/patch_monthly_security.yml

# Collect manifests
ansible-playbook -i inventories/hosts.yml playbooks/collect_manifests.yml
```

### Verification Commands

```bash
# On managed host: Verify repository access
sudo dnf repolist

# On managed host: Test package install
sudo dnf install -y tree

# On managed host: Check host identity
cat /etc/airgap/host-identity

# On internal server: Verify HTTPS
curl -k https://localhost:8443/
```

### File Locations Quick Reference

| Purpose | External Server | Internal Server | Managed Host |
|---------|-----------------|-----------------|--------------|
| Repositories | `/data/repos/` | `/data/lifecycle/` | N/A |
| GPG Keys | `/data/gpg/` | `/data/gpg/` | `/etc/pki/rpm-gpg/` |
| Certificates | N/A | `/data/certs/` | `/etc/pki/tls/certs/` |
| Logs | `/data/logs/` | `/data/logs/` | `/var/log/dnf.log` |
| Import/Export | `/data/export/` | `/data/import/` | N/A |
| Host Identity | N/A | N/A | `/etc/airgap/host-identity` |

### Critical Variables Reference

| Variable | Purpose | Default |
|----------|---------|---------|
| `internal_repo_host` | Internal server hostname | `rpm-publisher` |
| `internal_repo_https_port` | HTTPS port | `8443` |
| `repo_lifecycle_env` | Target lifecycle | `stable` |
| `airgap_host_id` | Unique host identifier | (required) |
| `onboard_disable_external_repos` | Disable internet repos | `true` |
| `patch_serial` | Concurrent patch percentage | `20%` |
| `patch_max_fail` | Max failure percentage | `10` |

---

## Document Information

| Field | Value |
|-------|-------|
| Version | 1.0 |
| Last Updated | 2025-12-30 |
| Author | System Documentation |
| Audience | System Operators and Administrators |
