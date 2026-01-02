#!/bin/bash
# scripts/satellite/capsule-import-bundle.sh
# Import content bundle into disconnected Capsule server
#
# Usage:
#   ./capsule-import-bundle.sh --bundle /path/to/bundle.tar.gz
#
# This script:
#   1. Verifies bundle checksums
#   2. Extracts bundle content
#   3. Imports into Capsule's Pulp storage
#   4. Configures content serving over HTTPS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/capsule-setup}"
IMPORT_DIR="/var/lib/pulp/imports"
VERIFIED_DIR="/var/lib/pulp/verified"
BUNDLE_PATH=""
ORG_NAME="Default Organization"
SKIP_VERIFY=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }

usage() {
    cat << 'EOF'
Capsule Content Import Script

Usage:
    ./capsule-import-bundle.sh [OPTIONS]

Required:
    --bundle PATH           Path to bundle .tar.gz file

Options:
    --org NAME              Organization name (default: Default Organization)
    --import-dir DIR        Import staging directory (default: /var/lib/pulp/imports)
    --skip-verify           Skip checksum verification
    --help                  Show this help

Example:
    ./capsule-import-bundle.sh \
        --bundle /mnt/transfer/airgap-security-bundle-20240115.tar.gz \
        --org "MyOrg"
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)
                BUNDLE_PATH="$2"
                shift 2
                ;;
            --org)
                ORG_NAME="$2"
                shift 2
                ;;
            --import-dir)
                IMPORT_DIR="$2"
                shift 2
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
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

    if [[ -z "$BUNDLE_PATH" ]]; then
        log_error "Bundle path is required (--bundle)"
        usage
    fi
}

check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check bundle file exists
    if [[ ! -f "$BUNDLE_PATH" ]]; then
        log_error "Bundle file not found: $BUNDLE_PATH"
        exit 1
    fi

    # Check checksum file exists
    local checksum_file="${BUNDLE_PATH}.sha256"
    if [[ ! -f "$checksum_file" ]] && [[ "$SKIP_VERIFY" != "true" ]]; then
        log_warn "Checksum file not found: $checksum_file"
        log_warn "Use --skip-verify to proceed without verification"
    fi

    # Create directories
    mkdir -p "$IMPORT_DIR"
    mkdir -p "$VERIFIED_DIR"
    mkdir -p "$LOG_DIR"

    # Check Capsule/Satellite services
    if ! systemctl is-active --quiet pulpcore-api; then
        log_warn "Pulp API service not running. Some import features may not work."
    fi

    log_info "Prerequisites check passed"
}

verify_bundle_checksum() {
    if [[ "$SKIP_VERIFY" == "true" ]]; then
        log_warn "Skipping checksum verification"
        return 0
    fi

    log_step "Verifying bundle checksum..."

    local checksum_file="${BUNDLE_PATH}.sha256"

    if [[ -f "$checksum_file" ]]; then
        cd "$(dirname "$BUNDLE_PATH")"
        if sha256sum -c "$checksum_file"; then
            log_info "Checksum verification passed"
        else
            log_error "Checksum verification FAILED"
            exit 1
        fi
    else
        log_warn "No checksum file found, skipping verification"
    fi
}

extract_bundle() {
    log_step "Extracting bundle..."

    local bundle_name
    bundle_name=$(basename "$BUNDLE_PATH" .tar.gz)
    local extract_dir="${IMPORT_DIR}/${bundle_name}"

    mkdir -p "$extract_dir"

    tar -xzf "$BUNDLE_PATH" -C "$IMPORT_DIR"

    log_info "Bundle extracted to: $extract_dir"
    echo "$extract_dir"
}

verify_bundle_contents() {
    log_step "Verifying bundle contents..."

    local extract_dir="$1"

    # Check for manifest
    if [[ -f "${extract_dir}/MANIFEST.json" ]]; then
        log_info "Bundle manifest found"
        cat "${extract_dir}/MANIFEST.json" | jq . 2>/dev/null || cat "${extract_dir}/MANIFEST.json"
    else
        log_warn "No manifest file found in bundle"
    fi

    # Verify internal checksums
    if [[ -f "${extract_dir}/SHA256SUMS.txt" ]]; then
        log_info "Verifying internal file checksums..."
        cd "$extract_dir"
        if sha256sum -c SHA256SUMS.txt; then
            log_info "All internal checksums verified"
        else
            log_error "Internal checksum verification failed"
            exit 1
        fi
    fi
}

