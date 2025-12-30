#!/bin/bash
# generate_client_config.sh - Generate client configuration files
#
# This script generates .repo files and GPG key distribution scripts
# for internal RHEL hosts.
#
# Usage:
#   ./generate_client_config.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LIFECYCLE_DIR="${DATA_DIR}/lifecycle"
CLIENT_CONFIG_DIR="${DATA_DIR}/client-config"
KEYS_DIR="${DATA_DIR}/keys"

BASE_URL="${RPMSERVER_BASE_URL:-http://repo.internal.local:8080}"
LIFECYCLE="prod"
PROFILES="rhel8 rhel9"

usage() {
    cat << 'EOF'
Generate Client Configuration Files

Generates .repo files and GPG key distribution scripts for
internal RHEL hosts.

Usage:
  ./generate_client_config.sh [options]

Options:
  --base-url URL       Base URL for repository (default: http://repo.internal.local:8080)
  --lifecycle CHANNEL  Lifecycle channel (default: prod)
  --profiles PROFILES  Profiles to generate for (default: "rhel8 rhel9")
  -h, --help           Show this help message

Output:
  /data/client-config/
    rhel8/
      internal.repo
      install-repo.sh
    rhel9/
      internal.repo
      install-repo.sh
    RPM-GPG-KEY-internal
    README.txt

Examples:
  # Generate with defaults
  ./generate_client_config.sh

  # Generate for specific base URL
  ./generate_client_config.sh --base-url https://repo.corp.local

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url)
                BASE_URL="$2"
                shift 2
                ;;
            --lifecycle)
                LIFECYCLE="$2"
                shift 2
                ;;
            --profiles)
                PROFILES="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

generate_repo_file() {
    local profile="$1"
    local output_dir="${CLIENT_CONFIG_DIR}/${profile}"

    mkdir -p "${output_dir}"

    local repo_file="${output_dir}/internal.repo"

    log_info "Generating repo file for ${profile}..."

    cat > "${repo_file}" << REPO
# Internal RPM Repository Configuration
# Profile: ${profile}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Lifecycle: ${LIFECYCLE}

[internal-${profile}-baseos]
name=Internal ${profile^^} BaseOS Repository
baseurl=${BASE_URL}/lifecycle/${LIFECYCLE}/repos/${profile}/x86_64/baseos/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-internal
sslverify=0
metadata_expire=1h

[internal-${profile}-appstream]
name=Internal ${profile^^} AppStream Repository
baseurl=${BASE_URL}/lifecycle/${LIFECYCLE}/repos/${profile}/x86_64/appstream/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-internal
sslverify=0
metadata_expire=1h
REPO

    log_success "Generated: ${repo_file}"
}

generate_install_script() {
    local profile="$1"
    local output_dir="${CLIENT_CONFIG_DIR}/${profile}"

    local script_file="${output_dir}/install-repo.sh"

    log_info "Generating install script for ${profile}..."

    cat > "${script_file}" << 'SCRIPT'
#!/bin/bash
# install-repo.sh - Install internal repository configuration
#
# This script installs the internal repository configuration and GPG key
# on RHEL hosts.
#
# Usage:
#   sudo ./install-repo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
fi

# Detect OS
if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot detect OS version"
fi

source /etc/os-release

log_info "Detected OS: ${ID} ${VERSION_ID}"

# Install GPG key
log_info "Installing GPG key..."

GPG_KEY="${SCRIPT_DIR}/../RPM-GPG-KEY-internal"
if [[ ! -f "${GPG_KEY}" ]]; then
    GPG_KEY="${SCRIPT_DIR}/RPM-GPG-KEY-internal"
fi

if [[ -f "${GPG_KEY}" ]]; then
    cp "${GPG_KEY}" /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-internal
    log_info "GPG key installed"
else
    log_warn "GPG key not found, skipping import"
fi

# Install repo file
log_info "Installing repository configuration..."

REPO_FILE="${SCRIPT_DIR}/internal.repo"
if [[ -f "${REPO_FILE}" ]]; then
    # Disable existing Red Hat repos (optional - uncomment if needed)
    # subscription-manager repos --disable="*" 2>/dev/null || true

    cp "${REPO_FILE}" /etc/yum.repos.d/internal.repo
    log_info "Repository configuration installed"
else
    log_error "Repository file not found: ${REPO_FILE}"
fi

# Clear cache
log_info "Clearing DNF cache..."
dnf clean all

# Test repository
log_info "Testing repository access..."
if dnf repolist | grep -q "internal"; then
    log_info "Repository accessible"
else
    log_warn "Repository may not be accessible, check network connectivity"
fi

log_info "Installation complete!"
log_info "Run 'dnf update' to check for available updates"
SCRIPT

    chmod +x "${script_file}"
    log_success "Generated: ${script_file}"
}

