# Internal Publisher Workflow

This document describes the workflow for the Internal Publisher, which imports bundles and serves repositories to internal hosts.

## Prerequisites

- RHEL 9.6 VM (or container)
- Network access from internal hosts
- GPG public key from External Builder
- Imported bundle from hand-carry media

## Workflow Overview

```
1. Import bundle from hand-carry media
2. Verify bundle integrity and signatures
3. Publish to development channel
4. Test with dev hosts
5. Promote to production channel
6. Generate client configuration
7. Deploy configuration to internal hosts
```

## Step-by-Step Guide

### 1. Initialize Environment

```bash
# Initialize internal publisher
make init-internal

# Or manually
./rpmserverctl init-internal
```

This creates:
- `/data/bundles/` - Bundle storage (incoming, verified, archive)
- `/data/lifecycle/dev/` - Development channel
- `/data/lifecycle/prod/` - Production channel
- `/data/keys/` - GPG public key storage
- `/data/client-config/` - Client configuration files
- `/data/internal.conf` - Configuration file

### 2. Import GPG Public Key

First, import the GPG public key from the External Builder:

```bash
# Copy key from bundle or separate media
cp /mnt/usb/RPM-GPG-KEY-internal /data/keys/

# Import into GPG keyring
./scripts/common/gpg_functions.sh import /data/keys/RPM-GPG-KEY-internal
```

### 3. Import Bundle

```bash
# Import bundle from USB
make import BUNDLE_PATH=/mnt/usb/bundles/january-2024-patch-2024-01-15-001.tar.gz
```

The bundle is extracted to `/data/bundles/incoming/<bundle-name>/`.

### 4. Verify Bundle

```bash
# Verify bundle integrity and signatures
make verify
```

Verification checks:
- Bill of Materials (SHA256 checksums for all files)
- GPG signature on bundle archive
- GPG signatures on repository metadata (repomd.xml.asc)
- Bundle structure validation

Verified bundles are moved to `/data/bundles/verified/`.

### 5. Publish to Development Channel

```bash
# Publish verified bundle to dev channel
make publish LIFECYCLE=dev
```

This:
- Copies repositories to `/data/lifecycle/dev/repos/`
- Copies GPG keys to `/data/lifecycle/dev/keys/`
- Updates channel metadata

### 6. Test with Development Hosts

Configure a test host to use the dev channel:

```bash
# On test host
cat > /etc/yum.repos.d/internal-dev.repo << EOF
[internal-dev-baseos]
name=Internal Dev BaseOS
baseurl=http://publisher:8080/lifecycle/dev/repos/rhel9/x86_64/baseos/
enabled=1
gpgcheck=1
gpgkey=http://publisher:8080/lifecycle/dev/keys/RPM-GPG-KEY-internal

[internal-dev-appstream]
name=Internal Dev AppStream
baseurl=http://publisher:8080/lifecycle/dev/repos/rhel9/x86_64/appstream/
enabled=1
gpgcheck=1
gpgkey=http://publisher:8080/lifecycle/dev/keys/RPM-GPG-KEY-internal
EOF

# Test
dnf clean all
dnf repolist
dnf check-update
```

### 7. Promote to Production

After successful testing:

```bash
# Promote from dev to prod
make promote FROM=dev TO=prod
```

This:
- Copies repositories from dev to prod
- Archives previous prod content
- Updates channel metadata with history

### 8. Generate Client Configuration

```bash
# Generate repo files and install scripts
make generate-client-config
```

Output in `/data/client-config/`:
- `rhel8/internal.repo` - Repository configuration for RHEL 8
- `rhel8/install-repo.sh` - Installation script for RHEL 8
- `rhel9/internal.repo` - Repository configuration for RHEL 9
- `rhel9/install-repo.sh` - Installation script for RHEL 9
- `RPM-GPG-KEY-internal` - GPG public key
- `README.txt` - Installation instructions

### 9. Deploy to Internal Hosts

```bash
# Copy configuration to host
scp -r /data/client-config/rhel9 root@host:/tmp/repo-config/

# On host: run installation
ssh root@host "cd /tmp/repo-config/rhel9 && ./install-repo.sh"
```

## Lifecycle Channels

### Channel Structure

```
/data/lifecycle/
├── dev/
│   ├── repos/
│   │   └── rhel9/x86_64/baseos/
│   │   └── rhel9/x86_64/appstream/
│   ├── keys/
│   │   └── RPM-GPG-KEY-internal
│   └── metadata.json
└── prod/
    ├── repos/
    ├── keys/
    └── metadata.json
```

### Channel Metadata

```json
{
    "channel": "prod",
    "created": "2024-01-01T00:00:00Z",
    "current_bundle": "january-2024-patch-2024-01-15-001",
    "last_updated": "2024-01-15T10:00:00Z",
    "history": [
        {
            "bundle": "january-2024-patch-2024-01-15-001",
            "promoted_from": "dev",
            "promoted_at": "2024-01-15T10:00:00Z"
        }
    ]
}
```

### Rollback Procedure

To rollback to a previous bundle:

```bash
# List available bundles
ls /data/bundles/verified/

# Re-publish previous bundle
./scripts/internal/publish_repos.sh prod --bundle december-2023-patch-2023-12-15-001

# Or use archived content
ls /data/lifecycle/prod/.archive/
```

## HTTP Server Configuration

The internal publisher serves repositories via Apache HTTP Server on port 8080.

### URL Structure

| URL | Content |
|-----|---------|
| `/lifecycle/dev/` | Development channel |
| `/lifecycle/prod/` | Production channel |
| `/keys/` | GPG public keys |
| `/repos/` | Direct repository access |

### Client Configuration

**RHEL 9 Production:**

```ini
[internal-baseos]
name=Internal BaseOS
baseurl=http://publisher:8080/lifecycle/prod/repos/rhel9/x86_64/baseos/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-internal
```

## Troubleshooting

### Bundle Import Issues

```bash
# Check bundle structure
tar -tzf /path/to/bundle.tar.gz | head

# Extract manually
mkdir /tmp/bundle-test
tar -xzf /path/to/bundle.tar.gz -C /tmp/bundle-test

# Verify BOM manually
cd /tmp/bundle-test/*
python3 -c "
import json, hashlib
with open('BILL_OF_MATERIALS.json') as f:
    bom = json.load(f)
for f in bom['files'][:5]:
    print(f['path'])
"
```

### Verification Failures

```bash
# Check GPG key
./scripts/common/gpg_functions.sh list

# Manually verify signature
gpg --verify /path/to/file.asc /path/to/file
```

### HTTP Server Issues

```bash
# Check httpd status
systemctl status httpd

# Check logs
tail -f /var/log/rpmserver/httpd-error.log

# Test locally
curl http://localhost:8080/repos/
```

### Client Connection Issues

```bash
# On client: test connectivity
curl http://publisher:8080/repos/

# Check repository
dnf repolist -v

# Clear cache
dnf clean all
```

## Security Considerations

1. **Bundle Verification**: Always verify bundles before publishing
2. **GPG Validation**: Ensure GPG key is from trusted source
3. **Firewall**: Limit access to internal hosts only
4. **HTTPS**: Consider enabling HTTPS for additional security
5. **Access Control**: Restrict SSH access to administrators

## Related Documentation

- [Architecture](architecture.md)
- [External Workflow](external_workflow.md)
- [VMware Deployment](vmware_deploy_internal.md)
- [Operations](operations.md)