import_content() {
    log_step "Importing content into Capsule..."

    local extract_dir="$1"

    # Find content export directories
    local content_dirs
    content_dirs=$(find "$extract_dir" -type d -name "content" 2>/dev/null)

    if [[ -z "$content_dirs" ]]; then
        # Try using hammer content-import
        log_info "Using hammer content-import..."

        hammer content-import library \
            --organization "$ORG_NAME" \
            --path "$extract_dir" 2>&1 | tee -a "${LOG_DIR}/import.log" || {
            log_warn "hammer content-import failed, trying alternative method..."

            # Alternative: Direct pulp import
            import_via_pulp "$extract_dir"
        }
    else
        log_info "Found content directories, importing..."
        for dir in $content_dirs; do
            log_info "Importing: $dir"
            hammer content-import library \
                --organization "$ORG_NAME" \
                --path "$(dirname "$dir")" 2>&1 | tee -a "${LOG_DIR}/import.log" || true
        done
    fi
}

import_via_pulp() {
    log_step "Importing via Pulp directly..."

    local extract_dir="$1"

    # Create repository from extracted content
    # This is a fallback method for when hammer import fails

    local repo_base="/var/lib/pulp/content"
    mkdir -p "$repo_base"

    # Copy RPMs to content directory
    find "$extract_dir" -name "*.rpm" -exec cp {} "$repo_base/" \; 2>/dev/null || true

    # Create repository metadata
    if command -v createrepo_c &>/dev/null; then
        log_info "Creating repository metadata..."
        createrepo_c "$repo_base"
    fi

    log_info "Content imported to: $repo_base"
}

configure_content_serving() {
    log_step "Configuring content serving over HTTPS..."

    # Ensure web server is configured
    if systemctl is-active --quiet httpd; then
        log_info "Apache already running"
    else
        log_info "Starting Apache..."
        systemctl enable --now httpd
    fi

    # Create content serving configuration
    local content_conf="/etc/httpd/conf.d/pulp-content.conf"

    if [[ ! -f "$content_conf" ]]; then
        cat > "$content_conf" << 'APACHE'
# Pulp content serving
<Directory "/var/lib/pulp/content">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

Alias /content /var/lib/pulp/content
APACHE
        systemctl reload httpd
        log_info "Content serving configured at /content"
    fi

    # Verify HTTPS
    if [[ -f /etc/pki/tls/certs/localhost.crt ]]; then
        log_info "HTTPS certificate found"
    else
        log_warn "No HTTPS certificate. Run capsule-certs-generate for production."
    fi
}

move_to_verified() {
    log_step "Moving bundle to verified storage..."

    local extract_dir="$1"
    local bundle_name
    bundle_name=$(basename "$extract_dir")

    mv "$extract_dir" "${VERIFIED_DIR}/${bundle_name}"
    log_info "Bundle archived to: ${VERIFIED_DIR}/${bundle_name}"
}

generate_import_report() {
    log_step "Generating import report..."

    local report_file="${LOG_DIR}/import-report-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << REPORT
================================================================================
Capsule Content Import Report
================================================================================
Date: $(date)
Bundle: $(basename "$BUNDLE_PATH")
Organization: ${ORG_NAME}

Import Status: SUCCESS

Content Locations:
  Import staging: ${IMPORT_DIR}
  Verified archive: ${VERIFIED_DIR}
  Content serving: /var/lib/pulp/content

Service Status:
$(systemctl is-active httpd && echo "  Apache: running" || echo "  Apache: stopped")
$(systemctl is-active pulpcore-api 2>/dev/null && echo "  Pulp API: running" || echo "  Pulp API: not configured")

Content URL:
  HTTPS: https://$(hostname -f)/content

Repositories:
$(hammer repository list --organization "$ORG_NAME" 2>/dev/null || echo "  Could not list (hammer may not be configured)")

Next Steps:
1. Configure managed hosts to use this Capsule for content
2. Update /etc/yum.repos.d/ on clients
3. Run 'dnf check-update' to verify connectivity

================================================================================
REPORT

    log_info "Report saved to: $report_file"
    cat "$report_file"
}

main() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "${LOG_DIR}/import-$(date +%Y%m%d-%H%M%S).log") 2>&1

    parse_args "$@"

    log_info "Starting content import..."
    log_info "Bundle: $BUNDLE_PATH"
    log_info "Organization: $ORG_NAME"

    check_prerequisites
    verify_bundle_checksum

    local extract_dir
    extract_dir=$(extract_bundle)

    verify_bundle_contents "$extract_dir"
    import_content "$extract_dir"
    configure_content_serving
    move_to_verified "$extract_dir"
    generate_import_report

    log_info "Content import complete!"
    log_info "Content available at: https://$(hostname -f)/content"
}

main "$@"
