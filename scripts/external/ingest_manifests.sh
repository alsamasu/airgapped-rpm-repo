#!/bin/bash
# ingest_manifests.sh - Ingest host manifests from hand-carry media
#
# This script processes host manifests collected from internal hosts,
# validates them, and indexes them for update computation.
#
# Usage:
#   ./ingest_manifests.sh /path/to/manifest/directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/validation.sh
source "${SCRIPT_DIR}/../common/validation.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
MANIFESTS_DIR="${DATA_DIR}/manifests"
INCOMING_DIR="${MANIFESTS_DIR}/incoming"
PROCESSED_DIR="${MANIFESTS_DIR}/processed"
INDEX_FILE="${MANIFESTS_DIR}/index/manifest_index.json"

usage() {
    cat << 'EOF'
Ingest Host Manifests

Processes host manifests from hand-carry media, validates them,
and indexes them for update computation.

Usage:
  ./ingest_manifests.sh /path/to/manifest/directory
  ./ingest_manifests.sh /path/to/manifest.tar.gz
  ./ingest_manifests.sh --scan-incoming

Options:
  --scan-incoming    Scan and process all manifests in incoming directory
  --verify-only      Verify manifests without importing
  -h, --help         Show this help message

Directory Structure:
  /data/manifests/incoming/     - Drop zone for new manifests
  /data/manifests/processed/    - Processed and indexed manifests
  /data/manifests/index/        - Manifest index for lookup

Examples:
  # Import from USB drive
  ./ingest_manifests.sh /media/usb/manifest-host1-20240115-120000

  # Import tarball
  ./ingest_manifests.sh /media/usb/manifest-host1-20240115-120000.tar.gz

  # Process all in incoming directory
  ./ingest_manifests.sh --scan-incoming

EOF
}

MANIFEST_PATH=""
SCAN_INCOMING=false
VERIFY_ONLY=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scan-incoming)
                SCAN_INCOMING=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
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
                MANIFEST_PATH="$1"
                shift
                ;;
        esac
    done

    if [[ "${SCAN_INCOMING}" == "false" && -z "${MANIFEST_PATH}" ]]; then
        log_error "No manifest path specified"
        usage
        exit 1
    fi
}

ensure_directories() {
    mkdir -p "${INCOMING_DIR}"
    mkdir -p "${PROCESSED_DIR}"
    mkdir -p "${MANIFESTS_DIR}/index"

    # Initialize index if not exists
    if [[ ! -f "${INDEX_FILE}" ]]; then
        echo '{"hosts": {}, "last_updated": null}' > "${INDEX_FILE}"
    fi
}

extract_tarball() {
    local tarball="$1"
    local extract_dir="${INCOMING_DIR}/$(basename "${tarball}" .tar.gz)"

    log_info "Extracting tarball: ${tarball}"

    mkdir -p "${extract_dir}"

    if tar -xzf "${tarball}" -C "${INCOMING_DIR}"; then
        log_success "Extracted to: ${extract_dir}"
        echo "${extract_dir}"
    else
        log_error "Failed to extract tarball"
        return 1
    fi
}

verify_manifest_checksums() {
    local manifest_dir="$1"
    local checksum_file="${manifest_dir}/SHA256SUMS"

    if [[ ! -f "${checksum_file}" ]]; then
        log_warn "No SHA256SUMS file found in ${manifest_dir}"
        return 1
    fi

    log_info "Verifying checksums..."

    if (cd "${manifest_dir}" && sha256sum -c SHA256SUMS --quiet 2>/dev/null); then
        log_success "All checksums verified"
        return 0
    else
        log_error "Checksum verification failed"
        return 1
    fi
}

validate_manifest_structure() {
    local manifest_dir="$1"

    log_info "Validating manifest structure..."

    # Check required files
    local required_files=(
        "manifest.json"
        "packages.txt"
        "os-release.txt"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "${manifest_dir}/${file}" ]]; then
            log_error "Missing required file: ${file}"
            return 1
        fi
    done

    # Validate JSON structure
    if ! validate_manifest "${manifest_dir}/manifest.json"; then
        return 1
    fi

    log_success "Manifest structure valid"
    return 0
}

