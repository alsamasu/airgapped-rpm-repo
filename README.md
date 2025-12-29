# Airgapped Two-Tier RPM Repository System

A complete, production-ready solution for managing RHEL package distribution in airgapped environments. This system implements a two-tier architecture with an internet-connected external builder and an offline internal publisher.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL ENVIRONMENT                               │
│  ┌─────────────────┐         ┌─────────────────────────────────────────┐   │
│  │   Red Hat CDN   │────────▶│         EXTERNAL BUILDER                │   │
│  │  (Internet)     │         │  - subscription-manager registration    │   │
│  └─────────────────┘         │  - dnf reposync mirroring               │   │
│                              │  - Manifest ingestion                   │   │
│                              │  - Update computation                   │   │
│                              │  - Signed bundle creation               │   │
│                              └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Hand-carry (USB/media)
                                          │ - Signed repository bundles
                                          │ - GPG keys
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INTERNAL ENVIRONMENT (Airgapped)                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    INTERNAL PUBLISHER (RHEL 9.6 VM)                  │   │
│  │  - Bundle import & verification                                      │   │
│  │  - HTTP(S) repository serving                                        │   │
│  │  - Lifecycle channels (dev/prod)                                     │   │
│  │  - Client configuration distribution                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│              ┌───────────────┼───────────────┐                             │
│              ▼               ▼               ▼                             │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                  │
│  │  RHEL 8.10    │  │  RHEL 9.6     │  │  RHEL 9.6     │                  │
│  │  Host         │  │  Host         │  │  Host         │                  │
│  └───────────────┘  └───────────────┘  └───────────────┘                  │
│         │                   │                   │                          │
│         └───────────────────┴───────────────────┘                          │
│                             │                                              │
│                    Host manifests (hand-carry out)                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **Subscription-manager integration**: Proper Red Hat CDN authentication
- **Offline-capable**: Internal publisher requires no network connectivity
- **GPG signing**: All repository metadata is cryptographically signed
- **Lifecycle management**: Dev/Prod channels with promotion workflow
- **DISA STIG compliance**: Hardening guidance and OpenSCAP integration
- **NIST SP 800-53 mapping**: Control implementation documentation
- **VMware deployment**: Packer-built OVA for internal publisher
- **Container-native**: Podman/Docker deployment options
- **CI/CD ready**: GitHub Actions with security scanning

## Quick Start

### Prerequisites

- RHEL 8.10 or 9.6 (for production use)
- Podman or Docker
- GNU Make
- GPG for signing operations
- Valid Red Hat subscription (external builder only)

### Development Environment

```bash
# Clone repository
git clone https://github.com/your-org/airgapped-rpm-repo.git
cd airgapped-rpm-repo

# Start development environment
make build
docker compose up -d

# Run tests
make test
```

### External Builder Setup

```bash
# Initialize external builder
make init-external

# Register with Red Hat (interactive - requires credentials)
make sm-register ACTIVATION_KEY=your-key ORG_ID=your-org
# OR
make sm-register SM_USER=your-username SM_PASS=your-password

# Enable repositories
make enable-repos

# Sync content
make sync

# Ingest host manifests
make ingest MANIFEST_DIR=/path/to/manifests

# Compute updates
make compute

# Build repositories
make build-repos

# Export bundle for hand-carry
make export BUNDLE_NAME=2024-01-release
```

### Internal Publisher Setup

```bash
# Initialize internal publisher
make init-internal

# Import hand-carried bundle
make import BUNDLE_PATH=/media/usb/bundles/2024-01-release.tar.gz

# Verify bundle integrity
make verify

# Publish to dev channel
make publish LIFECYCLE=dev

# Promote to prod after testing
make promote FROM=dev TO=prod
```

### Build VMware OVA (Internal Publisher)

```bash
# Validate Packer configuration
make packer-validate

# Build OVA (requires RHEL 9.6 ISO)
make packer-build-internal ISO_PATH=/path/to/rhel-9.6-x86_64-dvd.iso
```

## Project Structure

```
/
├── Dockerfile                    # Container image definition
├── docker-compose.yml            # Development environment
├── Makefile                      # Build and operation targets
├── rpmserverctl                  # Main control script
├── scripts/
│   ├── host_collect_manifest.sh  # Host inventory collection
│   ├── common/                   # Shared functions
│   ├── external/                 # External builder scripts
│   ├── internal/                 # Internal publisher scripts
│   ├── run_openscap.sh          # OpenSCAP evaluation
│   └── generate_ckl.sh          # STIG checklist generation
├── packer/                       # VMware OVA build
├── docs/                         # Documentation
├── compliance/                   # Security artifacts
├── .github/workflows/            # CI/CD pipelines
├── testdata/                     # Test fixtures
└── src/                          # Python modules
```

## Documentation

- [Architecture](docs/architecture.md) - System design and data flows
- [External Workflow](docs/external_workflow.md) - External builder operations
- [Internal Workflow](docs/internal_workflow.md) - Internal publisher operations
- [VMware Deployment](docs/vmware_deploy_internal.md) - OVA build and deployment
- [Operations](docs/operations.md) - Day-to-day operations guide
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [Threat Model](docs/threat_model.md) - Security analysis
- [STIG Hardening](docs/stig_hardening_internal.md) - DISA STIG guidance
- [NIST 800-53 Mapping](docs/nist_80053_mapping.md) - Control mapping
- [Security Boundary](docs/security_boundary.md) - System boundary definition
- [Minimal SSP](docs/minimal_ssp.md) - System Security Plan

## Security

This project implements security controls aligned with:
- DISA STIG for RHEL 9
- NIST SP 800-53 Rev 5

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.
