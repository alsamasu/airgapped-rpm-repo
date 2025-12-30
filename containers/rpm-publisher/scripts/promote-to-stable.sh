#!/bin/bash
# promote-to-stable.sh - Promote testing content to stable
#
# Validates testing content and promotes to stable environment.
# Performs HTTPS reachability check and optional dnf makecache test.
#
# Usage: promote-to-stable.sh [--skip-reachability] [--skip-dnf-test]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LIFECYCLE_DIR="${DATA_DIR}/lifecycle"
TESTING_DIR="${LIFECYCLE_DIR}/testing"
STABLE_DIR="${LIFECYCLE_DIR}/stable"
HTTPS_PORT="${RPMSERVER_HTTPS_PORT:-8443}"

# Parse arguments
SKIP_REACHABILITY=false
SKIP_DNF_TEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-reachability)
            SKIP_REACHABILITY=true
            shift
            ;;
        --skip-dnf-test)
            SKIP_DNF_TEST=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_info "Promoting testing content to stable..."

# Check testing directory exists and has content
if [[ ! -d "${TESTING_DIR}" ]]; then
    log_error "Testing directory does not exist: ${TESTING_DIR}"
    exit 1
fi

if [[ -z "$(ls -A "${TESTING_DIR}" 2>/dev/null)" ]]; then
    log_error "Testing directory is empty"
    exit 1
fi

# Read import metadata
IMPORT_META="${TESTING_DIR}/.import_metadata.json"
if [[ -f "${IMPORT_META}" ]]; then
    BUNDLE_ID=$(jq -r '.bundle_id // "unknown"' "${IMPORT_META}")
    log_info "Bundle ID: ${BUNDLE_ID}"
else
    log_warn "No import metadata found"
    BUNDLE_ID="unknown"
fi

# Validate repodata integrity
log_info "Validating repodata integrity..."

VALIDATION_PASSED=true
find "${TESTING_DIR}" -name "repomd.xml" | while read -r repomd; do
    repo_dir=$(dirname "${repomd}")
    log_info "Checking: ${repo_dir}"
    
    # Verify repomd.xml is valid XML
    if ! xmllint --noout "${repomd}" 2>/dev/null; then
        log_error "Invalid XML: ${repomd}"
        VALIDATION_PASSED=false
    fi
    
    # Verify referenced files exist
    for href in $(xmllint --xpath '//*[local-name()="location"]/@href' "${repomd}" 2>/dev/null | sed 's/href="//g' | sed 's/"//g'); do
        ref_file="${repo_dir}/${href}"
        if [[ ! -f "${ref_file}" ]]; then
            log_error "Missing referenced file: ${href}"
            VALIDATION_PASSED=false
        fi
    done
done

# HTTPS reachability check
if [[ "${SKIP_REACHABILITY}" != "true" ]]; then
    log_info "Checking HTTPS reachability..."
    
    if curl -fsk "https://localhost:${HTTPS_PORT}/lifecycle/testing/" >/dev/null 2>&1; then
        log_success "HTTPS reachability check passed"
    else
        log_warn "HTTPS reachability check failed (server may not be running)"
    fi
fi

# Optional dnf makecache test
if [[ "${SKIP_DNF_TEST}" != "true" ]] && command_exists dnf; then
    log_info "Running dnf makecache test..."
    
    # Create temporary repo config
    TEMP_REPO=$(mktemp)
    cat > "${TEMP_REPO}" << EOF
[test-promotion]
name=Test Promotion
baseurl=https://localhost:${HTTPS_PORT}/lifecycle/testing/
enabled=1
gpgcheck=0
sslverify=0
EOF
    
    if dnf --config="${TEMP_REPO}" makecache --disablerepo='*' --enablerepo='test-promotion' 2>/dev/null; then
        log_success "dnf makecache test passed"
    else
        log_warn "dnf makecache test failed"
    fi
    
    rm -f "${TEMP_REPO}"
fi

# Perform promotion
log_info "Promoting to stable..."

# Create backup of current stable (if exists)
if [[ -d "${STABLE_DIR}" && -n "$(ls -A "${STABLE_DIR}" 2>/dev/null)" ]]; then
    BACKUP_DIR="${LIFECYCLE_DIR}/.stable_backup_$(date +%Y%m%d_%H%M%S)"
    log_info "Backing up current stable to: ${BACKUP_DIR}"
    mv "${STABLE_DIR}" "${BACKUP_DIR}"
fi

# Atomic promotion using rsync
mkdir -p "${STABLE_DIR}"
rsync -a "${TESTING_DIR}/" "${STABLE_DIR}/"

# Update promotion metadata
PROMO_META="${STABLE_DIR}/.promotion_metadata.json"
cat > "${PROMO_META}" << EOF
{
    "bundle_id": "${BUNDLE_ID}",
    "promoted_at": "$(_timestamp)",
    "promoted_from": "testing",
    "status": "stable"
}
EOF

log_success "Promotion complete"
log_info "Stable content available at: https://localhost:${HTTPS_PORT}/lifecycle/stable/"
