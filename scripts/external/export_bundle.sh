#!/bin/bash
# export_bundle.sh - Export signed bundle for hand-carry to internal
#
# This script creates a complete, signed bundle containing repositories,
# GPG keys, and metadata for transport to the internal publisher.
#
# Usage:
#   ./export_bundle.sh <bundle_name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/gpg_functions.sh
source "${SCRIPT_DIR}/../common/gpg_functions.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
REPOS_DIR="${DATA_DIR}/repos"
BUNDLES_DIR="${DATA_DIR}/bundles"
KEYS_DIR="${DATA_DIR}/keys"
UPDATES_DIR="${DATA_DIR}/updates"
STAGING_DIR="${DATA_DIR}/staging"

BUNDLE_NAME=""
BUNDLE_VERSION=""
INCLUDE_UPDATES=true
COMPRESS=true

usage() {
    cat << 'EOF'
Export Bundle for Hand-Carry

Creates a complete, signed bundle containing repositories, GPG keys,
and metadata for transport to the internal publisher.

Usage:
  ./export_bundle.sh <bundle_name> [options]

Arguments:
  bundle_name          Name for the bundle (e.g., "2024-01-release")

Options:
  --version VERSION    Bundle version (default: auto-generated YYYY-MM-DD-NNN)
  --no-updates         Exclude update computation results
  --no-compress        Create uncompressed bundle
  -h, --help           Show this help message

Output:
  /data/bundles/<bundle_name>.tar.gz
  /data/bundles/<bundle_name>.tar.gz.sha256
  /data/bundles/<bundle_name>.tar.gz.asc

Bundle Contents:
  repos/               - Repository packages and metadata
  keys/                - GPG public key for verification
  updates/             - Update computation results (optional)
  BILL_OF_MATERIALS.json - Checksums for all files
  bundle_manifest.json - Bundle metadata
  README.md            - Import instructions

Examples:
  # Create bundle with auto-generated version
  ./export_bundle.sh january-2024-patch

  # Create bundle with specific version
  ./export_bundle.sh security-update --version 2024-01-15-001

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                BUNDLE_VERSION="$2"
                shift 2
                ;;
            --no-updates)
                INCLUDE_UPDATES=false
                shift
                ;;
            --no-compress)
                COMPRESS=false
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "${BUNDLE_NAME}" ]]; then
                    BUNDLE_NAME="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${BUNDLE_NAME}" ]]; then
        log_error "Bundle name required"
        usage
        exit 1
    fi
}

generate_version() {
    local date_part
    date_part=$(date +%Y-%m-%d)

    # Find next sequence number
    local seq=1
    while [[ -d "${BUNDLES_DIR}/${BUNDLE_NAME}-${date_part}-$(printf '%03d' ${seq})" ]] || \
          [[ -f "${BUNDLES_DIR}/${BUNDLE_NAME}-${date_part}-$(printf '%03d' ${seq}).tar.gz" ]]; do
        ((seq++))
    done

    echo "${date_part}-$(printf '%03d' ${seq})"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ ! -d "${REPOS_DIR}" ]]; then
        log_error "Repositories directory not found: ${REPOS_DIR}"
        log_error "Run: make build-repos first"
        exit 1
    fi

    # Check for repository content
    local repo_count
    repo_count=$(find "${REPOS_DIR}" -name "repomd.xml" 2>/dev/null | wc -l)
    if [[ ${repo_count} -eq 0 ]]; then
        log_error "No repositories found"
        exit 1
    fi

    log_info "Found ${repo_count} repositories"

    log_success "Prerequisites check passed"
}

