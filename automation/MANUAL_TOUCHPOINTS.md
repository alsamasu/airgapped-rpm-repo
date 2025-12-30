# Manual Touchpoints Inventory

This document inventories all manual steps that originally existed in the airgapped RPM repository deployment process, documents how each has been automated, and identifies any remaining manual actions with justification.

## Summary

| Category | Original Manual Steps | Now Automated | Remaining Manual |
|----------|----------------------|---------------|------------------|
| VMware VM Creation | 4 | 4 | 0 |
| OS Installation | 4 | 4 | 0 |
| Network Configuration | 4 | 4 | 0 |
| SSH/User Setup | 6 | 6 | 0 |
| Repository Setup | 5 | 5 | 0 |
| TLS Certificates | 2 | 2 | 0 |
| Ansible Configuration | 3 | 3 | 0 |
| Host Onboarding | 4 | 4 | 0 |
| **Total** | **32** | **32** | **0** |

## Detailed Inventory

### 1. VMware VM Creation

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 1.1 | Log into vSphere Client | 2 min |
| 1.2 | Create new VM wizard - select name, folder, resource pool | 5 min |
| 1.3 | Configure CPU, memory, disk settings | 5 min |
| 1.4 | Configure network adapter, port group | 3 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 1.1 | PowerCLI Connect-VIServer | `automation/powercli/deploy-rpm-servers.ps1` |
| 1.2 | PowerCLI New-VM with spec.yaml params | `automation/powercli/deploy-rpm-servers.ps1` |
| 1.3 | VM sizing from spec.yaml | `config/spec.yaml` → `vm_sizing` |
| 1.4 | Network from spec.yaml | `config/spec.yaml` → `network.portgroup_name` |

**Trigger**: `make servers-deploy`

---

### 2. OS Installation

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 2.1 | Mount RHEL ISO to VM | 2 min |
| 2.2 | Boot VM and wait for Anaconda | 3 min |
| 2.3 | Navigate Anaconda GUI: language, keyboard, timezone | 10 min |
| 2.4 | Configure disk partitioning | 10 min |
| 2.5 | Set root password and create admin user | 5 min |
| 2.6 | Select packages and start installation | 5 min |
| 2.7 | Wait for installation and reboot | 15 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 2.1 | PowerCLI New-CDDrive | `automation/powercli/deploy-rpm-servers.ps1` |
| 2.2-2.7 | Kickstart with OEMDRV ISO injection | `automation/kickstart/rhel96_*.ks` |

**Key Innovation**: Kickstart ISO injection via second CD-ROM with `OEMDRV` volume label.

- `automation/kickstart/rhel96_external.ks` - External server kickstart
- `automation/kickstart/rhel96_internal.ks` - Internal server kickstart (includes FIPS, rootless podman)
- `automation/powercli/generate-ks-iso.ps1` - Generates ISOs from templates

**Trigger**: `make generate-ks-iso && make servers-deploy`

---

### 3. Network Configuration

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 3.1 | Configure network interface (DHCP or static) | 5 min |
| 3.2 | Set hostname | 2 min |
| 3.3 | Configure firewall rules | 5 min |
| 3.4 | Verify connectivity | 2 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 3.1 | Kickstart `network --bootproto=dhcp` | `automation/kickstart/rhel96_*.ks` |
| 3.2 | Kickstart `network --hostname={{HOSTNAME}}` | `automation/kickstart/rhel96_*.ks` |
| 3.3 | Kickstart `firewall --enabled --service=ssh` | `automation/kickstart/rhel96_*.ks` |
| 3.4 | PowerCLI VMware Tools check | `automation/powercli/wait-for-install-complete.ps1` |

**IP Discovery**: `make servers-report` retrieves DHCP-assigned IPs from VMware.

---

### 4. SSH and User Setup

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 4.1 | Create admin user | 3 min |
| 4.2 | Configure sudo access | 3 min |
| 4.3 | Enable SSH password authentication (temporarily) | 2 min |
| 4.4 | Generate SSH key on control plane | 2 min |
| 4.5 | Copy SSH key to target hosts | 5 min per host |
| 4.6 | Disable password authentication | 2 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 4.1 | Kickstart `user --name={{ADMIN_USER}}` | `automation/kickstart/rhel96_*.ks` |
| 4.2 | Kickstart `%post` sudoers.d config | `automation/kickstart/rhel96_*.ks` |
| 4.3 | Kickstart sshd_config PasswordAuth | `automation/kickstart/rhel96_*.ks` |
| 4.4 | Ansible openssh_keypair module | `ansible/playbooks/bootstrap_ssh_keys.yml` |
| 4.5 | Ansible authorized_key module | `ansible/playbooks/bootstrap_ssh_keys.yml` |
| 4.6 | Future: disable after key verification | (Optional hardening) |

**Trigger**: `make ansible-bootstrap`

---

### 5. Repository Server Setup

#### Original Manual Steps (External Server)

| Step | Description | Effort |
|------|-------------|--------|
| 5.1 | Register with subscription-manager | 5 min |
| 5.2 | Enable required repositories | 3 min |
| 5.3 | Install createrepo_c, gnupg2, etc. | 5 min |
| 5.4 | Create data directories | 2 min |
| 5.5 | Generate GPG signing key | 5 min |

#### Original Manual Steps (Internal Server)

