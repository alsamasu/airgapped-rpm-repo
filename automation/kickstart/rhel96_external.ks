#version=RHEL9
# Kickstart for External RPM Server (RHEL 9.6)
# This server is internet-connected and syncs from Red Hat CDN.
#
# Generated from spec.yaml template
# Placeholders: {{HOSTNAME}}, {{ROOT_PASSWORD}}, {{ADMIN_USER}}, {{ADMIN_PASSWORD}}

# Installation method
text
cdrom

# System language and keyboard
lang en_US.UTF-8
keyboard --xlayouts='us'

# Network configuration (DHCP)
network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname={{HOSTNAME}}

# Security
firewall --enabled --service=ssh --service=http --service=https
selinux --enforcing

# Root password
rootpw --plaintext {{ROOT_PASSWORD}}

# Admin user with sudo access
user --name={{ADMIN_USER}} --password={{ADMIN_PASSWORD}} --plaintext --groups=wheel

# Timezone
timezone America/New_York --utc
timesource --ntp-server=time.nist.gov

# Bootloader configuration
bootloader --location=mbr --append="crashkernel=auto"

# Disk partitioning
zerombr
clearpart --all --initlabel --disklabel=gpt

# UEFI partition
part /boot/efi --fstype="efi" --size=600

# Boot partition
part /boot --fstype="xfs" --size=1024

# LVM physical volume
part pv.01 --fstype="lvmpv" --size=1 --grow

# Volume group
volgroup vg_root pv.01

# Logical volumes
logvol / --fstype="xfs" --size=30720 --name=lv_root --vgname=vg_root
logvol /var --fstype="xfs" --size=20480 --name=lv_var --vgname=vg_root
logvol /var/log --fstype="xfs" --size=10240 --name=lv_log --vgname=vg_root
logvol /var/log/audit --fstype="xfs" --size=5120 --name=lv_audit --vgname=vg_root
logvol /home --fstype="xfs" --size=10240 --name=lv_home --vgname=vg_root
logvol /data --fstype="xfs" --size=1 --grow --name=lv_data --vgname=vg_root
logvol swap --fstype="swap" --size=4096 --name=lv_swap --vgname=vg_root

# Package selection
skipx
%packages
@^minimal-environment
# Core utilities
vim-enhanced
tmux
git
wget
curl
rsync
tar
unzip

# System administration
sudo
openssh-server
openssh-clients
chrony

# Security and auditing
audit
rsyslog
policycoreutils-python-utils
setools-console

# Repository tools
createrepo_c
dnf-utils
yum-utils

# Signing and verification
gnupg2
rpm-sign

# Python for automation
python3
python3-pip

# Firewall
firewalld
nftables

# VMware Tools (for OVA first-boot)
open-vm-tools
%end

# Post-installation script
%post --log=/root/ks-post.log
#!/bin/bash
set -euo pipefail

echo "=== Post-installation configuration for External RPM Server ==="

# Set hostname
hostnamectl set-hostname {{HOSTNAME}}

# Configure SSH
echo "Configuring SSH..."
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Configure sudo for admin user
echo "Configuring sudo..."
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

# Create data directories
echo "Creating data directories..."
mkdir -p /data/{repos,export,gpg,logs,manifests}
chown -R {{ADMIN_USER}}:{{ADMIN_USER}} /data

# Record role
echo "external-rpm-server" > /etc/airgap-role
echo "{{HOSTNAME}}" > /etc/hostname

# Configure firewall
echo "Configuring firewall..."
systemctl enable firewalld
systemctl start firewalld || true
firewall-cmd --permanent --add-service=ssh || true
firewall-cmd --permanent --add-service=http || true
firewall-cmd --permanent --add-service=https || true
firewall-cmd --reload || true

# Enable services
echo "Enabling services..."
systemctl enable sshd
systemctl enable chronyd
systemctl enable rsyslog
systemctl enable auditd
systemctl enable vmtoolsd || true

# Install first-boot customization script for OVA deployments
echo "Installing first-boot customization..."
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/airgap-firstboot-customize << 'EOFSCRIPT'
#!/bin/bash
# First-boot customization for Airgapped RPM Repository OVA deployments
set -euo pipefail

