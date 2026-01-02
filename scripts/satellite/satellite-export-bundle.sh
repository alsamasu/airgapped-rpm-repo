#!/bin/bash
# scripts/satellite/satellite-export-bundle.sh
# Export Content View versions as a disconnected bundle for airgap transfer
#
# Usage:
#   ./satellite-export-bundle.sh --org "Default Organization" --output-dir /var/lib/pulp/exports
#
# This script:
#   1. Exports specified Content Views as a complete bundle
#   2. Generates manifest and checksums
#   3. Creates a transfer-ready archive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/satellite-setup}"
ORG_NAME="Default Organization"
OUTPUT_DIR="/var/lib/pulp/exports"
BUNDLE_PREFIX="airgap-security-bundle"
EXPORT_TYPE="complete"  # complete or incremental
CONTENT_VIEWS=("cv_rhel8_security" "cv_rhel9_security")
LIFECYCLE_ENV="prod"

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
Satellite Content Export Script

Usage:
    ./satellite-export-bundle.sh [OPTIONS]

Options:
    --org NAME              Organization name (default: Default Organization)
    --output-dir DIR        Export output directory (default: /var/lib/pulp/exports)
    --bundle-prefix NAME    Bundle name prefix (default: airgap-security-bundle)
    --lifecycle-env ENV     Lifecycle environment to export (default: prod)
    --incremental           Export incremental (delta) instead of complete
    --content-view CV       Content View to export (can be repeated)
    --help                  Show this help

Example:
    ./satellite-export-bundle.sh \
        --org "MyOrg" \
        --lifecycle-env prod \
        --output-dir /mnt/transfer
EOF
    exit 1
}