create_bundle_structure() {
    local bundle_dir="$1"

    log_info "Creating bundle structure..."

    mkdir -p "${bundle_dir}/repos"
    mkdir -p "${bundle_dir}/keys"

    if [[ "${INCLUDE_UPDATES}" == "true" ]]; then
        mkdir -p "${bundle_dir}/updates"
    fi

    # Copy repositories
    log_info "Copying repositories..."
    rsync -av --progress "${REPOS_DIR}/" "${bundle_dir}/repos/" \
        --exclude='.package_cache.json'

    # Copy GPG public key
    log_info "Copying GPG public key..."
    if [[ -f "${KEYS_DIR}/RPM-GPG-KEY-internal" ]]; then
        cp "${KEYS_DIR}/RPM-GPG-KEY-internal" "${bundle_dir}/keys/"
    else
        log_warn "GPG public key not found, skipping"
    fi

    if [[ -f "${KEYS_DIR}/RPM-GPG-KEY-internal.gpg" ]]; then
        cp "${KEYS_DIR}/RPM-GPG-KEY-internal.gpg" "${bundle_dir}/keys/"
    fi

    # Copy updates if requested
    if [[ "${INCLUDE_UPDATES}" == "true" && -d "${UPDATES_DIR}" ]]; then
        log_info "Copying update computations..."
        rsync -av "${UPDATES_DIR}/" "${bundle_dir}/updates/" 2>/dev/null || true
    fi

    log_success "Bundle structure created"
}

generate_bom() {
    local bundle_dir="$1"

    log_info "Generating Bill of Materials..."

    local bom_file="${bundle_dir}/BILL_OF_MATERIALS.json"
    local files_json="["
    local first=true
    local total_size=0
    local file_count=0

    while IFS= read -r -d '' file; do
        local rel_path="${file#${bundle_dir}/}"
        local checksum
        local size

        checksum=$(sha256sum "${file}" | cut -d' ' -f1)
        size=$(stat -c%s "${file}")

        if [[ "${first}" == "true" ]]; then
            first=false
        else
            files_json+=","
        fi

        files_json+="{\"path\":\"${rel_path}\",\"sha256\":\"${checksum}\",\"size\":${size}}"

        ((total_size += size))
        ((file_count++))
    done < <(find "${bundle_dir}" -type f ! -name "BILL_OF_MATERIALS.json" ! -name "bundle_manifest.json" -print0)

    files_json+="]"

    cat > "${bom_file}" << BOM
{
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "file_count": ${file_count},
    "total_size": ${total_size},
    "checksum_algorithm": "sha256",
    "files": ${files_json}
}
BOM

    log_success "Bill of Materials generated: ${file_count} files, $(numfmt --to=iec ${total_size})"
}

generate_manifest() {
    local bundle_dir="$1"
    local bundle_name="$2"
    local bundle_version="$3"

    log_info "Generating bundle manifest..."

    local manifest_file="${bundle_dir}/bundle_manifest.json"

    # Count repos and packages
    local repo_count
    repo_count=$(find "${bundle_dir}/repos" -name "repomd.xml" 2>/dev/null | wc -l)

    local pkg_count
    pkg_count=$(find "${bundle_dir}/repos" -name "*.rpm" 2>/dev/null | wc -l)

    # Get profiles
    local profiles
    profiles=$(find "${bundle_dir}/repos" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' ')

    cat > "${manifest_file}" << MANIFEST
{
    "bundle_name": "${bundle_name}",
    "bundle_version": "${bundle_version}",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "created_by": "$(whoami)@$(hostname)",
    "repository_count": ${repo_count},
    "package_count": ${pkg_count},
    "profiles": "$(echo ${profiles} | xargs)",
    "includes_updates": ${INCLUDE_UPDATES},
    "gpg_signed": true,
    "format_version": "1.0"
}
MANIFEST

    log_success "Bundle manifest generated"
}

generate_readme() {
    local bundle_dir="$1"
    local bundle_name="$2"
    local bundle_version="$3"

    cat > "${bundle_dir}/README.md" << 'README'
# RPM Repository Bundle

This bundle contains RPM repositories for import into the internal publisher.

## Contents

- `repos/` - Repository packages and metadata
- `keys/` - GPG public key for signature verification
- `updates/` - Update computation results (if included)
- `BILL_OF_MATERIALS.json` - Checksums for all files
- `bundle_manifest.json` - Bundle metadata

## Import Instructions

### 1. Verify Bundle Integrity

Before importing, verify the bundle signature and checksums:

```bash
# Verify GPG signature (if available)
gpg --verify bundle.tar.gz.asc bundle.tar.gz

# Verify checksums after extraction
cd /path/to/extracted/bundle
python3 -c "
import json, hashlib
with open('BILL_OF_MATERIALS.json') as f:
    bom = json.load(f)
for file_info in bom['files']:
    with open(file_info['path'], 'rb') as f:
        actual = hashlib.sha256(f.read()).hexdigest()
    if actual != file_info['sha256']:
        print(f'FAIL: {file_info[\"path\"]}')
    else:
        print(f'OK: {file_info[\"path\"]}')
"
```

### 2. Import Bundle

On the internal publisher:

```bash
# Copy bundle to internal publisher
scp bundle.tar.gz internal-publisher:/data/bundles/incoming/

# Import bundle
make import BUNDLE_PATH=/data/bundles/incoming/bundle.tar.gz

# Verify bundle
make verify

# Publish to dev channel
make publish LIFECYCLE=dev
```

### 3. Configure Clients

After publishing, generate client configuration:

```bash
make generate-client-config
```

Distribute the generated repo files and GPG key to internal hosts.

## Verification

The bundle includes GPG signatures for all repository metadata (repomd.xml.asc).
Import the GPG public key on client systems:

```bash
rpm --import /path/to/keys/RPM-GPG-KEY-internal
```

## Support

For issues with this bundle, contact your repository administrator.
README

    log_success "README generated"
}

