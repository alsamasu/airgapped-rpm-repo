# Internal RPM Server VM Setup Guide

## VMware OVF/OVA Deployment for RHEL 9.6

---

## 1) Overview

### What This VM Is

This document guides deployment of the **Internal RPM Server VM**, which serves as the airgapped RPM repository inside your secure network. The VM runs RHEL 9.6 with FIPS mode enabled and uses rootless Podman to host two containers:

- **rpm-publisher**: HTTPS repository server serving RPM packages
- **ansible-control**: Ansible Execution Environment for host automation

### What It Will Provide After Setup

- HTTPS RPM repository accessible at `https://<vm-ip>:8443/`
- Lifecycle environments: `/lifecycle/testing/` and `/lifecycle/stable/`
- GPG key distribution at `/keys/`
- Ansible automation for managed hosts (repo configuration, manifest collection, patching)
- Self-signed TLS certificate (replaceable with CA-signed certificate)

### What It Will NOT Do

- Generate repository bundles (done on the external builder)
- Connect to the internet
- Automatically configure syslog TLS forwarding (done via Ansible playbook after deployment)
- Automatically replace the self-signed certificate with a CA-signed one

---

## 2) Prerequisites

### VMware Requirements

| Component | Requirement |
|-----------|-------------|
| VMware ESXi | 7.0 or later |
| vSphere Client | 7.0 or later |
| Hardware Version | 19 or later |
| Virtual Hardware | 4 vCPU, 8 GB RAM minimum |
| Disk Space | 100 GB minimum (expandable) |

### Required Files

Before starting, ensure you have:

| File | Description | Location |
|------|-------------|----------|
| RHEL 9.6 ISO | Red Hat Enterprise Linux 9.6 installation media | Obtained from Red Hat Customer Portal |
| Repository Bundle | Signed tarball from external builder | `bundle-YYYYMMDD-HHMMSS.tar.gz.gpg` |
| GPG Public Key | Key to verify bundle signatures | `RPM-GPG-KEY-internal` |
| This Repository | Cloned airgapped-rpm-repo | Local workstation |

### Required Operator Access

- vSphere administrator privileges to deploy OVAs
- Console access to the deployed VM
- SSH access (after first boot)
- Root or sudo access on the VM

---

## 3) Build the OVF/OVA (Packer)

### 3.1) Navigate to Packer Directory

```bash
cd /path/to/airgapped-rpm-repo/packer
```

### 3.2) Create Variables File

Create a file named `variables.pkrvars.hcl`:

```hcl
iso_url              = "/path/to/rhel-9.6-x86_64-dvd.iso"
iso_checksum         = "sha256:YOUR_ISO_SHA256_CHECKSUM"
vcenter_server       = "vcenter.example.com"
vcenter_username     = "administrator@vsphere.local"
vcenter_password     = "YOUR_PASSWORD"
vcenter_datacenter   = "Datacenter"
vcenter_cluster      = "Cluster"
vcenter_datastore    = "datastore1"
vcenter_network      = "VM Network"
vm_name              = "airgap-internal-rpm-server"
ssh_username         = "root"
ssh_password         = "INITIAL_ROOT_PASSWORD"
```

### 3.3) Validate Packer Template

```bash
packer validate -var-file=variables.pkrvars.hcl internal-server.pkr.hcl
```

**Expected output:**
```
The configuration is valid.
```

### 3.4) Build the OVA

```bash
packer build -var-file=variables.pkrvars.hcl internal-server.pkr.hcl
```

**Expected output:**
```
==> Builds finished. The artifacts of successful builds are:
--> vmware-iso.internal-server: VM files in directory: output-internal-server
```

### 3.5) Locate Output Files

```bash
ls -la output-internal-server/
```

**Expected files:**
```
airgap-internal-rpm-server.ovf
airgap-internal-rpm-server.vmdk
airgap-internal-rpm-server.mf
```

### Verify: OVA Build Succeeded

```bash
ovftool --verifyOnly output-internal-server/airgap-internal-rpm-server.ovf
```

**Expected output:**
```
Completed successfully
```

---

## 4) Deploy the OVF/OVA in VMware

### 4.1) Open vSphere Client

1. Open your browser and navigate to `https://vcenter.example.com/ui`
2. Log in with your vSphere credentials

### 4.2) Start OVF Deployment

1. Right-click on your target cluster or host
2. Select **Deploy OVF Template**

### 4.3) Select Source

