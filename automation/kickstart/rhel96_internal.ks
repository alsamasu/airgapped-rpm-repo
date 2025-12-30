#version=RHEL9
# Kickstart for Internal RPM Server (RHEL 9.6)
# This server is airgapped and publishes packages to managed hosts.
#
# Features:
# - FIPS mode enabled (if configured)
# - Rootless podman for rpm-publisher container
# - Service user (rpmops) for unprivileged operations
# - Self-signed TLS bootstrap
# - Ansible control plane ready
#
# Generated from spec.yaml template
# Placeholders: {{HOSTNAME}}, {{ROOT_PASSWORD}}, {{ADMIN_USER}}, {{ADMIN_PASSWORD}},
#               {{SERVICE_USER}}, {{DATA_DIR}}, {{CERTS_DIR}}, {{ANSIBLE_DIR}},
#               {{FIPS_ENABLED}}, {{HTTP_PORT}}, {{HTTPS_PORT}}

# Installation method
text
cdrom

# System language and keyboard
lang en_US.UTF-8
keyboard --xlayouts='us'

# Network configuration (DHCP)
network --bootproto=dhcp --device=link --activate --onboot=yes
network --hostname={{HOSTNAME}}

# Security - FIPS mode handled in %post
firewall --enabled --service=ssh --port={{HTTP_PORT}}/tcp --port={{HTTPS_PORT}}/tcp
selinux --enforcing

# Root password
rootpw --plaintext {{ROOT_PASSWORD}}

# Admin user with sudo access
user --name={{ADMIN_USER}} --password={{ADMIN_PASSWORD}} --plaintext --groups=wheel

# Service user for containers (unprivileged)
user --name={{SERVICE_USER}} --password={{ADMIN_PASSWORD}} --plaintext --uid=1001 --gid=1001

# Timezone
timezone America/New_York --utc
timesource --ntp-disable

# Bootloader configuration (FIPS requires specific kernel options)
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

# Logical volumes with security-focused layout
logvol / --fstype="xfs" --size=30720 --name=lv_root --vgname=vg_root
logvol /var --fstype="xfs" --size=20480 --name=lv_var --vgname=vg_root
logvol /var/log --fstype="xfs" --size=10240 --name=lv_log --vgname=vg_root
logvol /var/log/audit --fstype="xfs" --size=5120 --name=lv_audit --vgname=vg_root
logvol /home --fstype="xfs" --size=10240 --name=lv_home --vgname=vg_root
logvol /srv --fstype="xfs" --size=1 --grow --name=lv_srv --vgname=vg_root
logvol /tmp --fstype="xfs" --size=5120 --name=lv_tmp --vgname=vg_root --fsoptions="nodev,nosuid,noexec"
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

# Security and compliance
audit
rsyslog
rsyslog-gnutls
policycoreutils-python-utils
setools-console
openscap
openscap-scanner
scap-security-guide
aide

# Container runtime
podman
skopeo
buildah
container-selinux
slirp4netns
fuse-overlayfs

# Repository tools
createrepo_c
dnf-utils

# Web server (for fallback/debugging)
nginx

# Python for automation and Ansible
python3
python3-pip
python3-pyyaml
python3-jinja2

# Ansible
ansible-core

# Firewall
firewalld
nftables

# Cryptography
gnupg2
openssl
crypto-policies
crypto-policies-scripts

# VMware Tools (for OVA first-boot)
open-vm-tools
%end

# Post-installation script
%post --log=/root/ks-post.log
#!/bin/bash
set -euo pipefail

echo "=== Post-installation configuration for Internal RPM Server ==="
echo "Started: $(date -Iseconds)"

# Variables from kickstart template
HOSTNAME="{{HOSTNAME}}"
ADMIN_USER="{{ADMIN_USER}}"
SERVICE_USER="{{SERVICE_USER}}"
DATA_DIR="{{DATA_DIR}}"
CERTS_DIR="{{CERTS_DIR}}"
ANSIBLE_DIR="{{ANSIBLE_DIR}}"
FIPS_ENABLED="{{FIPS_ENABLED}}"
HTTP_PORT="{{HTTP_PORT}}"
HTTPS_PORT="{{HTTPS_PORT}}"

# Set hostname
hostnamectl set-hostname "$HOSTNAME"

# Configure SSH
echo "Configuring SSH..."
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
# STIG: Disable X11 forwarding
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

# Configure sudo for admin user
echo "Configuring sudo..."
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

# Create airgap directory structure
echo "Creating airgap directories..."
mkdir -p "$DATA_DIR"/{import,lifecycle/{testing,stable}/{rhel8,rhel9},logs}
mkdir -p "$CERTS_DIR"
mkdir -p "$ANSIBLE_DIR"/{inventories,playbooks,roles,artifacts/manifests}