create_archive() {
    local bundle_dir="$1"
    local bundle_name="$2"
    local output_file="${BUNDLES_DIR}/${bundle_name}"

    log_info "Creating bundle archive..."

    local archive_file
    if [[ "${COMPRESS}" == "true" ]]; then
        archive_file="${output_file}.tar.gz"
        tar -czf "${archive_file}" -C "$(dirname "${bundle_dir}")" "$(basename "${bundle_dir}")"
    else
        archive_file="${output_file}.tar"
        tar -cf "${archive_file}" -C "$(dirname "${bundle_dir}")" "$(basename "${bundle_dir}")"
    fi

    log_success "Archive created: ${archive_file}"

    # Generate checksum
    log_info "Generating archive checksum..."
    sha256sum "${archive_file}" > "${archive_file}.sha256"
    log_success "Checksum: ${archive_file}.sha256"

    # Sign archive
    log_info "Signing archive..."
    if gpg_sign_file "${archive_file}" 2>/dev/null; then
        log_success "Signature: ${archive_file}.asc"
    else
        log_warn "Could not sign archive (no GPG key available)"
    fi

    # Report size
    local archive_size
    archive_size=$(du -h "${archive_file}" | cut -f1)
    log_info "Archive size: ${archive_size}"

    echo "${archive_file}"
}

cleanup_staging() {
    local bundle_dir="$1"

    log_info "Cleaning up staging area..."
    rm -rf "${bundle_dir}"
}

main() {
    parse_args "$@"

    log_section "Export Bundle"

    check_prerequisites

    # Generate version if not specified
    if [[ -z "${BUNDLE_VERSION}" ]]; then
        BUNDLE_VERSION=$(generate_version)
    fi

    local full_bundle_name="${BUNDLE_NAME}-${BUNDLE_VERSION}"
    log_info "Bundle: ${full_bundle_name}"

    # Create staging directory
    mkdir -p "${BUNDLES_DIR}"
    local bundle_dir="${STAGING_DIR}/${full_bundle_name}"
    rm -rf "${bundle_dir}"
    mkdir -p "${bundle_dir}"

    # Build bundle
    create_bundle_structure "${bundle_dir}"
    generate_bom "${bundle_dir}"
    generate_manifest "${bundle_dir}" "${BUNDLE_NAME}" "${BUNDLE_VERSION}"
    generate_readme "${bundle_dir}" "${BUNDLE_NAME}" "${BUNDLE_VERSION}"

    # Create archive
    local archive_path
    archive_path=$(create_archive "${bundle_dir}" "${full_bundle_name}")

    # Cleanup
    cleanup_staging "${bundle_dir}"

    log_section "Bundle Export Complete"
    log_info "Bundle: ${full_bundle_name}"
    log_info "Archive: ${archive_path}"
    log_info "Checksum: ${archive_path}.sha256"

    if [[ -f "${archive_path}.asc" ]]; then
        log_info "Signature: ${archive_path}.asc"
    fi

    echo ""
    log_info "Next steps:"
    log_info "  1. Transfer bundle to hand-carry media"
    log_info "  2. On internal publisher: make import BUNDLE_PATH=/path/to/bundle.tar.gz"

    log_audit "BUNDLE_EXPORTED" "Bundle ${full_bundle_name} exported to ${archive_path}"
}

main "$@"