1. Choose **Local file**
2. Click **Upload Files**
3. Select all files from `output-internal-server/` directory:
   - `airgap-internal-rpm-server.ovf`
   - `airgap-internal-rpm-server.vmdk`
   - `airgap-internal-rpm-server.mf`
4. Click **Next**

### 4.4) Name and Location

1. Set VM name: `airgap-internal-rpm-server`
2. Select target datacenter folder
3. Click **Next**

### 4.5) Select Compute Resource

1. Select target cluster or ESXi host
2. Click **Next**

### 4.6) Review Details

1. Verify OVF details are correct
2. Click **Next**

### 4.7) Select Storage

1. Select target datastore with at least 100 GB free
2. Set virtual disk format: **Thick Provision Lazy Zeroed**
3. Click **Next**

### 4.8) Select Networks

1. Map source network to your target network
2. For airgapped environments, select your isolated network
3. Click **Next**

### 4.9) Customize Template (if prompted)

1. Leave defaults or adjust as needed
2. Click **Next**

### 4.10) Ready to Complete

1. Review all settings
2. Check **Power on after deployment** if desired
3. Click **Finish**

### 4.11) Wait for Deployment

Monitor the task in vSphere until completion.

### Disk Sizing Guidance

| Mount Point | Purpose | Minimum Size |
|-------------|---------|--------------|
| `/` | Root filesystem | 20 GB |
| `/srv/airgap/data` | Repository data, bundles, keys | 80 GB |

If you need more repository space, expand `/srv/airgap/data` after deployment.

### Network Configuration

**Static IP (Recommended for Production):**
- Configure static IP in RHEL during first boot
- Ensure DNS resolution works
- Ensure firewall allows ports 8080 and 8443

**DHCP (Development/Testing):**
- DHCP will assign IP automatically
- Note the assigned IP from console

### Power-On Procedure

1. Right-click the deployed VM
2. Select **Power** → **Power On**
3. Open the console to monitor boot

---

## 5) First Boot (Day 0)

### 5.1) Login to Console

1. Open VM console in vSphere
2. Wait for login prompt
3. Login as:
   - Username: `root`
   - Password: The password set during Packer build

### 5.2) Verify OS Version

```bash
cat /etc/redhat-release
```

**Expected output:**
```
Red Hat Enterprise Linux release 9.6 (Plow)
```

### 5.3) Verify FIPS Mode

```bash
fips-mode-setup --check
```

**Expected output:**
```
FIPS mode is enabled.
```

### 5.4) Verify Podman Installation

```bash
podman --version
```

**Expected output:**
```
podman version 4.9.x
```

### 5.5) Verify Service User Exists

```bash
id rpmops
```

**Expected output:**
```
uid=1001(rpmops) gid=1001(rpmops) groups=1001(rpmops)
```

### 5.6) Verify Required Directories

```bash
ls -la /srv/airgap/data/
```

**Expected output:**
```
drwxr-xr-x. rpmops rpmops repos
drwxr-xr-x. rpmops rpmops lifecycle
drwxr-xr-x. rpmops rpmops bundles
drwxr-xr-x. rpmops rpmops keys
drwxr-xr-x. rpmops rpmops certs
drwxr-xr-x. rpmops rpmops manifests
```

### 5.7) Verify Directory Permissions

```bash
stat -c '%U:%G %a %n' /srv/airgap/data/*
```

**Expected output:**
```
rpmops:rpmops 755 /srv/airgap/data/bundles
rpmops:rpmops 755 /srv/airgap/data/certs
rpmops:rpmops 755 /srv/airgap/data/keys
rpmops:rpmops 755 /srv/airgap/data/lifecycle
rpmops:rpmops 755 /srv/airgap/data/manifests
rpmops:rpmops 755 /srv/airgap/data/repos
```

### Verify: First Boot Complete

```bash
systemctl is-system-running
```

**Expected output:**
```
running
```

---

## 6) Start Internal Services

### 6.1) Switch to Service User

```bash
su - rpmops
```

### 6.2) Enable Lingering

Lingering allows user services to run without an active login session:

```bash
loginctl enable-linger rpmops
```

### Verify: Lingering Enabled

```bash
ls /var/lib/systemd/linger/
```

**Expected output:**
```
rpmops
```

### 6.3) Create User Systemd Directory

```bash
mkdir -p ~/.config/systemd/user/
```

### 6.4) Copy Service Files

As root, copy the service files:

