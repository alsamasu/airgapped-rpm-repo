#!/bin/bash
# harden.sh - DISA STIG hardening script for internal publisher VM
#
# This script applies STIG-aligned hardening to the internal publisher VM.
# Based on DISA STIG for RHEL 9.

set -euo pipefail

echo "=== Starting STIG hardening ==="

APPLY_STIG="${APPLY_STIG:-true}"

if [[ "${APPLY_STIG}" != "true" ]]; then
    echo "STIG hardening disabled (APPLY_STIG != true)"
    exit 0
fi

# Helper function
apply_setting() {
    local file="$1"
    local setting="$2"
    local value="$3"

    if grep -q "^${setting}" "${file}" 2>/dev/null; then
        sed -i "s|^${setting}.*|${setting}=${value}|" "${file}"
    else
        echo "${setting}=${value}" >> "${file}"
    fi
}

# =============================================================================
# SSH Configuration (STIG: RHEL-09-255xxx)
# =============================================================================
echo "Configuring SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# Disable root login with password
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "${SSHD_CONFIG}"

# Disable password authentication
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "${SSHD_CONFIG}"

# Disable empty passwords
sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "${SSHD_CONFIG}"

# Disable X11 forwarding
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "${SSHD_CONFIG}"

# Set max auth tries
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 4/' "${SSHD_CONFIG}"

# Set client alive settings
cat >> "${SSHD_CONFIG}" << 'SSH'
# STIG: Session timeout
ClientAliveInterval 600
ClientAliveCountMax 0

# STIG: Use only strong ciphers
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# STIG: Use only strong MACs
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# STIG: Use only strong key exchange
KexAlgorithms ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256

# STIG: Banner
Banner /etc/issue.net
SSH

# Create banner
cat > /etc/issue.net << 'BANNER'
*******************************************************************************
*                                                                             *
*  You are accessing a U.S. Government (USG) Information System (IS) that is *
*  provided for USG-authorized use only.                                      *
*                                                                             *
*  By using this IS (which includes any device attached to this IS), you      *
*  consent to the following conditions:                                       *
*                                                                             *
*  - The USG routinely intercepts and monitors communications on this IS for  *
*    purposes including, but not limited to, penetration testing, COMSEC      *
*    monitoring, network operations and defense, personnel misconduct (PM),   *
*    law enforcement (LE), and counterintelligence (CI) investigations.       *
*                                                                             *
*  - At any time, the USG may inspect and seize data stored on this IS.       *
*                                                                             *
*  - Communications using, or data stored on, this IS are not private, are    *
*    subject to routine monitoring, interception, and search, and may be      *
*    disclosed or used for any USG-authorized purpose.                        *
*                                                                             *
*  - This IS includes security measures (e.g., authentication and access      *
*    controls) to protect USG interests--not for your personal benefit or     *
*    privacy.                                                                  *
*                                                                             *
*  - Notwithstanding the above, using this IS does not constitute consent to  *
*    PM, LE or CI investigative searching or monitoring of the content of     *
*    privileged communications, or work product, related to personal          *
*    representation or services by attorneys, psychotherapists, or clergy,    *
*    and their assistants. Such communications and work product are private   *
*    and confidential. See User Agreement for details.                        *
*                                                                             *
*******************************************************************************
BANNER

# =============================================================================
# Audit Configuration (STIG: RHEL-09-653xxx)
# =============================================================================
echo "Configuring audit..."

# Ensure auditd is enabled
systemctl enable auditd

# Configure audit rules
cat > /etc/audit/rules.d/stig.rules << 'AUDIT'
# STIG audit rules for RHEL 9

# Delete all existing rules
-D

# Set buffer size
-b 8192

# Panic on failure
-f 2

# Identity changes
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# System administration actions
-w /etc/sudoers -p wa -k actions
-w /etc/sudoers.d/ -p wa -k actions

# Login/logout events
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

# Session initiation
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

# DAC permission changes
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=unset -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=1000 -F auid!=unset -k perm_mod

# File deletion events
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=unset -k delete

# Kernel module loading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules

# Privileged commands
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/su -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/chage -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/chfn -F perm=x -F auid>=1000 -F auid!=unset -k privileged
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid>=1000 -F auid!=unset -k privileged

