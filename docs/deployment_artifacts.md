# Deployment Artifacts Inventory

## Overview

This document provides a complete inventory of all artifacts required for deploying and operating the airgapped RPM repository infrastructure. Artifacts are categorized by their source (operator-supplied, automation-generated, or runtime-generated) and lifecycle phase.

The system consists of two RHEL 9.6 servers:
- **rpm-external**: Internet-connected server that syncs packages from Red Hat CDN
- **rpm-internal**: Airgapped server hosting the internal RPM repository

---

## Artifact Categories

| Category | Description | Example |
|----------|-------------|---------|
| Operator-Supplied | Provided by operator before deployment | RHEL ISO, vCenter credentials |
| Automation-Generated | Created by automation scripts during deployment | Kickstart ISOs, Ansible inventory |
| Runtime-Generated | Created during system operation | Package bundles, manifests, TLS certs |

---

## Operator-Supplied Inputs

### Required Files

| Artifact | Path/Location | Description | Validation |
|----------|---------------|-------------|------------|
| RHEL 9.6 DVD ISO | `isos.rhel96_iso_path` in spec.yaml | Base OS installation media | File exists, checksum matches |
| config/spec.yaml | `config/spec.yaml` | Primary deployment configuration | `make validate-spec` |
| vCenter credentials | `VMWARE_USER`, `VMWARE_PASSWORD` env vars | VMware authentication | Connection test during discovery |

### Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `VMWARE_USER` | vCenter/ESXi username | Yes (if not in spec.yaml) |
| `VMWARE_PASSWORD` | vCenter/ESXi password | Yes (if not in spec.yaml) |

### Configuration Structure (config/spec.yaml)

```yaml
vcenter:
  server: ""          # vCenter or ESXi host address
  datacenter: ""      # Datacenter name (vCenter only)
  cluster: ""         # Cluster name or ESXi host
  datastore: ""       # Storage datastore
  folder: ""          # Optional: VM folder path
  resource_pool: ""   # Optional: Resource pool

network:
  portgroup_name: ""  # VM network port group (must be DHCP-enabled)
  dhcp: true          # Required: static IP not supported

isos:
  rhel96_iso_path: "" # Path to RHEL 9.6 ISO
  iso_datastore_folder: "" # Datastore folder for ISOs

vm_names:
  rpm_external: ""    # External server VM name
  rpm_internal: ""    # Internal server VM name

vm_sizing:
  external:
    cpu: 2
    memory_gb: 8
    disk_gb: 200
  internal:
    cpu: 2
    memory_gb: 8
    disk_gb: 200

credentials:
  initial_root_password: ""
  initial_admin_user: ""
  initial_admin_password: ""
```

---

## Automation-Generated Artifacts

### vSphere Discovery Phase (`make vsphere-discover`)

| Artifact | Path | Description |
|----------|------|-------------|
| vsphere-defaults.json | `automation/artifacts/vsphere-defaults.json` | Discovered vSphere resources |
| spec.detected.yaml | `automation/artifacts/spec.detected.yaml` | Auto-populated spec template |

### Kickstart ISO Generation (`make generate-ks-iso`)

| Artifact | Path | Description |
|----------|------|-------------|
| rpm-external kickstart ISO | `output/ks-isos/ks-rpm-external.iso` | Kickstart config for external server |
| rpm-internal kickstart ISO | `output/ks-isos/ks-rpm-internal.iso` | Kickstart config for internal server |

### Inventory Generation (`make render-inventory`)

| Artifact | Path | Description |
|----------|------|-------------|
| Generated Ansible inventory | `ansible/inventories/generated.yml` | Auto-generated from spec.yaml |

### OVA Build Phase (`make build-ovas`)

| Artifact | Path | Description |
|----------|------|-------------|
| External server OVA | `automation/artifacts/ovas/rpm-external.ova` | Exportable external server appliance |
| Internal server OVA | `automation/artifacts/ovas/rpm-internal.ova` | Exportable internal server appliance |

### E2E Test Reports (`make e2e`)

| Artifact | Path | Description |
|----------|------|-------------|
| E2E report (Markdown) | `automation/artifacts/e2e/report.md` | Human-readable test report |
| E2E report (JSON) | `automation/artifacts/e2e/report.json` | Machine-readable test results |

---

## Runtime-Generated Artifacts

### On External Server (rpm-external)

| Artifact | Path | Description |
|----------|------|-------------|
| Synced repository mirror | `/var/lib/airgap-rpm/sync/` | Mirrored packages from Red Hat CDN |
| Export bundles | `/var/lib/airgap-rpm/export/` | Prepared hand-carry bundles |
| Host manifests (received) | `/var/lib/airgap-rpm/manifests/` | Manifests from managed hosts |

### On Internal Server (rpm-internal)

| Artifact | Path | Description |
|----------|------|-------------|
| Repository content (testing) | `/var/lib/airgap-rpm/repo/testing/` | Newly imported packages |
| Repository content (stable) | `/var/lib/airgap-rpm/repo/stable/` | Production-ready packages |
| TLS certificates | `/var/lib/airgap-rpm/tls/` | Server TLS cert and key |
| Import staging | `/var/lib/airgap-rpm/import/` | Bundle import working directory |
| Host manifests | `/var/lib/airgap-rpm/manifests/` | Package manifests from managed hosts |
| Backups | `/var/lib/airgap-rpm/backups/` | Repository content backups |

### On Managed Hosts

| Artifact | Path | Description |
|----------|------|-------------|
| Repository configuration | `/etc/yum.repos.d/airgap-*.repo` | DNF repository definitions |
| CA trust bundle | `/etc/pki/tls/certs/airgap-ca.crt` | Internal repo CA certificate |
| Syslog TLS CA | `/etc/pki/tls/certs/syslog-ca.crt` | Syslog server CA certificate |