```bash
exit  # Return to root
cp /opt/airgap/deployment/systemd/airgap-rpm-publisher.service /home/rpmops/.config/systemd/user/
cp /opt/airgap/deployment/systemd/airgap-ansible-control.service /home/rpmops/.config/systemd/user/
chown -R rpmops:rpmops /home/rpmops/.config/
```

### 6.5) Start Services as rpmops User

```bash
su - rpmops
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable airgap-rpm-publisher.service
systemctl --user enable airgap-ansible-control.service
systemctl --user start airgap-rpm-publisher.service
```

### 6.6) Verify rpm-publisher Container

```bash
podman ps --format "{{.Names}} {{.Status}}"
```

**Expected output:**
```
airgap-rpm-publisher Up X seconds (healthy)
```

### 6.7) Verify HTTPS Endpoint

```bash
curl -fsk https://localhost:8443/
```

**Expected output:**
```html
<!DOCTYPE html>
<html>
<head>
    <title>Internal RPM Repository</title>
...
```

### 6.8) Start Ansible Control Container

```bash
systemctl --user start airgap-ansible-control.service
```

### 6.9) Verify Ansible Container

```bash
podman ps --format "{{.Names}} {{.Status}}"
```

**Expected output:**
```
airgap-rpm-publisher Up X minutes (healthy)
airgap-ansible-control Up X seconds
```

### Verify: Services Running

```bash
systemctl --user status airgap-rpm-publisher.service airgap-ansible-control.service
```

Both services should show `active (running)`.

---

## 7) HTTPS Bootstrap

### 7.1) Self-Signed Certificate Location

On first start, the rpm-publisher container automatically generates a self-signed certificate:

```bash
ls -la /srv/airgap/data/certs/
```

**Expected output:**
```
-rw------- rpmops rpmops server.key
-rw-r--r-- rpmops rpmops server.crt
```

### 7.2) View Certificate Details

```bash
openssl x509 -in /srv/airgap/data/certs/server.crt -noout -subject -dates
```

**Expected output:**
```
subject=C = US, ST = Internal, L = Internal, O = RPM Repository, OU = IT, CN = localhost
notBefore=Dec 30 01:00:00 2025 GMT
notAfter=Dec 30 01:00:00 2026 GMT
```

### 7.3) Confirm HTTPS Works

```bash
curl -vsk https://localhost:8443/ 2>&1 | grep -E "subject|issuer|expire"
```

**Expected output:**
```
*  subject: C=US; ST=Internal; L=Internal; O=RPM Repository; OU=IT; CN=localhost
*  issuer: C=US; ST=Internal; L=Internal; O=RPM Repository; OU=IT; CN=localhost
*  expire date: Dec 30 01:00:00 2026 GMT
```

### 7.4) How Clients Will Trust This Certificate

Clients must either:

**Option A: Disable SSL verification (testing only)**
```ini
sslverify=0
```

**Option B: Install the self-signed CA (recommended)**
```bash
# On client machine
scp rpmops@<server-ip>:/srv/airgap/data/certs/server.crt /etc/pki/ca-trust/source/anchors/internal-rpm.crt
update-ca-trust
```

### 7.5) Replacing with CA-Signed Certificate

To replace the self-signed certificate with a CA-signed certificate:

1. Obtain certificate and key from your CA
2. Stop the service:
   ```bash
   systemctl --user stop airgap-rpm-publisher.service
   ```
3. Replace the files:
   ```bash
   cp /path/to/ca-signed.crt /srv/airgap/data/certs/server.crt
   cp /path/to/ca-signed.key /srv/airgap/data/certs/server.key
   chmod 600 /srv/airgap/data/certs/server.key
   chmod 644 /srv/airgap/data/certs/server.crt
   ```
4. Start the service:
   ```bash
   systemctl --user start airgap-rpm-publisher.service
   ```

---

## 8) Import First Repository Bundle

### 8.1) Transfer Bundle to Server

From the external builder machine, transfer the bundle:

```bash
scp bundle-20251230-120000.tar.gz.gpg rpmops@<internal-server>:/srv/airgap/data/bundles/incoming/
```

### 8.2) Import the GPG Public Key

```bash
su - rpmops
gpg --import /srv/airgap/data/keys/RPM-GPG-KEY-internal
```

### 8.3) Verify and Decrypt Bundle