# Make rules immutable (must be last)
-e 2
AUDIT

# =============================================================================
# Password Policy (STIG: RHEL-09-411xxx)
# =============================================================================
echo "Configuring password policy..."

# Password quality
cat > /etc/security/pwquality.conf.d/stig.conf << 'PWQUALITY'
# STIG password requirements
minlen = 15
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
difok = 8
minclass = 4
maxrepeat = 3
maxclassrepeat = 4
dictcheck = 1
PWQUALITY

# Login definitions
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   60/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/' /etc/login.defs
sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN    15/' /etc/login.defs

# =============================================================================
# Filesystem (STIG: RHEL-09-231xxx)
# =============================================================================
echo "Configuring filesystem security..."

# Disable unused filesystems
cat > /etc/modprobe.d/stig-blacklist.conf << 'MODPROBE'
# STIG: Disable unused filesystems
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true

# STIG: Disable USB storage
install usb-storage /bin/true

# STIG: Disable uncommon network protocols
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
MODPROBE

# =============================================================================
# System Settings (STIG: RHEL-09-213xxx)
# =============================================================================
echo "Configuring system settings..."

# Kernel parameters
cat > /etc/sysctl.d/99-stig.conf << 'SYSCTL'
# STIG: Kernel hardening

# Network security
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1

# IPv6 settings
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Core dumps
fs.suid_dumpable = 0

# ASLR
kernel.randomize_va_space = 2

# Ptrace scope
kernel.yama.ptrace_scope = 1

# Kernel message logging
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
SYSCTL

# Apply sysctl settings
sysctl --system

# =============================================================================
# Firewall (STIG: RHEL-09-251xxx)
# =============================================================================
echo "Configuring firewall..."

systemctl enable firewalld
systemctl start firewalld || true

# Set default zone
firewall-cmd --set-default-zone=drop 2>/dev/null || true

# Allow only necessary services
firewall-cmd --permanent --zone=drop --add-service=ssh 2>/dev/null || true
firewall-cmd --permanent --zone=drop --add-port=8080/tcp 2>/dev/null || true
firewall-cmd --permanent --zone=drop --add-port=8443/tcp 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

# =============================================================================
# Services (STIG: RHEL-09-252xxx)
# =============================================================================
echo "Configuring services..."

# Disable unnecessary services
for service in rpcbind nfs-server rpcidmapd cups avahi-daemon; do
    systemctl disable "${service}" 2>/dev/null || true
    systemctl stop "${service}" 2>/dev/null || true
done

# Enable required services
systemctl enable auditd chronyd firewalld sshd

# =============================================================================
# File Permissions (STIG: RHEL-09-232xxx)
# =============================================================================
echo "Configuring file permissions..."

# Set correct permissions on sensitive files
chmod 0600 /etc/shadow
chmod 0644 /etc/passwd
chmod 0644 /etc/group
chmod 0600 /etc/gshadow
chmod 0640 /etc/sudoers
chmod 0750 /etc/sudoers.d

# Remove world-writable files
find / -xdev -type f -perm -0002 -exec chmod o-w {} \; 2>/dev/null || true

# =============================================================================
# AIDE Configuration (STIG: RHEL-09-651xxx)
# =============================================================================
echo "Configuring AIDE..."

if command -v aide &>/dev/null; then
    # Initialize AIDE database
    aide --init 2>/dev/null || true
    mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null || true

    # Create AIDE cron job
    cat > /etc/cron.daily/aide-check << 'AIDE'
#!/bin/bash
/usr/sbin/aide --check 2>&1 | /usr/bin/mail -s "AIDE Report - $(hostname)" root
AIDE
    chmod 700 /etc/cron.daily/aide-check
fi

# =============================================================================
# Final Steps
# =============================================================================
echo "Finalizing hardening..."

# Update crypto policy to FIPS
update-crypto-policies --set FIPS 2>/dev/null || true

# Generate audit rules
augenrules --load 2>/dev/null || true

# Restart affected services
systemctl restart sshd 2>/dev/null || true
systemctl restart auditd 2>/dev/null || true

echo "=== STIG hardening complete ==="
echo "Note: Some settings require a reboot to take effect."