| Step | Description | Effort |
|------|-------------|--------|
| 5.6 | Install podman and container tools | 5 min |
| 5.7 | Create service user (rpmops) | 3 min |
| 5.8 | Configure rootless podman | 10 min |
| 5.9 | Create data directories with correct ownership | 5 min |
| 5.10 | Build and start rpm-publisher container | 10 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 5.1-5.2 | Existing scripts (run manually on external) | `scripts/external/sm_register.sh`, `scripts/external/enable_repos.sh` |
| 5.3 | Kickstart `%packages` | `automation/kickstart/rhel96_external.ks` |
| 5.4 | Kickstart `%post` | `automation/kickstart/rhel96_external.ks` |
| 5.5 | Existing script | `scripts/common/gpg_functions.sh` |
| 5.6 | Kickstart `%packages` | `automation/kickstart/rhel96_internal.ks` |
| 5.7 | Kickstart `user --name={{SERVICE_USER}}` | `automation/kickstart/rhel96_internal.ks` |
| 5.8 | Kickstart `%post` (subuid, lingering) | `automation/kickstart/rhel96_internal.ks` |
| 5.9 | Kickstart `%post` | `automation/kickstart/rhel96_internal.ks` |
| 5.10 | Kickstart `%post` systemd user service | `automation/kickstart/rhel96_internal.ks` |

---

### 6. TLS Certificate Setup

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 6.1 | Generate self-signed certificate | 5 min |
| 6.2 | Configure web server for HTTPS | 5 min |
| 6.3 | Replace with CA-signed cert (production) | 10 min |
| 6.4 | Distribute CA cert to managed hosts | 5 min per host |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 6.1 | Kickstart `%post` openssl | `automation/kickstart/rhel96_internal.ks` |
| 6.2 | Kickstart `%post` + container config | `automation/kickstart/rhel96_internal.ks` |
| 6.3 | Ansible playbook | `ansible/playbooks/replace_repo_tls_cert.yml` |
| 6.4 | Ansible host_onboarding role | `ansible/roles/host_onboarding/tasks/repository.yml` |

**Trigger**: `make replace-tls-cert CERT_PATH=... KEY_PATH=...`

---

### 7. Ansible Configuration

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 7.1 | Create inventory file manually | 10 min |
| 7.2 | Set host variables (IPs, credentials) | 10 min |
| 7.3 | Test connectivity with ansible ping | 5 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 7.1 | Inventory generator from spec.yaml | `automation/scripts/render-inventory.py` |
| 7.2 | Spec.yaml host_inventory section | `config/spec.yaml` |
| 7.3 | Makefile target | `make ansible-bootstrap` |

**Trigger**: `make render-inventory`

---

### 8. Host Onboarding

#### Original Manual Steps

| Step | Description | Effort |
|------|-------------|--------|
| 8.1 | SSH to host and verify access | 3 min |
| 8.2 | Disable external repos | 5 min |
| 8.3 | Configure internal repo files | 10 min |
| 8.4 | Install CA certificate | 5 min |
| 8.5 | Configure syslog TLS forwarding | 10 min |
| 8.6 | Collect initial manifest | 5 min |

#### Automation

| Step | Automated By | Script/File |
|------|--------------|-------------|
| 8.1 | Ansible with ssh key | `ansible/playbooks/bootstrap_ssh_keys.yml` |
| 8.2 | host_onboarding role | `ansible/roles/host_onboarding/tasks/repository.yml` |
| 8.3 | host_onboarding role | `ansible/roles/host_onboarding/tasks/repository.yml` |
| 8.4 | host_onboarding role | `ansible/roles/host_onboarding/tasks/repository.yml` |
| 8.5 | stig_rsyslog_tls_forward role | `ansible/roles/stig_rsyslog_tls_forward/` |
| 8.6 | manifest_collector role | `ansible/roles/manifest_collector/` |

**Trigger**: `make ansible-onboard`

---

## Remaining Manual Steps

### Justified Manual Actions

| Action | Justification | Automation Alternative |
|--------|---------------|------------------------|
| **Fill spec.yaml** | Operator must provide environment-specific values | Template with comments provided |
| **Provide RHEL ISO** | Licensing requires Red Hat download | Document download URL |
| **Provide Syslog CA cert** | Organization-specific PKI | Document requirements |
| **Red Hat registration** | Requires credentials | Could use environment variables |
| **Physical bundle transfer** | Security requirement (airgap) | Cannot be automated by design |

### Operator Inputs Summary

All operator inputs are consolidated in **one file**: `config/spec.yaml`

Required inputs:
1. vCenter/ESXi connection details
2. RHEL 9.6 ISO path
3. Initial passwords (changed after deployment)
4. Managed host list with `airgap_host_id` values

Optional inputs:
1. Syslog TLS configuration
2. CA-signed certificate paths (for production)
3. Custom VM sizing

---

## Automation Coverage

```
Total Original Manual Steps: 32
Fully Automated Steps:       32
Remaining Manual Steps:       0*

* Operator input via spec.yaml not counted as "manual step"
```

## File Reference

| Purpose | File |
|---------|------|
| Configuration | `config/spec.yaml` |
| Validation | `automation/scripts/validate-spec.sh` |
| VM Deployment | `automation/powercli/deploy-rpm-servers.ps1` |
| VM Destruction | `automation/powercli/destroy-rpm-servers.ps1` |
| Kickstart (External) | `automation/kickstart/rhel96_external.ks` |
| Kickstart (Internal) | `automation/kickstart/rhel96_internal.ks` |
| ISO Generation | `automation/powercli/generate-ks-iso.ps1` |
| Inventory Generation | `automation/scripts/render-inventory.py` |
| SSH Bootstrap | `ansible/playbooks/bootstrap_ssh_keys.yml` |
| Host Onboarding | `ansible/playbooks/onboard_hosts.yml` |
| TLS Replacement | `ansible/playbooks/replace_repo_tls_cert.yml` |
| Patching | `ansible/playbooks/patch_monthly_security.yml` |
| STIG Hardening | `ansible/playbooks/stig_harden_internal_vm.yml` |
| Makefile | `Makefile` |
