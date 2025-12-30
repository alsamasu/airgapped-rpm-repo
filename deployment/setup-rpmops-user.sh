#!/bin/bash
# setup-rpmops-user.sh - Create and configure the rpmops service user
#
# This script sets up the rootless Podman environment for the
# airgapped RPM repository infrastructure.
#
# Usage: sudo ./setup-rpmops-user.sh

set -euo pipefail

RPMOPS_USER="rpmops"
RPMOPS_HOME="/home/${RPMOPS_USER}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

log_info "Setting up rpmops service user for rootless Podman..."

# Create user if not exists
if id "${RPMOPS_USER}" &>/dev/null; then
    log_info "User ${RPMOPS_USER} already exists"
else
    log_info "Creating user ${RPMOPS_USER}..."
    useradd -r -m -d "${RPMOPS_HOME}" -s /bin/bash "${RPMOPS_USER}"
    log_success "User created"
fi

# Enable lingering for user services to run without login
log_info "Enabling lingering for ${RPMOPS_USER}..."
loginctl enable-linger "${RPMOPS_USER}"
log_success "Lingering enabled"

# Create directory structure
log_info "Creating directory structure..."
sudo -u "${RPMOPS_USER}" mkdir -p "${RPMOPS_HOME}/data"/{repos,lifecycle/testing,lifecycle/stable,bundles/incoming,bundles/processed,keys,certs}
sudo -u "${RPMOPS_USER}" mkdir -p "${RPMOPS_HOME}/ansible"/{inventory,artifacts}
sudo -u "${RPMOPS_USER}" mkdir -p "${RPMOPS_HOME}/.ssh"
sudo -u "${RPMOPS_USER}" mkdir -p "${RPMOPS_HOME}/.config/systemd/user"
chmod 700 "${RPMOPS_HOME}/.ssh"
log_success "Directories created"

# Generate SSH key for Ansible
if [[ ! -f "${RPMOPS_HOME}/.ssh/id_ed25519" ]]; then
    log_info "Generating SSH key..."
    sudo -u "${RPMOPS_USER}" ssh-keygen -t ed25519 -f "${RPMOPS_HOME}/.ssh/id_ed25519" -N "" -C "ansible@airgap-rpm-repo"
    log_success "SSH key generated"
else
    log_info "SSH key already exists"
fi

# Set up subuid/subgid for rootless Podman
log_info "Configuring subuid/subgid..."
if ! grep -q "^${RPMOPS_USER}:" /etc/subuid; then
    echo "${RPMOPS_USER}:100000:65536" >> /etc/subuid
fi
if ! grep -q "^${RPMOPS_USER}:" /etc/subgid; then
    echo "${RPMOPS_USER}:100000:65536" >> /etc/subgid
fi
log_success "subuid/subgid configured"

# Copy systemd service files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/systemd/airgap-rpm-publisher.service" ]]; then
    log_info "Installing systemd service files..."
    cp "${SCRIPT_DIR}/systemd/airgap-rpm-publisher.service" "${RPMOPS_HOME}/.config/systemd/user/"
    cp "${SCRIPT_DIR}/systemd/airgap-ansible-control.service" "${RPMOPS_HOME}/.config/systemd/user/"
    chown -R "${RPMOPS_USER}:${RPMOPS_USER}" "${RPMOPS_HOME}/.config"
    log_success "Service files installed"
fi

# Summary
log_success "Setup complete!"
cat << EOF

Next steps:
1. Build container images:
   sudo -u ${RPMOPS_USER} podman build -t airgap-rpm-publisher:latest \\
       -f containers/rpm-publisher/Containerfile containers/rpm-publisher/
   
   sudo -u ${RPMOPS_USER} podman build -t airgap-ansible-control:latest \\
       -f containers/ansible-ee/Containerfile containers/ansible-ee/

2. Enable and start services:
   sudo -u ${RPMOPS_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${RPMOPS_USER}) \\
       systemctl --user daemon-reload
   
   sudo -u ${RPMOPS_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${RPMOPS_USER}) \\
       systemctl --user enable --now airgap-rpm-publisher
   
   sudo -u ${RPMOPS_USER} XDG_RUNTIME_DIR=/run/user/\$(id -u ${RPMOPS_USER}) \\
       systemctl --user enable --now airgap-ansible-control

3. Copy the SSH public key to managed hosts:
   cat ${RPMOPS_HOME}/.ssh/id_ed25519.pub

Data directories:
  - Repositories: ${RPMOPS_HOME}/data/repos
  - Lifecycle:    ${RPMOPS_HOME}/data/lifecycle
  - Bundles:      ${RPMOPS_HOME}/data/bundles
  - Certificates: ${RPMOPS_HOME}/data/certs
  - Ansible:      ${RPMOPS_HOME}/ansible
EOF
