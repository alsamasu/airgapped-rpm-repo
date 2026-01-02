#!/bin/bash
# scripts/satellite/satellite-install.sh
# Install Red Hat Satellite on external server (connected to internet)
#
# Prerequisites:
#   - RHEL 9.6 installed with kickstart ks-satellite.cfg
#   - System registered with Red Hat subscription
#   - Satellite manifest uploaded
#
# Usage:
#   ./satellite-install.sh --org-id <ORG_ID> --activation-key <KEY>
#   ./satellite-install.sh --manifest /path/to/manifest.zip
#
# Reference: https://access.redhat.com/documentation/en-us/red_hat_satellite

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/satellite-setup}"
MANIFEST_PATH=""
ORG_ID=""
ACTIVATION_KEY=""
SATELLITE_ADMIN_USER="admin"
SATELLITE_ADMIN_PASSWORD=""
SATELLITE_ORG="Default Organization"
SATELLITE_LOCATION="Default Location"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }

usage() {
    cat << 'EOF'
Satellite Installation Script

Usage:
    ./satellite-install.sh [OPTIONS]

Required (one of):
    --org-id ID             Red Hat organization ID
    --activation-key KEY    Red Hat activation key
    OR
    --rhsm-user USER        Red Hat username
    --rhsm-pass PASS        Red Hat password

Optional:
    --manifest PATH         Path to Satellite manifest ZIP file
    --admin-user USER       Satellite admin username (default: admin)
    --admin-pass PASS       Satellite admin password
    --organization NAME     Satellite organization name
    --location NAME         Satellite location name
    --fqdn FQDN             Satellite FQDN (default: hostname)
    --help                  Show this help

Example:
    ./satellite-install.sh \
        --org-id 12043377 \
        --activation-key "satellite-key" \
        --manifest /tmp/satellite-manifest.zip \
        --admin-pass "SecurePass123!"
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org-id)
                ORG_ID="$2"
                shift 2
                ;;
            --activation-key)
                ACTIVATION_KEY="$2"
                shift 2
                ;;
            --manifest)
                MANIFEST_PATH="$2"
                shift 2
                ;;
            --admin-user)
                SATELLITE_ADMIN_USER="$2"
                shift 2
                ;;
            --admin-pass)
                SATELLITE_ADMIN_PASSWORD="$2"
                shift 2
                ;;
            --organization)
                SATELLITE_ORG="$2"
                shift 2
                ;;
            --location)
                SATELLITE_LOCATION="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$SATELLITE_ADMIN_PASSWORD" ]]; then
        log_error "Satellite admin password is required (--admin-pass)"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check RHEL version
    if ! grep -q "Red Hat Enterprise Linux" /etc/redhat-release; then
        log_error "This script requires Red Hat Enterprise Linux"
        exit 1
    fi

    # Check system resources
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb=$((mem_kb / 1024 / 1024))
    if [[ $mem_gb -lt 16 ]]; then
        log_warn "System has ${mem_gb}GB RAM. Satellite recommends 20GB+"
    fi

    # Check /var/lib/pulp mount
    if ! mountpoint -q /var/lib/pulp 2>/dev/null; then
        log_warn "/var/lib/pulp is not a separate mount point"
    fi

    log_info "Prerequisites check complete"
}

register_system() {
    log_info "Registering system with Red Hat..."

    if subscription-manager status 2>/dev/null | grep -q "Overall Status: Current"; then
        log_info "System already registered"
        return 0
    fi

    if [[ -n "$ORG_ID" && -n "$ACTIVATION_KEY" ]]; then
        subscription-manager register \
            --org="$ORG_ID" \
            --activationkey="$ACTIVATION_KEY" \
            --force
    else
        log_error "Registration credentials required"
        exit 1
    fi

    log_info "System registered successfully"
}

