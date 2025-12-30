# External Builder Workflow

This document describes the workflow for the External Builder, which syncs content from Red Hat CDN and creates bundles for the Internal Publisher.

## Prerequisites

- RHEL 8 or 9 system with internet access
- Valid Red Hat subscription
- At least 200GB disk space for mirroring
- GPG for signing

## Workflow Overview

```
1. Register with subscription-manager
2. Enable required repositories
3. Sync content from CDN
4. Ingest host manifests
5. Compute available updates
6. Build repository structure
7. Export signed bundle
```

## Step-by-Step Guide

### 1. Initialize Environment

```bash
# Initialize external builder
make init-external

# Or manually
./rpmserverctl init-external
```

This creates:
- `/data/mirror/` - Repository mirror storage
- `/data/manifests/` - Host manifest storage
- `/data/bundles/` - Bundle export storage
- `/data/keys/` - GPG key storage
- `/data/external.conf` - Configuration file

### 2. Register with Subscription Manager

**Option A: Using Activation Key (Recommended)**

```bash
make sm-register ACTIVATION_KEY=your-key ORG_ID=your-org-id
```

**Option B: Using Username/Password**

```bash
make sm-register SM_USER=your-username SM_PASS=your-password
```

**Verification:**

```bash
subscription-manager status
subscription-manager list --consumed
```

### 3. Enable Repositories

```bash
# Enable default repositories (RHEL 8 and 9 BaseOS/AppStream)
make enable-repos

# Or with options
./scripts/external/enable_repos.sh --rhel9-only
./scripts/external/enable_repos.sh --include-optional
```

**Default repositories enabled:**
- `rhel-8-for-x86_64-baseos-rpms`
- `rhel-8-for-x86_64-appstream-rpms`
- `rhel-9-for-x86_64-baseos-rpms`
- `rhel-9-for-x86_64-appstream-rpms`

### 4. Sync Content

```bash
# Sync all enabled repositories
make sync

# Sync specific repository
./scripts/external/sync_repos.sh --repo rhel-9-for-x86_64-baseos-rpms

# Sync with all versions (not just newest)
./scripts/external/sync_repos.sh --all-versions
```

**Duration:** Initial sync may take several hours depending on bandwidth.

**Disk usage:** Approximately 30-50GB per repository.

### 5. Generate GPG Signing Key

```bash
# Generate new GPG key
make gpg-init

# Export public key
make gpg-export
```

The public key will be at `/data/keys/RPM-GPG-KEY-internal`.

### 6. Ingest Host Manifests

Collect manifests from internal hosts and transfer via hand-carry:

```bash
# On internal host
./scripts/host_collect_manifest.sh -o /mnt/usb/manifests

# Transfer USB to external builder

# Import manifests
make ingest MANIFEST_DIR=/mnt/usb/manifests

# Or process all from incoming directory
./scripts/external/ingest_manifests.sh --scan-incoming
```

### 7. Compute Updates

```bash
# Compute updates for all hosts
make compute

# Compute for specific host
./scripts/external/compute_updates.sh --host host-001
```

Results are written to `/data/updates/`.

### 8. Build Repositories

```bash
# Build all repositories with signing
make build-repos

# Build without signing
./scripts/external/build_repos.sh --no-sign
```

### 9. Export Bundle

```bash
# Create bundle with auto-generated version
make export BUNDLE_NAME=january-2024-patch

# Create bundle with specific version
./scripts/external/export_bundle.sh security-update --version 2024-01-15-001
```

**Output:**
- `/data/bundles/<bundle-name>.tar.gz` - Bundle archive
- `/data/bundles/<bundle-name>.tar.gz.sha256` - SHA256 checksum
- `/data/bundles/<bundle-name>.tar.gz.asc` - GPG signature

### 10. Transfer Bundle

```bash
# Copy to hand-carry media
cp /data/bundles/january-2024-patch-*.tar.gz* /mnt/usb/bundles/
```

## Configuration

### `/data/external.conf`

```bash
# Repository profiles to sync
PROFILES="rhel8 rhel9"

# Architectures to sync
ARCHITECTURES="x86_64"

# RHEL 8 repositories
RHEL8_REPOS="rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms"

# RHEL 9 repositories
RHEL9_REPOS="rhel-9-for-x86_64-baseos-rpms rhel-9-for-x86_64-appstream-rpms"

# Sync options
SYNC_NEWEST_ONLY=true
SYNC_DELETE=false

# GPG signing key ID
GPG_KEY_ID="ABC12345"
```

## Automation

### Cron Job for Regular Sync

```bash
# /etc/cron.d/rpm-sync
0 2 * * * root /opt/rpmserver/scripts/external/sync_repos.sh >> /var/log/rpmserver/sync.log 2>&1
```

### Scripted Bundle Creation

```bash
#!/bin/bash
# weekly-bundle.sh

set -euo pipefail

cd /opt/rpmserver

# Sync latest
./scripts/external/sync_repos.sh

# Build repos
./scripts/external/build_repos.sh

# Create weekly bundle
WEEK=$(date +%Y-W%V)
./scripts/external/export_bundle.sh "weekly-update" --version "${WEEK}"

echo "Bundle created: /data/bundles/weekly-update-${WEEK}.tar.gz"
```

## Troubleshooting

### Subscription Manager Issues

```bash
# Check status
subscription-manager status

# List available subscriptions
subscription-manager list --available

# Force clean and re-register
subscription-manager clean
subscription-manager register --force ...
```

### Sync Failures

```bash
# Check network connectivity
curl -I https://cdn.redhat.com

# Check repository configuration
dnf repolist -v

# Retry specific repo
./scripts/external/sync_repos.sh --repo <repo-id>
```

### GPG Issues

```bash
# List keys
./scripts/common/gpg_functions.sh list

# Re-export public key
./scripts/common/gpg_functions.sh export
```

## Unregistration

When decommissioning:

```bash
make sm-unregister
```

## Security Considerations

1. **Credentials**: Never embed credentials in scripts or configuration files
2. **GPG Keys**: Protect private key; only distribute public key
3. **Bundle Integrity**: Always include checksums and signatures
4. **Clean Up**: Remove sensitive data before disposing of hardware

## Related Documentation

- [Architecture](architecture.md)
- [Internal Workflow](internal_workflow.md)
- [Operations](operations.md)
