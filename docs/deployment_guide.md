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
  server: vcenter.example.com
  username: administrator@vsphere.local
  password: "vCenterPassword"
  datacenter: Datacenter
  cluster: Cluster
  datastore: datastore1
  network: "VM Network"
  folder: "/Datacenter/vm/RPM-Infrastructure"

vms:
  external:
    name: rpm-external
    hostname: rpm-external.example.com
    ip: ""
    cpu: 4
    memory_gb: 8
    disk_gb: 200
  internal:
    name: rpm-internal
    hostname: rpm-internal.example.com
    ip: ""
    cpu: 4
    memory_gb: 16
    disk_gb: 500

credentials:
  root_password: "SecureRootPassword"
  rpmops_password: "SecureOpsPassword"

options:
  fips_mode: false
  timezone: America/New_York

iso_path: /path/to/rhel-9.6-x86_64-dvd.iso
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
   cat output/vsphere-defaults.json
   cat output/spec.detected.yaml
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
pwsh automation/powercli/generate-ks-iso.ps1 -SpecFile config/spec.yaml
```

### Step 2: Deploy VMs

```bash
make servers-deploy
```

### Step 3: Validate Installation

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

```bash
make e2e INVENTORY=inventories/lab.yml
```

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
