# Architecture

This document describes the architecture of the Airgapped Two-Tier RPM Repository System.

## System Overview

The system implements a two-tier architecture designed for airgapped environments:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL ENVIRONMENT                               │
│  ┌─────────────────┐         ┌─────────────────────────────────────────┐   │
│  │   Red Hat CDN   │────────▶│         EXTERNAL BUILDER                │   │
│  │  (Internet)     │         │                                         │   │
│  └─────────────────┘         │  Components:                            │   │
│                              │  - subscription-manager                 │   │
│                              │  - dnf reposync                         │   │
│                              │  - Update calculator                    │   │
│                              │  - Bundle creator                       │   │
│                              │                                         │   │
│                              │  Data:                                  │   │
│                              │  - /data/mirror/                        │   │
│                              │  - /data/manifests/                     │   │
│                              │  - /data/bundles/                       │   │
│                              └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Hand-carry (USB/media)
                                          │ - Signed repository bundles
                                          │ - GPG public keys
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INTERNAL ENVIRONMENT (Airgapped)                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    INTERNAL PUBLISHER (RHEL 9.6 VM)                  │   │
│  │                                                                      │   │
│  │  Components:                                                         │   │
│  │  - HTTP/HTTPS server (Apache)                                       │   │
│  │  - Bundle importer/verifier                                         │   │
│  │  - Lifecycle manager                                                │   │
│  │                                                                      │   │
│  │  Data:                                                               │   │
│  │  - /data/bundles/     (incoming, verified, archive)                 │   │
│  │  - /data/lifecycle/   (dev, prod channels)                          │   │
│  │  - /data/keys/        (GPG public keys)                             │   │
│  │                                                                      │   │
│  │  Endpoints:                                                          │   │
│  │  - http://publisher:8080/lifecycle/dev/                             │   │
│  │  - http://publisher:8080/lifecycle/prod/                            │   │
│  │  - http://publisher:8080/keys/                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│              ┌───────────────┼───────────────┐                             │
│              ▼               ▼               ▼                             │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                  │
│  │  RHEL 8.10    │  │  RHEL 9.6     │  │  RHEL 9.6     │                  │
│  │  Host         │  │  Host         │  │  Host         │                  │
│  │               │  │               │  │               │                  │
│  │  DNF config:  │  │  DNF config:  │  │  DNF config:  │                  │
│  │  internal.repo│  │  internal.repo│  │  internal.repo│                  │
│  └───────────────┘  └───────────────┘  └───────────────┘                  │
│         │                   │                   │                          │
│         └───────────────────┴───────────────────┘                          │
│                             │                                              │
│                    Host manifests (hand-carry out)                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Data Flows

### 1. Content Sync Flow

```
Red Hat CDN
    │
    ▼
subscription-manager (auth)
    │
    ▼
dnf reposync (download)
    │
    ▼
/data/mirror/<profile>/<arch>/<channel>/
    │
    ▼
createrepo_c (metadata)
    │
    ▼
GPG signing (repomd.xml.asc)
```

### 2. Host Manifest Flow

```
Internal Host
    │
    ▼
host_collect_manifest.sh
    │
    ▼
Manifest tarball (hand-carry)
    │
    ▼
External Builder
    │
    ▼
/data/manifests/processed/<host_id>/
    │
    ▼
Update computation
```

### 3. Bundle Export Flow

```
/data/repos/
    │
    ▼
export_bundle.sh
    │
    ▼
BILL_OF_MATERIALS.json (SHA256)
    │
    ▼
GPG signature (bundle.tar.gz.asc)
    │
    ▼
Hand-carry media
```

### 4. Bundle Import Flow

```
Hand-carry media
    │
    ▼
import_bundle.sh
    │
    ▼
/data/bundles/incoming/
    │
    ▼
verify_bundle.sh (BOM + GPG)
    │
    ▼
/data/bundles/verified/
    │
    ▼
publish_repos.sh
    │
    ▼
/data/lifecycle/<channel>/
```

## Directory Structure

### External Builder

```
/data/
├── mirror/                 # Mirrored repository content
│   ├── rhel8/
│   │   └── x86_64/
│   │       ├── baseos/
│   │       └── appstream/
│   └── rhel9/
│       └── x86_64/
│           ├── baseos/
│           └── appstream/
├── manifests/              # Host manifests
│   ├── incoming/           # New manifests
│   ├── processed/          # Indexed manifests
│   │   └── <host_id>/
│   │       └── latest/
│   │           └── manifest.json
│   └── index/
│       └── manifest_index.json
├── updates/                # Update computation results
│   ├── <host_id>/
│   │   └── updates.json
│   └── summary.json
├── repos/                  # Built repositories
│   └── <profile>/<arch>/<channel>/
├── bundles/                # Export bundles
│   └── <bundle_name>.tar.gz
├── keys/                   # GPG keys
│   ├── .gnupg/             # GPG keyring
│   └── RPM-GPG-KEY-internal
└── external.conf           # Configuration
```

### Internal Publisher

```
/data/
├── bundles/
│   ├── incoming/           # Imported bundles
│   ├── verified/           # Verified bundles
│   └── archive/            # Historical bundles
├── lifecycle/
│   ├── dev/                # Development channel
│   │   ├── repos/
│   │   ├── keys/
│   │   └── metadata.json
│   └── prod/               # Production channel
│       ├── repos/
│       ├── keys/
│       └── metadata.json
├── client-config/          # Client configuration files
│   ├── rhel8/
│   │   ├── internal.repo
│   │   └── install-repo.sh
│   └── rhel9/
│       ├── internal.repo
│       └── install-repo.sh
├── keys/
│   └── RPM-GPG-KEY-internal
└── internal.conf           # Configuration
```

## Security Boundaries

### Trust Zones

1. **External Zone** (Internet-connected)
   - External builder server
   - Red Hat CDN access
   - No direct access to internal network

2. **Transfer Zone** (Air gap)
   - Hand-carry media only
   - Signed and checksummed bundles
   - No electronic network connection

3. **Internal Zone** (Airgapped)
   - Internal publisher
   - Internal RHEL hosts
   - No outbound network access

### Cryptographic Controls

- GPG signing of repository metadata (repomd.xml.asc)
- GPG signing of bundle archives
- SHA256 checksums for all files (Bill of Materials)
- HTTPS optional for internal publishing

## Component Details

### External Builder Container

- Base: UBI 9
- Key packages: subscription-manager, dnf-plugins-core, createrepo_c, gnupg2
- Purpose: Sync content, compute updates, create bundles

### Internal Publisher Container

- Base: UBI 9
- Key packages: httpd, createrepo_c, gnupg2
- Purpose: Serve repositories to internal hosts

### Internal Publisher VM (OVA)

- OS: RHEL 9.6
- Hardened per DISA STIG
- Packages: podman, openscap-scanner, scap-security-guide
- Purpose: Production deployment in VMware

## Lifecycle Management

### Channels

1. **dev** - Development/testing channel
   - New bundles published here first
   - Used for validation before production

2. **prod** - Production channel
   - Promoted from dev after testing
   - Used by production hosts

### Promotion Flow

```
Bundle Imported → Verified → Published to dev → Tested → Promoted to prod
```

### Rollback

Rollback is supported through:
- Archived bundles in `/data/bundles/archive/`
- Channel history in `metadata.json`
- Re-importing previous bundles