process_manifest() {
    local manifest_dir="$1"

    log_info "Processing manifest: ${manifest_dir}"

    # Read manifest JSON
    local manifest_file="${manifest_dir}/manifest.json"
    local host_id
    local timestamp
    local os_id
    local os_version

    host_id=$(jq -r '.host_id' "${manifest_file}")
    timestamp=$(jq -r '.timestamp' "${manifest_file}")
    os_id=$(jq -r '.os_release.id' "${manifest_file}")
    os_version=$(jq -r '.os_release.version' "${manifest_file}")

    log_info "Host ID: ${host_id}"
    log_info "Timestamp: ${timestamp}"
    log_info "OS: ${os_id} ${os_version}"

    # Create processed directory for this host
    local host_dir="${PROCESSED_DIR}/${host_id}"
    local versioned_dir="${host_dir}/${timestamp//[:-]/}"

    mkdir -p "${versioned_dir}"

    # Copy manifest files
    cp -r "${manifest_dir}"/* "${versioned_dir}/"

    # Create latest symlink
    ln -sfn "${versioned_dir}" "${host_dir}/latest"

    log_success "Manifest processed: ${versioned_dir}"

    # Update index
    update_index "${host_id}" "${timestamp}" "${os_id}" "${os_version}" "${versioned_dir}"

    return 0
}

update_index() {
    local host_id="$1"
    local timestamp="$2"
    local os_id="$3"
    local os_version="$4"
    local manifest_path="$5"

    log_info "Updating manifest index..."

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read current index
    local current_index
    current_index=$(cat "${INDEX_FILE}")

    # Check if host exists
    local host_entry
    host_entry=$(echo "${current_index}" | jq -r ".hosts[\"${host_id}\"] // null")

    if [[ "${host_entry}" == "null" ]]; then
        # New host
        current_index=$(echo "${current_index}" | jq \
            --arg host_id "${host_id}" \
            --arg timestamp "${timestamp}" \
            --arg os_id "${os_id}" \
            --arg os_version "${os_version}" \
            --arg path "${manifest_path}" \
            --arg now "${now}" \
            '.hosts[$host_id] = {
                "first_seen": $now,
                "last_updated": $now,
                "os_id": $os_id,
                "os_version": $os_version,
                "latest_manifest": $timestamp,
                "manifest_path": $path,
                "manifest_count": 1
            } | .last_updated = $now')
    else
        # Existing host - update
        local manifest_count
        manifest_count=$(echo "${current_index}" | jq -r ".hosts[\"${host_id}\"].manifest_count // 0")
        ((manifest_count++))

        current_index=$(echo "${current_index}" | jq \
            --arg host_id "${host_id}" \
            --arg timestamp "${timestamp}" \
            --arg os_id "${os_id}" \
            --arg os_version "${os_version}" \
            --arg path "${manifest_path}" \
            --arg now "${now}" \
            --argjson count "${manifest_count}" \
            '.hosts[$host_id].last_updated = $now |
             .hosts[$host_id].os_id = $os_id |
             .hosts[$host_id].os_version = $os_version |
             .hosts[$host_id].latest_manifest = $timestamp |
             .hosts[$host_id].manifest_path = $path |
             .hosts[$host_id].manifest_count = $count |
             .last_updated = $now')
    fi

    # Write updated index
    echo "${current_index}" > "${INDEX_FILE}"

    log_success "Index updated"
}

process_single_manifest() {
    local path="$1"
    local manifest_dir=""

    # Handle tarball
    if [[ "${path}" == *.tar.gz ]]; then
        manifest_dir=$(extract_tarball "${path}")
    elif [[ -d "${path}" ]]; then
        manifest_dir="${path}"
    else
        log_error "Invalid manifest path: ${path}"
        return 1
    fi

    # Verify checksums
    if ! verify_manifest_checksums "${manifest_dir}"; then
        log_warn "Checksum verification failed, continuing with validation..."
    fi

    # Validate structure
    if ! validate_manifest_structure "${manifest_dir}"; then
        log_error "Invalid manifest structure"
        return 1
    fi

    # Process if not verify-only
    if [[ "${VERIFY_ONLY}" == "false" ]]; then
        process_manifest "${manifest_dir}"
    else
        log_info "Verification complete (--verify-only mode)"
    fi

    return 0
}

scan_incoming() {
    log_info "Scanning incoming directory: ${INCOMING_DIR}"

    local count=0
    local success=0
    local failed=0

    # Process directories
    for manifest_dir in "${INCOMING_DIR}"/*/; do
        [[ ! -d "${manifest_dir}" ]] && continue
        [[ ! -f "${manifest_dir}/manifest.json" ]] && continue

        ((count++))
        if process_single_manifest "${manifest_dir}"; then
            ((success++))
            # Move processed directory
            if [[ "${VERIFY_ONLY}" == "false" ]]; then
                rm -rf "${manifest_dir}"
            fi
        else
            ((failed++))
        fi
    done

    # Process tarballs
    for tarball in "${INCOMING_DIR}"/*.tar.gz; do
        [[ ! -f "${tarball}" ]] && continue

        ((count++))
        if process_single_manifest "${tarball}"; then
            ((success++))
            # Remove processed tarball
            if [[ "${VERIFY_ONLY}" == "false" ]]; then
                rm -f "${tarball}"
            fi
        else
            ((failed++))
        fi
    done

    log_info "Processed: ${count}, Success: ${success}, Failed: ${failed}"

    if [[ ${count} -eq 0 ]]; then
        log_info "No manifests found in incoming directory"
    fi

    return 0
}

show_index_summary() {
    log_section "Manifest Index Summary"

    local host_count
    host_count=$(jq -r '.hosts | length' "${INDEX_FILE}")
    log_info "Total hosts: ${host_count}"

    if [[ ${host_count} -gt 0 ]]; then
        echo ""
        echo "Hosts:"
        jq -r '.hosts | to_entries[] | "  \(.key): \(.value.os_id) \(.value.os_version) (last: \(.value.latest_manifest))"' "${INDEX_FILE}"
    fi
}

main() {
    parse_args "$@"

    log_section "Manifest Ingestion"

    ensure_directories

    if [[ "${SCAN_INCOMING}" == "true" ]]; then
        scan_incoming
    else
        process_single_manifest "${MANIFEST_PATH}"
    fi

    show_index_summary

    log_audit "MANIFEST_INGEST" "Ingested manifests from ${MANIFEST_PATH:-incoming}"

    log_success "Manifest ingestion complete"
    log_info "Next step: make compute"
}

main "$@"