# Set ownership for service user
chown -R ${SERVICE_USER}:${SERVICE_USER} "$DATA_DIR"
chown -R ${SERVICE_USER}:${SERVICE_USER} "$CERTS_DIR"
chown -R ${ADMIN_USER}:${ADMIN_USER} "$ANSIBLE_DIR"

# Configure SELinux contexts
echo "Configuring SELinux..."
semanage fcontext -a -t container_file_t "${DATA_DIR}(/.*)?" || true
semanage fcontext -a -t cert_t "${CERTS_DIR}(/.*)?" || true
restorecon -Rv "$DATA_DIR" || true
restorecon -Rv "$CERTS_DIR" || true

# Configure rootless podman for service user
echo "Configuring rootless podman..."
mkdir -p /home/${SERVICE_USER}/.config/containers
mkdir -p /home/${SERVICE_USER}/.local/share/containers

# Enable lingering for systemd user services
loginctl enable-linger ${SERVICE_USER}

# Create XDG_RUNTIME_DIR for service user
mkdir -p /run/user/1001
chown ${SERVICE_USER}:${SERVICE_USER} /run/user/1001
chmod 700 /run/user/1001

# Configure subuid/subgid for rootless containers
echo "${SERVICE_USER}:100000:65536" >> /etc/subuid
echo "${SERVICE_USER}:100000:65536" >> /etc/subgid

# Generate self-signed TLS certificate
echo "Generating self-signed TLS certificate..."
mkdir -p "$CERTS_DIR"
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$CERTS_DIR/server.key" \
    -out "$CERTS_DIR/server.crt" \
    -subj "/CN=${HOSTNAME}/O=Airgap Internal/C=US" \
    -addext "subjectAltName=DNS:${HOSTNAME},DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERTS_DIR/server.key"
chmod 644 "$CERTS_DIR/server.crt"
chown ${SERVICE_USER}:${SERVICE_USER} "$CERTS_DIR"/*

# Create systemd user service for rpm-publisher
echo "Creating systemd user service..."
mkdir -p /home/${SERVICE_USER}/.config/systemd/user

cat > /home/${SERVICE_USER}/.config/systemd/user/rpm-publisher.service << 'EOFSERVICE'
[Unit]
Description=RPM Publisher Container
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/podman stop rpm-publisher
ExecStartPre=-/usr/bin/podman rm rpm-publisher
ExecStart=/usr/bin/podman run --name rpm-publisher \
    --user 1001:1001 \
    -p {{HTTP_PORT}}:8080 \
    -p {{HTTPS_PORT}}:8443 \
    -v {{DATA_DIR}}:/data:Z \
    -v {{CERTS_DIR}}:/certs:Z \
    --label io.containers.autoupdate=registry \
    rpm-publisher:latest
ExecStop=/usr/bin/podman stop rpm-publisher

[Install]
WantedBy=default.target
EOFSERVICE

chown -R ${SERVICE_USER}:${SERVICE_USER} /home/${SERVICE_USER}/.config

# Configure firewall
echo "Configuring firewall..."
systemctl enable firewalld
systemctl start firewalld || true
firewall-cmd --permanent --add-service=ssh || true
firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp || true
firewall-cmd --permanent --add-port=${HTTPS_PORT}/tcp || true
firewall-cmd --reload || true

# FIPS mode configuration
if [ "$FIPS_ENABLED" = "true" ]; then
    echo "Enabling FIPS mode..."
    fips-mode-setup --enable
    # Note: Requires reboot to take effect
fi

# Configure audit rules
echo "Configuring audit rules..."
cat > /etc/audit/rules.d/stig.rules << 'EOFAUDIT'
# STIG Audit Rules
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k actions
-w /etc/sudoers.d/ -p wa -k actions
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k setuid
EOFAUDIT

# Enable services
echo "Enabling services..."
systemctl enable sshd
systemctl enable rsyslog
systemctl enable auditd
systemctl enable podman.socket
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

# Record role
echo "internal-rpm-server" > /etc/airgap-role
echo "${HOSTNAME}" > /etc/hostname

# Create completion marker
echo "Creating completion marker..."
cat > /root/.ks-install-complete << EOFMARKER
Installation completed: $(date -Iseconds)
Hostname: ${HOSTNAME}
FIPS Mode: ${FIPS_ENABLED}
Service User: ${SERVICE_USER}
Data Directory: ${DATA_DIR}
EOFMARKER

echo "=== Post-installation complete ==="
echo "Completed: $(date -Iseconds)"
%end

# Reboot after installation
reboot --eject
