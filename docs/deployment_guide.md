# Deployment Guide

## Overview

This guide covers the deployment of the airgapped RPM repository infrastructure consisting of two RHEL 9.6 servers:

- **External Server** (`rpm-external`): Internet-connected system that syncs packages from Red Hat CDN and prepares bundles for hand-carry transfer
- **Internal Server** (`rpm-internal`): Airgapped system that hosts the internal RPM repository serving managed RHEL hosts

The deployment automation uses VMware PowerCLI scripts with kickstart injection for fully automated installation. Two deployment methods are available:

1. **Kickstart ISO Injection**: Direct deployment from RHEL 9.6 ISO with automated kickstart configuration
2. **OVA Deployment**: Pre-built appliance images with first-boot customization via OVF properties

All automation artifacts reside in the repository under `automation/powercli/` and `automation/kickstart/`.

---

## Deployment Inputs

### Required Files

1. RHEL 9.6 DVD ISO image (downloaded from Red Hat Customer Portal)
2. VMware vCenter credentials with VM deployment permissions
3. Completed `config/spec.yaml` configuration file

### Configuration File: config/spec.yaml

The primary configuration file controls all deployment parameters:

```yaml
vcenter:
  server: "vcenter.example.local"
  datacenter: "Datacenter"
  cluster: "Cluster01"
  datastore: "datastore1"
  folder: ""  # Optional: VM folder path
  resource_pool: ""  # Optional
  # Credentials via environment: VMWARE_USER, VMWARE_PASSWORD

network:
  portgroup_name: "LAN"
  dhcp: true  # Required; static IP not supported in automated install

isos:
  rhel96_iso_path: "/isos/rhel-9.6-x86_64-dvd.iso"
  iso_datastore_folder: "isos"

vm_names:
  rpm_external: "rpm-external"
  rpm_internal: "rpm-internal"

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
  initial_root_password: "ChangeMe123!"
  initial_admin_user: "admin"
  initial_admin_password: "ChangeMe123!"

compliance:
  enable_fips: true
```

### Generating Initial Configuration

1. Run the spec initialization target:
   ```bash
   make spec-init
   ```

2. Edit `config/spec.yaml` with your environment values

3. Validate the configuration:
   ```bash
   make validate-spec
   ```

---

## vSphere Environment Discovery

1. Execute the discovery target:
   ```bash
   make vsphere-discover
   ```

2. Review the generated discovery output:
   ```bash
   cat automation/artifacts/vsphere-defaults.json
   cat automation/artifacts/spec.detected.yaml
   ```

---

## Deployment Method Selection

### Method 1: Kickstart ISO Injection (Recommended for Initial Deployment)

**Use when:** Deploying for the first time, FIPS mode needed, custom partitioning required.

### Method 2: OVA Deployment (Recommended for Replication)

**Use when:** Deploying additional instances, faster deployment preferred.

---

## Kickstart ISO Deployment

### Step 1: Generate Kickstart ISOs

```bash
make generate-ks-iso
```

Alternatively, run the PowerCLI script directly:
```bash
pwsh automation/powercli/generate-ks-iso.ps1 -SpecPath config/spec.yaml
```

### Step 2: Deploy VMs

```bash
make servers-deploy
```

### Step 3: Wait for Installation and Discover IPs

Wait for VMs to complete installation and obtain DHCP-assigned IPs:
```bash
make servers-wait
make servers-report
```

### Step 4: Validate Installation

Using the IPs from `servers-report`:
```bash
ssh admin@<internal-ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"
curl -k https://<internal-ip>/repo/stable/
```

---

## OVA Deployment

### Step 1: Build OVA Images

```bash
make build-ovas
```

### Step 2: Deploy from OVA

Deploy through vSphere Client or PowerCLI with OVF properties for hostname and network configuration.

---

## Post-Install Validation

Run the E2E test suite:
```bash
make e2e
```

Reports are generated in `automation/artifacts/e2e/`.

---

## Initial System State

| Component | State |
|-----------|-------|
| Repository Service | Running under rpmops user |
| TLS Certificate | Self-signed (replace for production) |
| Repository Content | Empty (import first bundle) |

---

## Deployment Troubleshooting

### Kickstart Installation Fails
- Verify kickstart ISO has OEMDRV volume label
- Verify both ISOs are attached to VM

### Repository Service Not Accessible
- Check service: `systemctl --user -M rpmops@ status airgap-rpm-publisher.service`
- Check firewall: `sudo firewall-cmd --list-ports`