LOG_FILE="/var/log/airgap-firstboot.log"
MARKER_FILE="/var/lib/airgap-firstboot-done"

log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

if [[ -f "$MARKER_FILE" ]]; then
    log "First-boot customization already completed. Exiting."
    exit 0
fi

log "Starting airgap first-boot customization"

get_guestinfo() {
    local key=$1
    local default=${2:-""}
    local value=""
    if command -v vmtoolsd &> /dev/null; then
        value=$(vmtoolsd --cmd "info-get guestinfo.ovfenv.$key" 2>/dev/null || true)
    fi
    if [[ -z "$value" ]] && command -v vmware-rpctool &> /dev/null; then
        value=$(vmware-rpctool "info-get guestinfo.ovfenv.$key" 2>/dev/null || true)
    fi
    echo "${value:-$default}"
}

HOSTNAME_NEW=$(get_guestinfo "hostname" "")
NETWORK_MODE=$(get_guestinfo "network.mode" "dhcp")
IP_ADDRESS=$(get_guestinfo "network.ip" "")
IP_PREFIX=$(get_guestinfo "network.prefix" "24")
GATEWAY=$(get_guestinfo "network.gateway" "")
DNS_SERVERS=$(get_guestinfo "network.dns" "")

log "Configuration: hostname=${HOSTNAME_NEW:-'(not set)'} mode=$NETWORK_MODE ip=${IP_ADDRESS:-'DHCP'}"

if [[ -n "$HOSTNAME_NEW" ]]; then
    log "Setting hostname to: $HOSTNAME_NEW"
    hostnamectl set-hostname "$HOSTNAME_NEW"
    grep -q "$HOSTNAME_NEW" /etc/hosts || echo "127.0.1.1 $HOSTNAME_NEW" >> /etc/hosts
fi

PRIMARY_IFACE=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|virbr|docker|veth)/ {print $2; exit}')
[[ -z "$PRIMARY_IFACE" ]] && PRIMARY_IFACE="ens192"

if [[ "$NETWORK_MODE" == "static" && -n "$IP_ADDRESS" ]]; then
    log "Configuring static network on $PRIMARY_IFACE"
    CONN_FILE="/etc/NetworkManager/system-connections/${PRIMARY_IFACE}-static.nmconnection"
    cat > "$CONN_FILE" << EOCONN
[connection]
id=${PRIMARY_IFACE}-static
type=ethernet
interface-name=${PRIMARY_IFACE}
autoconnect=true

[ethernet]

[ipv4]
method=manual
addresses=${IP_ADDRESS}/${IP_PREFIX}
$([ -n "$GATEWAY" ] && echo "gateway=$GATEWAY")
$([ -n "$DNS_SERVERS" ] && echo "dns=$DNS_SERVERS")

[ipv6]
method=disabled
EOCONN
    chmod 600 "$CONN_FILE"
    nmcli connection reload
    nmcli connection up "${PRIMARY_IFACE}-static" || true
else
    log "Using DHCP for network configuration"
fi

log "First-boot customization completed successfully"
echo "Completed: $(date -Iseconds)" > "$MARKER_FILE"
systemctl disable airgap-firstboot.service 2>/dev/null || true
exit 0
EOFSCRIPT
chmod 755 /usr/local/sbin/airgap-firstboot-customize

# Install systemd service for first-boot
cat > /etc/systemd/system/airgap-firstboot.service << 'EOFSVC'
[Unit]
Description=Airgap First-Boot Customization
After=network-online.target vmtoolsd.service
Wants=network-online.target
ConditionPathExists=!/var/lib/airgap-firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/airgap-firstboot-customize
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOFSVC
systemctl enable airgap-firstboot.service

# Create marker file for kickstart completion detection
echo "Creating completion marker..."
touch /root/.ks-install-complete
echo "Installation completed: $(date -Iseconds)" > /root/.ks-install-complete

echo "=== Post-installation complete ==="
%end

# Reboot after installation
reboot --eject
