#!/bin/bash
# import-bundle.sh - Import and validate an RPM bundle
#
# Validates bundle integrity, imports to testing environment,
# and optionally promotes to stable after validation.
#
# Usage: import-bundle.sh <bundle.tar.gz> [--promote]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
BUNDLES_DIR="${DATA_DIR}/bundles"
LIFECYCLE_DIR="${DATA_DIR}/lifecycle"
KEYS_DIR="${DATA_DIR}/keys"

usage() {
    cat << EOF
Usage: $(basename "$0") <bundle.tar.gz> [OPTIONS]

Import an RPM bundle into the repository.

Options:
    --promote       Auto-promote to stable after validation
    --skip-gpg      Skip GPG signature verification
    --help          Show this help message

The bundle must contain:
    - BOM.json      Bill of Materials with checksums
    - repos/        Repository content
    - keys/         GPG keys (optional)
EOF
    exit 1
}

# Parse arguments
BUNDLE_FILE=""
AUTO_PROMOTE=false
SKIP_GPG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --promote)
            AUTO_PROMOTE=true
            shift
            ;;
        --skip-gpg)
            SKIP_GPG=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "${BUNDLE_FILE}" ]]; then
                BUNDLE_FILE="$1"
            else
                log_error "Multiple bundle files specified"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "${BUNDLE_FILE}" ]]; then
    log_error "No bundle file specified"
    usage
fi

if [[ ! -f "${BUNDLE_FILE}" ]]; then
    log_error "Bundle file not found: ${BUNDLE_FILE}"
    exit 1
fi

log_info "Importing bundle: ${BUNDLE_FILE}"

# Create work directory
WORK_DIR=$(mktemp -d "${BUNDLES_DIR}/import.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

# Extract bundle
log_info "Extracting bundle..."
tar -xzf "${BUNDLE_FILE}" -C "${WORK_DIR}"

# Verify BOM exists
BOM_FILE="${WORK_DIR}/BOM.json"
if [[ ! -f "${BOM_FILE}" ]]; then
    log_error "BOM.json not found in bundle"
    exit 1
fi

log_info "Validating bundle contents..."

# Parse BOM and verify checksums
BUNDLE_ID=$(jq -r '.bundle_id // "unknown"' "${BOM_FILE}")
BUNDLE_DATE=$(jq -r '.created_at // "unknown"' "${BOM_FILE}")
log_info "Bundle ID: ${BUNDLE_ID}"
log_info "Bundle date: ${BUNDLE_DATE}"

# Verify each file in BOM
VALIDATION_FAILED=false
while IFS= read -r entry; do
    file_path=$(echo "${entry}" | jq -r '.path')
    expected_checksum=$(echo "${entry}" | jq -r '.sha256')
    
    full_path="${WORK_DIR}/${file_path}"
    if [[ ! -f "${full_path}" ]]; then
        log_error "Missing file from BOM: ${file_path}"
        VALIDATION_FAILED=true
        continue
    fi
    
    if ! verify_checksum "${full_path}" "${expected_checksum}" sha256; then
        VALIDATION_FAILED=true
    fi
done < <(jq -c '.files[]' "${BOM_FILE}")

if [[ "${VALIDATION_FAILED}" == "true" ]]; then
    log_error "Bundle validation failed"
    exit 1
fi

log_success "Bundle validation passed"

# Verify GPG signatures on repodata (if not skipped)
if [[ "${SKIP_GPG}" != "true" ]]; then
    log_info "Verifying GPG signatures..."
    
    # Import any GPG keys from bundle
    if [[ -d "${WORK_DIR}/keys" ]]; then
        for key_file in "${WORK_DIR}/keys"/*.asc "${WORK_DIR}/keys"/*.gpg "${WORK_DIR}/keys"/*.key; do
            if [[ -f "${key_file}" ]]; then
                log_info "Importing GPG key: $(basename "${key_file}")"
                gpg --import "${key_file}" 2>/dev/null || true
                # Copy to keys directory
                cp "${key_file}" "${KEYS_DIR}/"
            fi
        done
    fi
    
    # Verify repomd.xml.asc signatures if present
    find "${WORK_DIR}/repos" -name "repomd.xml.asc" | while read -r sig_file; do
        xml_file="${sig_file%.asc}"
        if [[ -f "${xml_file}" ]]; then
            if gpg --verify "${sig_file}" "${xml_file}" 2>/dev/null; then
                log_success "GPG signature valid: ${xml_file}"
            else
                log_warn "GPG signature verification failed: ${xml_file}"
            fi
        fi
    done
fi

# Import to testing environment
log_info "Importing to testing environment..."

TESTING_DIR="${LIFECYCLE_DIR}/testing"
mkdir -p "${TESTING_DIR}"

# Copy repos content
if [[ -d "${WORK_DIR}/repos" ]]; then
    rsync -a --delete "${WORK_DIR}/repos/" "${TESTING_DIR}/"
fi

# Create import metadata
IMPORT_META="${TESTING_DIR}/.import_metadata.json"
cat > "${IMPORT_META}" << EOF
{
    "bundle_id": "${BUNDLE_ID}",
    "bundle_file": "$(basename "${BUNDLE_FILE}")",
    "imported_at": "$(_timestamp)",
    "source_date": "${BUNDLE_DATE}",
    "status": "testing"
}
EOF

log_success "Bundle imported to testing environment"

# Move bundle to processed directory
PROCESSED_DIR="${BUNDLES_DIR}/processed"
mkdir -p "${PROCESSED_DIR}"
mv "${BUNDLE_FILE}" "${PROCESSED_DIR}/"
log_info "Bundle moved to: ${PROCESSED_DIR}/$(basename "${BUNDLE_FILE}")"

# Auto-promote if requested
if [[ "${AUTO_PROMOTE}" == "true" ]]; then
    log_info "Auto-promoting to stable..."
    "${SCRIPT_DIR}/promote-to-stable.sh"
fi

log_success "Import complete"