```bash
cd /srv/airgap/data/bundles/incoming/
gpg --verify bundle-20251230-120000.tar.gz.gpg
gpg --decrypt bundle-20251230-120000.tar.gz.gpg > bundle-20251230-120000.tar.gz
```

### 8.4) Import Bundle to Testing Environment

```bash
podman exec airgap-rpm-publisher /opt/rpmserver/import-bundle.sh \
  /data/bundles/incoming/bundle-20251230-120000.tar.gz
```

**Expected output:**
```
[INFO] Extracting bundle...
[INFO] Validating checksums...
[OK] All checksums valid
[INFO] Importing to testing environment...
[OK] Bundle imported to /data/lifecycle/testing/
```

### 8.5) Verify Testing Environment

```bash
curl -fsk https://localhost:8443/lifecycle/testing/
```

**Expected output:** Directory listing showing repository structure.

### 8.6) Validate Repository Metadata

```bash
podman exec airgap-rpm-publisher /opt/rpmserver/validate-repos.sh testing
```

**Expected output:**
```
[OK] Repository metadata valid
[OK] GPG signatures verified
```

### 8.7) Promote to Stable Environment

After validation, promote the repository:

```bash
podman exec airgap-rpm-publisher /opt/rpmserver/promote-to-stable.sh
```

**Expected output:**
```
[INFO] Promoting testing to stable...
[OK] Promotion complete
```

### 8.8) Verify Stable Environment

```bash
curl -fsk https://localhost:8443/lifecycle/stable/
```

**Expected output:** Directory listing showing repository structure.

### Verify: Repository Is Being Served

```bash
curl -fsk https://localhost:8443/lifecycle/stable/9/x86_64/baseos/repodata/repomd.xml | head -5
```

**Expected output:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo" ...>
```

---

## 9) Verify Client Consumption (Smoke Test)

### 9.1) Create Repository File on Client

On a RHEL 9 client machine, create `/etc/yum.repos.d/internal.repo`:

```ini
[internal-stable-baseos]
name=Internal Stable - BaseOS
baseurl=https://INTERNAL_SERVER_IP:8443/lifecycle/stable/9/x86_64/baseos
enabled=1
gpgcheck=1
gpgkey=https://INTERNAL_SERVER_IP:8443/keys/RPM-GPG-KEY-internal
sslverify=0

[internal-stable-appstream]
name=Internal Stable - AppStream
baseurl=https://INTERNAL_SERVER_IP:8443/lifecycle/stable/9/x86_64/appstream
enabled=1
gpgcheck=1
gpgkey=https://INTERNAL_SERVER_IP:8443/keys/RPM-GPG-KEY-internal
sslverify=0
```

Replace `INTERNAL_SERVER_IP` with the actual IP address of the internal server.

### 9.2) Install GPG Key on Client

```bash
curl -fsk https://INTERNAL_SERVER_IP:8443/keys/RPM-GPG-KEY-internal -o /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
```

### 9.3) Disable Default Repos (Airgapped)

```bash
dnf config-manager --disable rhel-9-for-x86_64-baseos-rpms
dnf config-manager --disable rhel-9-for-x86_64-appstream-rpms
```

### 9.4) Clean Cache and Test

```bash
dnf clean all
dnf repolist
```

**Expected output:**
```
repo id                     repo name
internal-stable-baseos      Internal Stable - BaseOS
internal-stable-appstream   Internal Stable - AppStream
```

### 9.5) Test Package Installation

```bash
dnf info bash
```

**Expected output:**
```
Available Packages
Name         : bash
Version      : 5.1.8
Release      : 9.el9
...
Repository   : internal-stable-baseos
```

### Verify: Client Can Consume Repository

```bash
dnf makecache
```

**Expected output:**
```
Internal Stable - BaseOS                    X.X MB/s | X.X MB     00:00
Internal Stable - AppStream                 X.X MB/s | X.X MB     00:00
Metadata cache created.
```

---

## 10) Prepare for Ansible Host Onboarding (Day 1)

### 10.1) Inventory Location

Ansible inventory is located at:

```
/opt/airgap/ansible/inventories/hosts.yml
```

### 10.2) Edit Inventory

```bash
vim /opt/airgap/ansible/inventories/hosts.yml
```

### 10.3) Required Inventory Variables

Each managed host MUST have the following variables:

```yaml
all:
  vars:
    # Repository server settings
    internal_repo_url: "https://10.0.0.50:8443"
    internal_repo_gpg_key: "https://10.0.0.50:8443/keys/RPM-GPG-KEY-internal"
    
    # Syslog TLS settings (for STIG playbook)
    syslog_tls_target_host: "syslog.example.com"
    syslog_tls_target_port: 6514
    syslog_tls_ca_bundle_path: "/etc/pki/tls/certs/syslog-ca.crt"

  children:
    rhel9_hosts:
      hosts:
        server1.example.com:
          airgap_host_id: "server1-prod-01"
          ansible_host: 10.0.0.101
        server2.example.com:
          airgap_host_id: "server2-prod-02"
          ansible_host: 10.0.0.102
    
    rhel8_hosts:
      hosts:
        legacy1.example.com:
          airgap_host_id: "legacy1-prod-01"
          ansible_host: 10.0.0.201
