# DISA STIG Hardening Guide - Internal Publisher

This document provides DISA STIG-aligned hardening guidance for the Internal Publisher VM running RHEL 9.6.

## Overview

The Internal Publisher VM implements hardening aligned with DISA STIG for RHEL 9. This document describes the implemented controls and provides guidance for verification and additional hardening.

## Automated Hardening

The Packer build process applies automated hardening via:
- `packer/http/ks.cfg` - Kickstart installation configuration
- `packer/scripts/harden.sh` - Post-installation hardening script

### Kickstart Hardening

1. **Partitioning** (STIG: RHEL-09-231xxx)
   - Separate partitions for /boot, /, /var, /var/log, /var/log/audit, /home, /tmp
   - Mount options: nodev, nosuid, noexec where appropriate

2. **Package Selection**
   - Minimal installation with security tools
   - Removed unnecessary firmware packages

3. **SELinux**
   - Enforcing mode enabled

4. **SCAP Profile**
   - Initial STIG profile applied via OpenSCAP during installation

### Post-Installation Hardening

The `harden.sh` script applies:

#### SSH Configuration (RHEL-09-255xxx)

```bash
# Key settings applied:
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 600
ClientAliveCountMax 0

# Strong ciphers only
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,...

# Strong MACs only
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,...
```

#### Audit Configuration (RHEL-09-653xxx)

```bash
# Identity file monitoring
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity

# Sudo monitoring
-w /etc/sudoers -p wa -k actions
-w /etc/sudoers.d/ -p wa -k actions

# Login monitoring
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

# Privileged commands
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged
```

#### Password Policy (RHEL-09-411xxx)

```bash
# /etc/security/pwquality.conf.d/stig.conf
minlen = 15
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
difok = 8
minclass = 4
maxrepeat = 3
```

#### Kernel Parameters (RHEL-09-213xxx)

```bash
# Network hardening
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1

# Core dump prevention
fs.suid_dumpable = 0

# ASLR
kernel.randomize_va_space = 2
```

#### Filesystem Security (RHEL-09-231xxx)

```bash
# Disabled filesystems
install cramfs /bin/true
install usb-storage /bin/true
install dccp /bin/true
install sctp /bin/true
```

## Verification

### Run OpenSCAP Evaluation

```bash
# On the Internal Publisher VM
sudo /opt/rpmserver/scripts/run_openscap.sh

# View results
ls /opt/rpmserver/compliance/html/
```

### Generate STIG Checklist

```bash
# Generate CKL format
sudo /opt/rpmserver/scripts/generate_ckl.sh

# View results
ls /opt/rpmserver/compliance/ckl/
```

### Manual Verification Commands

```bash
# Check SELinux status
getenforce

# Check SSH configuration
sshd -T | grep -E "permitrootlogin|passwordauthentication|x11forwarding"

# Check audit rules
auditctl -l

# Check kernel parameters
sysctl -a | grep -E "net.ipv4.ip_forward|randomize_va_space"

# Check firewall
firewall-cmd --list-all

# Check password policy
cat /etc/security/pwquality.conf.d/stig.conf

# Check FIPS mode
fips-mode-setup --check
```

## Additional Hardening Steps

The following may require manual configuration based on environment:

### 1. Configure NTP (RHEL-09-252xxx)

```bash
# Verify chronyd is configured
chronyc sources

# Add specific NTP servers if needed
echo "server ntp.internal.local iburst" >> /etc/chrony.conf
systemctl restart chronyd
```

### 2. Configure AIDE (RHEL-09-651xxx)

```bash
# Initialize AIDE database
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# Run AIDE check
aide --check
```

### 3. Disable IPv6 (if not used)

```bash
# Add to /etc/sysctl.d/99-stig.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

sysctl --system
```

### 4. Configure Log Rotation

```bash
# /etc/logrotate.d/rpmserver
/var/log/rpmserver/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 rpmserver rpmserver
}
```

### 5. Configure Automatic Updates (Optional)

For security patches only:

```bash
dnf install -y dnf-automatic
systemctl enable --now dnf-automatic-install.timer
```

**Note**: In airgapped environments, updates come through the bundle mechanism.

## STIG Categories

### CAT I (High)

High-severity findings that must be addressed:

| STIG ID | Title | Implementation |
|---------|-------|----------------|
| RHEL-09-211010 | SSH must be enabled | sshd enabled |
| RHEL-09-255010 | SSH root login | PermitRootLogin prohibit-password |
| RHEL-09-255015 | SSH password auth | PasswordAuthentication no |
| RHEL-09-291010 | USB storage | install usb-storage /bin/true |

### CAT II (Medium)

Medium-severity findings that should be addressed:

| STIG ID | Title | Implementation |
|---------|-------|----------------|
| RHEL-09-211xxx | Audit configuration | auditd rules |
| RHEL-09-231xxx | Partition security | Separate partitions |
| RHEL-09-252xxx | Time synchronization | chronyd |
| RHEL-09-411xxx | Password policy | pwquality configuration |

### CAT III (Low)

Low-severity findings for consideration:

| STIG ID | Title | Implementation |
|---------|-------|----------------|
| RHEL-09-xxx | Banner configuration | /etc/issue.net |
| RHEL-09-xxx | MOTD configuration | /etc/motd |

## Exceptions and Tailoring

The following STIG requirements may need tailoring for the Internal Publisher:

### Documented Exceptions

1. **Root SSH Access** (RHEL-09-255010)
   - Configured: `PermitRootLogin prohibit-password`
   - Justification: Initial administration requires root access; key-only authentication enforced

2. **USB Storage** (RHEL-09-291010)
   - Disabled by default
   - May need temporary enabling for bundle import from USB media
   - Compensating control: Physical security of media, bundle signature verification

3. **Network Services** (Various)
   - HTTP server (port 8080) required for repository serving
   - Compensating control: Firewall restricts to internal network only

## Compliance Reporting

### Generate Reports

```bash
# Full compliance run
make openscap
make generate-ckl

# View HTML report
firefox /opt/rpmserver/compliance/html/report-*.html

# Export checklist
cat /opt/rpmserver/compliance/ckl/checklist-*.csv
```

### Report Contents

- **ARF XML**: Machine-readable assessment results
- **XCCDF XML**: Extensible Configuration Checklist Description Format
- **HTML Report**: Human-readable compliance report
- **CKL/CSV/JSON**: STIG Viewer compatible checklist

## References

- [DISA STIG for RHEL 9](https://public.cyber.mil/stigs/)
- [SCAP Security Guide](https://github.com/ComplianceAsCode/content)
- [OpenSCAP Documentation](https://www.open-scap.org/documentation/)