parse_args() {
    local custom_cvs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org)
                ORG_NAME="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --bundle-prefix)
                BUNDLE_PREFIX="$2"
                shift 2
                ;;
            --lifecycle-env)
                LIFECYCLE_ENV="$2"
                shift 2
                ;;
            --incremental)
                EXPORT_TYPE="incremental"
                shift
                ;;
            --content-view)
                custom_cvs+=("$2")
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

    if [[ ${#custom_cvs[@]} -gt 0 ]]; then
        CONTENT_VIEWS=("${custom_cvs[@]}")
    fi
}

check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check if running as root or satellite user
    if [[ $EUID -ne 0 ]] && [[ "$(whoami)" != "foreman" ]]; then
        log_warn "Running as non-root user. Some operations may fail."
    fi

    # Check output directory
    mkdir -p "$OUTPUT_DIR"
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        log_error "Cannot write to output directory: $OUTPUT_DIR"
        exit 1
    fi

    # Verify Content Views exist
    for cv in "${CONTENT_VIEWS[@]}"; do
        if ! hammer content-view info --organization "$ORG_NAME" --name "$cv" &>/dev/null; then
            log_error "Content View not found: $cv"
            exit 1
        fi
    done

    log_info "Prerequisites check passed"
}

get_cv_version_in_env() {
    local cv="$1"
    local env="$2"

    hammer content-view version list \
        --organization "$ORG_NAME" \
        --content-view "$cv" \
        --lifecycle-environment "$env" \
        --fields="Version" 2>/dev/null | tail -1 | awk '{print $1}'
}

export_content_view() {
    local cv="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local export_name="${BUNDLE_PREFIX}-${cv}-${timestamp}"

    log_step "Exporting Content View: $cv"

    # Get version in lifecycle environment
    local version
    version=$(get_cv_version_in_env "$cv" "$LIFECYCLE_ENV")

    if [[ -z "$version" ]]; then
        log_error "No version of $cv found in $LIFECYCLE_ENV environment"
        return 1
    fi

    log_info "Exporting $cv version $version from $LIFECYCLE_ENV..."

    # Create export directory
    local export_dir="${OUTPUT_DIR}/${export_name}"
    mkdir -p "$export_dir"

    # Export using hammer (Satellite 6.10+)
    if [[ "$EXPORT_TYPE" == "complete" ]]; then
        hammer content-export complete version \
            --organization "$ORG_NAME" \
            --content-view "$cv" \
            --version "$version" \
            --destination-server "disconnected" \
            --format "syncable" 2>&1 | tee -a "${LOG_DIR}/export-${cv}.log"
    else
        hammer content-export incremental version \
            --organization "$ORG_NAME" \
            --content-view "$cv" \
            --version "$version" \
            --destination-server "disconnected" \
            --format "syncable" 2>&1 | tee -a "${LOG_DIR}/export-${cv}.log"
    fi

    # Move exported content to our bundle directory
    local pulp_export_dir="/var/lib/pulp/exports"
    local latest_export
    latest_export=$(ls -td "${pulp_export_dir}"/*/ 2>/dev/null | head -1)

    if [[ -d "$latest_export" ]]; then
        log_info "Moving export from $latest_export to $export_dir"
        mv "$latest_export"/* "$export_dir/" 2>/dev/null || true
        rmdir "$latest_export" 2>/dev/null || true
    fi

    echo "$export_name"
}

generate_bundle_manifest() {
    log_step "Generating bundle manifest..."

    local bundle_dir="$1"
    local manifest_file="${bundle_dir}/MANIFEST.json"

    cat > "$manifest_file" << MANIFEST
{
    "bundle_name": "$(basename "$bundle_dir")",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "created_by": "satellite-export-bundle.sh",
    "satellite_version": "$(rpm -q satellite --qf '%{VERSION}' 2>/dev/null || echo 'unknown')",
    "organization": "${ORG_NAME}",
    "lifecycle_environment": "${LIFECYCLE_ENV}",
    "export_type": "${EXPORT_TYPE}",
    "content_views": $(printf '%s\n' "${CONTENT_VIEWS[@]}" | jq -R . | jq -s .),
    "file_count": $(find "$bundle_dir" -type f | wc -l),
    "total_size_bytes": $(du -sb "$bundle_dir" | cut -f1)
}
MANIFEST

    log_info "Manifest created: $manifest_file"
}

generate_checksums() {
    log_step "Generating checksums..."

    local bundle_dir="$1"
    local checksum_file="${bundle_dir}/SHA256SUMS.txt"

    cd "$bundle_dir"
    find . -type f ! -name "SHA256SUMS.txt" -exec sha256sum {} \; > "$checksum_file"

    log_info "Checksums saved to: $checksum_file"
}

create_transfer_archive() {
    log_step "Creating transfer archive..."

    local bundle_dir="$1"
    local bundle_name
    bundle_name=$(basename "$bundle_dir")
    local archive_path="${OUTPUT_DIR}/${bundle_name}.tar.gz"

    cd "$(dirname "$bundle_dir")"
    tar -czf "$archive_path" "$bundle_name"

    # Generate archive checksum
    sha256sum "$archive_path" > "${archive_path}.sha256"

    log_info "Transfer archive created: $archive_path"
    log_info "Archive size: $(du -h "$archive_path" | cut -f1)"

    echo "$archive_path"
}

generate_export_report() {
    log_step "Generating export report..."

    local report_file="${LOG_DIR}/export-report-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << REPORT
================================================================================
Satellite Content Export Report
================================================================================
Date: $(date)
Organization: ${ORG_NAME}
Lifecycle Environment: ${LIFECYCLE_ENV}
Export Type: ${EXPORT_TYPE}

Content Views Exported:
$(printf '  - %s\n' "${CONTENT_VIEWS[@]}")

Output Directory: ${OUTPUT_DIR}

Generated Bundles:
$(ls -lh "${OUTPUT_DIR}"/*.tar.gz 2>/dev/null || echo "  None")

Instructions:
1. Copy the .tar.gz bundle and .sha256 file to transfer media
2. Transport to airgapped environment
3. Run capsule-import.sh on the internal Capsule server

================================================================================
REPORT

    log_info "Report saved to: $report_file"
    cat "$report_file"
}

main() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "${LOG_DIR}/export-$(date +%Y%m%d-%H%M%S).log") 2>&1

    parse_args "$@"

    log_info "Starting content export..."
    log_info "Organization: $ORG_NAME"
    log_info "Content Views: ${CONTENT_VIEWS[*]}"
    log_info "Lifecycle Environment: $LIFECYCLE_ENV"

    check_prerequisites

    # Create combined bundle directory
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local bundle_dir="${OUTPUT_DIR}/${BUNDLE_PREFIX}-${timestamp}"
    mkdir -p "$bundle_dir"

    # Export each Content View
    for cv in "${CONTENT_VIEWS[@]}"; do
        export_content_view "$cv"
    done

    # Generate metadata
    generate_bundle_manifest "$bundle_dir"
    generate_checksums "$bundle_dir"

    # Create transfer archive
    local archive_path
    archive_path=$(create_transfer_archive "$bundle_dir")

    generate_export_report

    log_info "Export complete!"
    log_info "Transfer bundle: $archive_path"
}

main "$@"