---

## Directory Structure Reference

### Repository Root
```
airgapped-rpm-repo/
├── ansible/
│   ├── inventories/
│   │   ├── generated.yml          # Auto-generated from spec.yaml
│   │   └── lab.yml                 # Lab environment inventory
│   ├── playbooks/
│   │   ├── bootstrap_ssh_keys.yml
│   │   ├── collect_manifests.yml
│   │   ├── onboard_hosts.yml
│   │   ├── patch_monthly_security.yml
│   │   ├── replace_repo_tls_cert.yml
│   │   └── stig_harden_internal_vm.yml
│   └── roles/
├── automation/
│   ├── artifacts/                  # Generated artifacts directory
│   │   ├── e2e/                    # E2E test reports
│   │   ├── ovas/                   # Built OVA files
│   │   ├── vsphere-defaults.json   # Discovery output
│   │   └── spec.detected.yaml      # Auto-populated spec
│   ├── powercli/
│   │   ├── deploy-rpm-servers.ps1
│   │   ├── destroy-rpm-servers.ps1
│   │   ├── discover-vsphere-defaults.ps1
│   │   ├── generate-ks-iso.ps1
│   │   ├── upload-isos.ps1
│   │   ├── wait-for-dhcp-and-report.ps1
│   │   └── wait-for-install-complete.ps1
│   └── scripts/
│       ├── render-inventory.py
│       ├── run-e2e-tests.sh
│       ├── validate-operator-guide.sh
│       └── validate-spec.sh
├── config/
│   └── spec.yaml                   # Primary configuration file
├── docs/
│   ├── deployment_guide.md
│   ├── administration_guide.md
│   └── deployment_artifacts.md     # This document
├── kickstart/
│   ├── ks-rpm-external.cfg
│   └── ks-rpm-internal.cfg
├── output/
│   └── ks-isos/                    # Generated kickstart ISOs
├── scripts/
│   ├── external/                   # Scripts for external server
│   │   ├── export_bundle.sh
│   │   ├── sync_repos.sh
│   │   └── ...
│   └── internal/                   # Scripts for internal server
│       ├── import_bundle.sh
│       ├── promote_lifecycle.sh
│       └── ...
└── Makefile
```

---

## Minimal Deployment Bundle

For airgapped deployment of a new environment, the following files constitute the minimal transfer bundle:

### Required for Initial Deployment

| File | Size (approx) | Purpose |
|------|---------------|---------|
| RHEL 9.6 DVD ISO | ~10 GB | Base OS installation |
| ks-rpm-external.iso | ~1 MB | External server kickstart |
| ks-rpm-internal.iso | ~1 MB | Internal server kickstart |
| spec.yaml (sanitized) | ~3 KB | Deployment configuration |

### Required for Ongoing Operations

| File | Size (approx) | Purpose |
|------|---------------|---------|
| Package bundle (monthly) | Varies | RPM updates for import |
| Host manifests | ~10 KB/host | Package inventory for external server |

### Optional OVA Deployment

| File | Size (approx) | Purpose |
|------|---------------|---------|
| rpm-external.ova | ~3 GB | Pre-built external server |
| rpm-internal.ova | ~3 GB | Pre-built internal server |

---

## Artifact Validation Checklist

### Pre-Deployment Validation

- [ ] RHEL 9.6 ISO exists and checksum verified
- [ ] `config/spec.yaml` populated with environment values
- [ ] `make validate-spec` passes without errors
- [ ] vCenter/ESXi credentials functional (`make vsphere-discover` succeeds)
- [ ] Network port group exists and has DHCP enabled
- [ ] Datastore has sufficient free space (≥500 GB recommended)

### Post-Deployment Validation

- [ ] Both VMs powered on and have IP addresses (`make servers-report`)
- [ ] SSH access works: `ssh admin@<ip>`
- [ ] Repository service running: `systemctl --user -M rpmops@ status airgap-rpm-publisher.service`
- [ ] Repository accessible: `curl -k https://<internal-ip>/repo/stable/`
- [ ] TLS certificate valid: `openssl s_client -connect <internal-ip>:8443`

### Operational Validation

- [ ] Package sync completes on external server
- [ ] Bundle export creates valid tarball with BILL_OF_MATERIALS.json
- [ ] Bundle import succeeds on internal server
- [ ] Lifecycle promotion (testing → stable) works
- [ ] Managed hosts can install packages from internal repository
- [ ] Manifest collection returns valid JSON

### Makefile Targets Reference

| Target | Description | Prerequisites |
|--------|-------------|---------------|
| `vsphere-discover` | Discover vSphere environment | vCenter credentials |
| `spec-init` | Initialize spec.yaml from discovery | `vsphere-discover` |
| `validate-spec` | Validate spec.yaml | spec.yaml exists |
| `generate-ks-iso` | Generate kickstart ISOs | `validate-spec` |
| `servers-deploy` | Deploy VMs | `validate-spec`, ISOs |
| `servers-report` | Report VM IPs | VMs deployed |
| `servers-wait` | Wait for installation | VMs deployed |
| `e2e` | Run E2E tests | VMs accessible |
| `build-ovas` | Export VMs as OVAs | E2E passed |
| `ansible-onboard` | Onboard managed hosts | `render-inventory` |
| `manifests` | Collect package manifests | `render-inventory` |
| `patch` | Apply security patches | `render-inventory` |
| `import` | Import package bundle | Bundle path |
| `promote` | Promote lifecycle | FROM, TO args |
| `servers-destroy` | Destroy VMs | VMs exist |