copy_gpg_key() {
    log_info "Copying GPG key..."

    local key_sources=(
        "${LIFECYCLE_DIR}/${LIFECYCLE}/keys/RPM-GPG-KEY-internal"
        "${KEYS_DIR}/RPM-GPG-KEY-internal"
    )

    for key_src in "${key_sources[@]}"; do
        if [[ -f "${key_src}" ]]; then
            cp "${key_src}" "${CLIENT_CONFIG_DIR}/RPM-GPG-KEY-internal"
            log_success "GPG key copied"
            return 0
        fi
    done

    log_warn "No GPG key found to copy"
    return 1
}

generate_readme() {
    local readme_file="${CLIENT_CONFIG_DIR}/README.txt"

    log_info "Generating README..."

    cat > "${readme_file}" << README
INTERNAL RPM REPOSITORY - CLIENT CONFIGURATION
===============================================

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Base URL: ${BASE_URL}
Lifecycle: ${LIFECYCLE}

Contents
--------
- RPM-GPG-KEY-internal    GPG public key for package verification
- rhel8/                  Configuration for RHEL 8.x hosts
  - internal.repo         Repository configuration file
  - install-repo.sh       Installation script
- rhel9/                  Configuration for RHEL 9.x hosts
  - internal.repo         Repository configuration file
  - install-repo.sh       Installation script

Quick Installation
------------------
On each internal RHEL host:

1. Copy the appropriate directory to the host:
   scp -r rhel9/ root@hostname:/tmp/repo-config/

2. Run the installation script:
   ssh root@hostname "cd /tmp/repo-config/rhel9 && ./install-repo.sh"

3. Verify installation:
   dnf repolist
   dnf check-update

Manual Installation
-------------------
1. Copy the GPG key:
   cp RPM-GPG-KEY-internal /etc/pki/rpm-gpg/
   rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-internal

2. Copy the repo file:
   cp rhel9/internal.repo /etc/yum.repos.d/

3. Clear cache and test:
   dnf clean all
   dnf repolist

Troubleshooting
---------------
- If dnf cannot reach the repository, verify network connectivity
  to ${BASE_URL}

- If GPG verification fails, ensure the key is imported:
  rpm -qa gpg-pubkey*

- To skip GPG checking temporarily (not recommended):
  dnf install --nogpgcheck <package>

Support
-------
Contact your repository administrator for support.
README

    log_success "Generated: ${readme_file}"
}

show_summary() {
    echo ""
    log_section "Client Configuration Summary"
    echo ""
    echo "Output directory: ${CLIENT_CONFIG_DIR}"
    echo ""
    echo "Files generated:"
    find "${CLIENT_CONFIG_DIR}" -type f | while read -r file; do
        echo "  ${file#${CLIENT_CONFIG_DIR}/}"
    done
    echo ""
    log_info "Distribute these files to internal hosts"
}

main() {
    parse_args "$@"

    log_section "Generate Client Configuration"

    log_info "Base URL: ${BASE_URL}"
    log_info "Lifecycle: ${LIFECYCLE}"
    log_info "Profiles: ${PROFILES}"

    # Create output directory
    rm -rf "${CLIENT_CONFIG_DIR}"
    mkdir -p "${CLIENT_CONFIG_DIR}"

    # Generate for each profile
    for profile in ${PROFILES}; do
        generate_repo_file "${profile}"
        generate_install_script "${profile}"
    done

    # Copy GPG key
    copy_gpg_key || true

    # Generate README
    generate_readme

    show_summary

    log_audit "CLIENT_CONFIG_GENERATED" "Generated client config for profiles: ${PROFILES}"

    log_success "Client configuration generated"
}

main "$@"