enable_satellite_repos() {
    log_info "Enabling Satellite repositories..."

    # Disable all repos first
    subscription-manager repos --disable="*"

    # Enable required repos for Satellite 6.15+
    subscription-manager repos \
        --enable=rhel-9-for-x86_64-baseos-rpms \
        --enable=rhel-9-for-x86_64-appstream-rpms \
        --enable=satellite-6.15-for-rhel-9-x86_64-rpms \
        --enable=satellite-maintenance-6.15-for-rhel-9-x86_64-rpms

    log_info "Repositories enabled"

    # Update system
    log_info "Updating system packages..."
    dnf update -y

    log_info "System update complete"
}

install_satellite_packages() {
    log_info "Installing Satellite packages..."

    dnf module enable satellite:el9 -y
    dnf install satellite -y

    log_info "Satellite packages installed"
}

run_satellite_installer() {
    log_info "Running Satellite installer..."

    local fqdn
    fqdn=$(hostname -f)

    # Run satellite-installer with minimal options
    satellite-installer --scenario satellite \
        --foreman-initial-admin-username "$SATELLITE_ADMIN_USER" \
        --foreman-initial-admin-password "$SATELLITE_ADMIN_PASSWORD" \
        --foreman-initial-organization "$SATELLITE_ORG" \
        --foreman-initial-location "$SATELLITE_LOCATION" \
        --certs-cname "$fqdn" \
        --enable-foreman-plugin-discovery \
        2>&1 | tee -a "${LOG_DIR}/satellite-installer.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Satellite installer failed"
        exit 1
    fi

    log_info "Satellite installer completed successfully"
}

upload_manifest() {
    if [[ -z "$MANIFEST_PATH" ]]; then
        log_warn "No manifest specified. Upload manually via WebUI or hammer CLI"
        return 0
    fi

    if [[ ! -f "$MANIFEST_PATH" ]]; then
        log_error "Manifest file not found: $MANIFEST_PATH"
        exit 1
    fi

    log_info "Uploading Satellite manifest..."

    hammer subscription upload \
        --organization "$SATELLITE_ORG" \
        --file "$MANIFEST_PATH"

    log_info "Manifest uploaded successfully"
}

create_lifecycle_environments() {
    log_info "Creating lifecycle environments..."

    # Create test environment (after Library)
    hammer lifecycle-environment create \
        --organization "$SATELLITE_ORG" \
        --name "test" \
        --description "Testing environment for validation" \
        --prior "Library" 2>/dev/null || log_info "test environment already exists"

    # Create prod environment (after test)
    hammer lifecycle-environment create \
        --organization "$SATELLITE_ORG" \
        --name "prod" \
        --description "Production environment for managed hosts" \
        --prior "test" 2>/dev/null || log_info "prod environment already exists"

    log_info "Lifecycle environments created"
}

generate_install_report() {
    log_info "Generating installation report..."

    local report_file="${LOG_DIR}/install-report-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << REPORT
================================================================================
Satellite Installation Report
================================================================================
Date: $(date)
Hostname: $(hostname -f)
IP Address: $(hostname -I | awk '{print $1}')

Satellite Version:
$(rpm -q satellite 2>/dev/null || echo "Not installed")

Services Status:
$(satellite-maintain service status 2>/dev/null || echo "Could not check services")

Web UI: https://$(hostname -f)
Username: ${SATELLITE_ADMIN_USER}

Organization: ${SATELLITE_ORG}
Location: ${SATELLITE_LOCATION}

Lifecycle Environments:
$(hammer lifecycle-environment list --organization "$SATELLITE_ORG" 2>/dev/null || echo "Could not list")

================================================================================
REPORT

    log_info "Report saved to: $report_file"
    cat "$report_file"
}

main() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "${LOG_DIR}/satellite-install-$(date +%Y%m%d-%H%M%S).log") 2>&1

    log_info "Starting Satellite installation..."

    parse_args "$@"
    check_prerequisites
    register_system
    enable_satellite_repos
    install_satellite_packages
    run_satellite_installer
    upload_manifest
    create_lifecycle_environments
    generate_install_report

    log_info "Satellite installation complete!"
    log_info "Web UI available at: https://$(hostname -f)"
}

main "$@"