```

**Critical:** The `airgap_host_id` variable is REQUIRED for each host. This is the unique identifier used for manifest collection and tracking.

### 10.4) Enter Ansible Container

```bash
su - rpmops
podman exec -it airgap-ansible-control /bin/bash
```

### 10.5) Run SSH Key Bootstrap

Distribute SSH keys to managed hosts:

```bash
cd /opt/ansible
ansible-playbook -i inventories/hosts.yml playbooks/bootstrap_ssh_keys.yml --ask-pass
```

**Expected output:**
```
PLAY [Bootstrap SSH keys] *****************************************************
...
PLAY RECAP ********************************************************************
server1.example.com : ok=3  changed=1  unreachable=0  failed=0
server2.example.com : ok=3  changed=1  unreachable=0  failed=0
```

### 10.6) Run Repository Configuration

Configure internal repository on all hosts:

```bash
ansible-playbook -i inventories/hosts.yml playbooks/configure_internal_repo.yml
```

**Expected output:**
```
PLAY [Configure internal repository] ******************************************
...
PLAY RECAP ********************************************************************
server1.example.com : ok=5  changed=2  unreachable=0  failed=0
server2.example.com : ok=5  changed=2  unreachable=0  failed=0
```

### 10.7) Run Manifest Collection

Collect package manifests from all hosts:

```bash
ansible-playbook -i inventories/hosts.yml playbooks/collect_manifests.yml
```

**Expected output:**
```
PLAY [Collect package manifests] **********************************************
...
TASK [Fetch manifest to control node] *****************************************
changed: [server1.example.com]
changed: [server2.example.com]
...
```

### Verify: Manifests Collected

```bash
ls -la /opt/ansible/manifests/
```

**Expected output:**
```
server1-prod-01/
server2-prod-02/
```

---

## 11) What Is NOT Done Automatically

### Syslog TLS Forwarding

Syslog TLS forwarding is configured via the STIG hardening playbook, NOT during initial deployment:

```bash
ansible-playbook -i inventories/hosts.yml playbooks/stig_harden_internal_vm.yml
```

This playbook:
- Configures rsyslog TLS forwarding with server-auth only (no mTLS)
- Uses the `syslog_tls_*` variables from inventory
- Does NOT require client certificates

### CA-Signed Certificate Replacement

The self-signed certificate must be manually replaced with a CA-signed certificate. See Section 7.5.

### External Bundle Generation

Repository bundles are generated on the EXTERNAL builder machine, not on this internal server. This server only imports and serves bundles.

### FIPS Validation Reporting

FIPS validation status is checked by the STIG playbook but must be reviewed manually for compliance evidence.

---

## 12) Troubleshooting

### 12.1) Podman Container Not Starting

**Check container logs:**
```bash
podman logs airgap-rpm-publisher
```

**Check container status:**
```bash
podman ps -a --format "{{.Names}} {{.Status}} {{.State}}"
```

**Restart container:**
```bash
systemctl --user restart airgap-rpm-publisher.service
```

### 12.2) Systemd User Service Issues

**Check if lingering is enabled:**
```bash
ls /var/lib/systemd/linger/
```

**Check XDG_RUNTIME_DIR:**
```bash
echo $XDG_RUNTIME_DIR
# Should be /run/user/1001
```

**If missing, set it:**
```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

**Check service status:**
```bash
systemctl --user status airgap-rpm-publisher.service
```

**View service logs:**
```bash
journalctl --user -u airgap-rpm-publisher.service -n 50
```

### 12.3) HTTPS Not Working

**Check if Apache is running in container:**
```bash
podman exec airgap-rpm-publisher pgrep httpd
```

**Check Apache error log:**
```bash
podman exec airgap-rpm-publisher cat /var/log/rpmserver/httpd-error.log
```

**Check certificate exists:**
```bash
ls -la /srv/airgap/data/certs/
```

**Verify certificate is valid:**
```bash
openssl x509 -in /srv/airgap/data/certs/server.crt -noout -text | head -20
```

### 12.4) Repository Metadata Errors

**Check repodata exists:**
```bash
podman exec airgap-rpm-publisher ls -la /data/lifecycle/stable/9/x86_64/baseos/repodata/
```

**Verify repomd.xml is valid:**
```bash
podman exec airgap-rpm-publisher xmllint --noout /data/lifecycle/stable/9/x86_64/baseos/repodata/repomd.xml
```

**Regenerate repository metadata:**
```bash
podman exec airgap-rpm-publisher createrepo_c --update /data/lifecycle/stable/9/x86_64/baseos/
```

### 12.5) Client Cannot Connect

**From client, test connectivity:**
```bash
curl -vsk https://INTERNAL_SERVER_IP:8443/
```

**Check firewall on server (as root):**
```bash
firewall-cmd --list-ports
```

**Open ports if needed:**
```bash
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=8443/tcp
firewall-cmd --reload
```

### 12.6) FIPS Mode Issues

**Check FIPS status:**
```bash
fips-mode-setup --check
```

**If FIPS is not enabled:**
```bash
fips-mode-setup --enable
reboot
```

---

## 13) Rollback / Reset

### 13.1) Stop All Services

As the rpmops user:

```bash
su - rpmops
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user stop airgap-rpm-publisher.service
systemctl --user stop airgap-ansible-control.service
```

### 13.2) Verify Services Stopped

```bash
podman ps
```

**Expected output:** No containers running.

### 13.3) Clear Testing Environment

```bash
rm -rf /srv/airgap/data/lifecycle/testing/*
```

### 13.4) Clear Stable Environment

```bash
rm -rf /srv/airgap/data/lifecycle/stable/*
```

### 13.5) Clear All Imported Bundles

```bash
rm -rf /srv/airgap/data/bundles/incoming/*
rm -rf /srv/airgap/data/bundles/processed/*
```

### 13.6) Clear Manifests

```bash
rm -rf /srv/airgap/data/manifests/*
```

### 13.7) Regenerate Self-Signed Certificate

```bash
rm -f /srv/airgap/data/certs/server.crt
rm -f /srv/airgap/data/certs/server.key
```

The certificate will be regenerated on next container start.

### 13.8) Re-Import Cleanly

1. Start services:
   ```bash
   systemctl --user start airgap-rpm-publisher.service
   ```

2. Wait for container to be healthy:
   ```bash
   podman wait --condition=healthy airgap-rpm-publisher
   ```

3. Import bundle (see Section 8):
   ```bash
   podman exec airgap-rpm-publisher /opt/rpmserver/import-bundle.sh \
     /data/bundles/incoming/bundle-YYYYMMDD-HHMMSS.tar.gz
   ```

### 13.9) Full Reset to Factory State

To completely reset the VM to initial state:

```bash
# As root
systemctl stop user@1001.service
rm -rf /srv/airgap/data/*
mkdir -p /srv/airgap/data/{repos,lifecycle/testing,lifecycle/stable,bundles/incoming,bundles/processed,keys,certs,manifests}
chown -R rpmops:rpmops /srv/airgap/data
chmod -R 755 /srv/airgap/data
systemctl start user@1001.service
```

Then follow the setup from Section 6 onwards.

---

## Quick Reference

| Task | Command |
|------|---------|
| Start publisher | `systemctl --user start airgap-rpm-publisher.service` |
| Stop publisher | `systemctl --user stop airgap-rpm-publisher.service` |
| View publisher logs | `podman logs airgap-rpm-publisher` |
| Check publisher health | `curl -fsk https://localhost:8443/` |
| Enter ansible container | `podman exec -it airgap-ansible-control /bin/bash` |
| Import bundle | `podman exec airgap-rpm-publisher /opt/rpmserver/import-bundle.sh /data/bundles/incoming/BUNDLE.tar.gz` |
| Promote to stable | `podman exec airgap-rpm-publisher /opt/rpmserver/promote-to-stable.sh` |
| Check FIPS | `fips-mode-setup --check` |

---

**Document Version:** 1.0  
**Last Updated:** 2025-12-30  
**Applies To:** Airgapped RPM Repository System - Internal Server
