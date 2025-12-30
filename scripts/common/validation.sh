#!/bin/bash
# validation.sh - Common validation functions for Airgapped RPM Repository System
#
# Usage: source this file to get validation functions
#
# Functions:
#   validate_path           - Validate a path exists
#   validate_file           - Validate a file exists
#   validate_directory      - Validate a directory exists
#   validate_checksum       - Validate SHA256 checksum
#   validate_gpg_signature  - Validate GPG signature
#   validate_rpm            - Validate RPM package
#   validate_repodata       - Validate repository metadata
#   validate_bom            - Validate Bill of Materials

# Prevent double-sourcing
if [[ -n "${_VALIDATION_SH_LOADED:-}" ]]; then
    return 0
fi
_VALIDATION_SH_LOADED=1

# Source logging if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${_LOGGING_SH_LOADED:-}" ]]; then
    # shellcheck source=logging.sh
    source "${SCRIPT_DIR}/logging.sh"
fi

# Validate path exists (file or directory)
# Usage: validate_path "/path/to/check" ["description"]
validate_path() {
    local path="$1"
    local desc="${2:-Path}"

    if [[ -z "${path}" ]]; then
        log_error "${desc}: path is empty"
        return 1
    fi

    if [[ ! -e "${path}" ]]; then
        log_error "${desc}: does not exist: ${path}"
        return 1
    fi

    return 0
}

# Validate file exists and is readable
# Usage: validate_file "/path/to/file" ["description"]
validate_file() {
    local file="$1"
    local desc="${2:-File}"

    if [[ -z "${file}" ]]; then
        log_error "${desc}: path is empty"
        return 1
    fi

    if [[ ! -f "${file}" ]]; then
        log_error "${desc}: not a file or does not exist: ${file}"
        return 1
    fi

    if [[ ! -r "${file}" ]]; then
        log_error "${desc}: not readable: ${file}"
        return 1
    fi

    return 0
}

# Validate directory exists and is accessible
# Usage: validate_directory "/path/to/dir" ["description"] ["writable"]
validate_directory() {
    local dir="$1"
    local desc="${2:-Directory}"
    local writable="${3:-false}"

    if [[ -z "${dir}" ]]; then
        log_error "${desc}: path is empty"
        return 1
    fi

    if [[ ! -d "${dir}" ]]; then
        log_error "${desc}: not a directory or does not exist: ${dir}"
        return 1
    fi

    if [[ "${writable}" == "true" ]] && [[ ! -w "${dir}" ]]; then
        log_error "${desc}: not writable: ${dir}"
        return 1
    fi

    return 0
}

# Validate SHA256 checksum
# Usage: validate_checksum "/path/to/file" "expected_checksum"
validate_checksum() {
    local file="$1"
    local expected="$2"

    if ! validate_file "${file}" "Checksum target"; then
        return 1
    fi

    if [[ -z "${expected}" ]]; then
        log_error "Expected checksum is empty"
        return 1
    fi

    local actual
    actual=$(sha256sum "${file}" | cut -d' ' -f1)

    if [[ "${actual}" != "${expected}" ]]; then
        log_error "Checksum mismatch for ${file}"
        log_error "  Expected: ${expected}"
        log_error "  Actual:   ${actual}"
        return 1
    fi

    log_debug "Checksum verified: ${file}"
    return 0
}

# Validate GPG signature
# Usage: validate_gpg_signature "/path/to/file" "/path/to/signature" [keyring_dir]
validate_gpg_signature() {
    local file="$1"
    local signature="$2"
    local keyring_dir="${3:-${KEYS_DIR:-/data/keys}/.gnupg}"

    if ! validate_file "${file}" "Signed file"; then
        return 1
    fi

    if ! validate_file "${signature}" "Signature file"; then
        return 1
    fi

    if ! command -v gpg &>/dev/null; then
        log_error "gpg command not found"
        return 1
    fi

    local gpg_opts=(
        --homedir "${keyring_dir}"
        --batch
        --no-tty
        --status-fd 1
    )

    local output
    if ! output=$(gpg "${gpg_opts[@]}" --verify "${signature}" "${file}" 2>&1); then
        log_error "GPG signature verification failed for ${file}"
        log_error "${output}"
        return 1
    fi

    if echo "${output}" | grep -q "GOODSIG"; then
        log_debug "GPG signature verified: ${file}"
        return 0
    else
        log_error "GPG signature not valid for ${file}"
        return 1
    fi
}

# Validate GPG detached signature (repomd.xml.asc style)
# Usage: validate_gpg_detached "/path/to/file.asc" [keyring_dir]
validate_gpg_detached() {
    local signature="$1"
    local keyring_dir="${2:-${KEYS_DIR:-/data/keys}/.gnupg}"

    # Derive the data file from signature file (remove .asc/.sig)
    local file="${signature%.asc}"
    file="${file%.sig}"

    validate_gpg_signature "${file}" "${signature}" "${keyring_dir}"
}

# Validate RPM package
# Usage: validate_rpm "/path/to/package.rpm"
validate_rpm() {
    local rpm_file="$1"

    if ! validate_file "${rpm_file}" "RPM package"; then
        return 1
    fi

    if ! command -v rpm &>/dev/null; then
        log_error "rpm command not found"
        return 1
    fi

    # Check RPM headers
    if ! rpm -K --nosignature "${rpm_file}" &>/dev/null; then
        log_error "Invalid RPM package: ${rpm_file}"
        return 1
    fi

    log_debug "RPM package validated: ${rpm_file}"
    return 0
}

# Validate repository metadata
# Usage: validate_repodata "/path/to/repodata"
validate_repodata() {
    local repodata_dir="$1"

    if ! validate_directory "${repodata_dir}" "Repodata directory"; then
        return 1
    fi

    local repomd="${repodata_dir}/repomd.xml"
    if ! validate_file "${repomd}" "repomd.xml"; then
        return 1
    fi

    # Check for required metadata files referenced in repomd.xml
    local required_types=("primary" "filelists" "other")
    for type in "${required_types[@]}"; do
        if ! grep -q "type=\"${type}\"" "${repomd}"; then
            log_warn "Missing ${type} metadata in repomd.xml"
        fi
    done

    # Verify XML is well-formed
    if command -v xmllint &>/dev/null; then
        if ! xmllint --noout "${repomd}" 2>/dev/null; then
            log_error "repomd.xml is not well-formed XML"
            return 1
        fi
    fi

    log_debug "Repodata validated: ${repodata_dir}"
    return 0
}

# Validate Bill of Materials
# Usage: validate_bom "/path/to/BILL_OF_MATERIALS.json" "/path/to/bundle_dir"
validate_bom() {
    local bom_file="$1"
    local bundle_dir="$2"

    if ! validate_file "${bom_file}" "Bill of Materials"; then
        return 1
    fi

    if ! validate_directory "${bundle_dir}" "Bundle directory"; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq command not found"
        return 1
    fi

    # Validate JSON structure
    if ! jq empty "${bom_file}" 2>/dev/null; then
        log_error "Bill of Materials is not valid JSON"
        return 1
    fi

    # Extract and verify checksums
    local failed=0
    local verified=0
    local total
    total=$(jq -r '.files | length' "${bom_file}")

    log_info "Verifying ${total} files from Bill of Materials..."

    while IFS= read -r line; do
        local file_path
        local expected_checksum
        file_path=$(echo "${line}" | jq -r '.path')
        expected_checksum=$(echo "${line}" | jq -r '.sha256')

        local full_path="${bundle_dir}/${file_path}"

        if [[ ! -f "${full_path}" ]]; then
            log_error "BOM file missing: ${file_path}"
            ((failed++))
            continue
        fi

        local actual_checksum
        actual_checksum=$(sha256sum "${full_path}" | cut -d' ' -f1)

        if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
            log_error "BOM checksum mismatch: ${file_path}"
            ((failed++))
        else
            ((verified++))
        fi
    done < <(jq -c '.files[]' "${bom_file}")

    if [[ ${failed} -gt 0 ]]; then
        log_error "BOM verification failed: ${failed} errors, ${verified} verified"
        return 1
    fi

    log_success "BOM verification passed: ${verified} files verified"
    return 0
}

# Validate manifest file structure
# Usage: validate_manifest "/path/to/manifest.json"
validate_manifest() {
    local manifest_file="$1"

    if ! validate_file "${manifest_file}" "Manifest"; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq command not found"
        return 1
    fi

    # Validate JSON structure
    if ! jq empty "${manifest_file}" 2>/dev/null; then
        log_error "Manifest is not valid JSON"
        return 1
    fi

    # Check required fields
    local required_fields=("host_id" "timestamp" "os_release" "packages")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".${field}" "${manifest_file}" &>/dev/null; then
            log_error "Manifest missing required field: ${field}"
            return 1
        fi
    done

    log_debug "Manifest validated: ${manifest_file}"
    return 0
}

# Validate version string (NEVRA format for RPM)
# Usage: validate_nevra "name-epoch:version-release.arch"
validate_nevra() {
    local nevra="$1"

    # Basic NEVRA pattern matching
    # Format: name-[epoch:]version-release.arch
    local pattern="^[a-zA-Z0-9._+-]+-([0-9]+:)?[0-9][a-zA-Z0-9._]*-[a-zA-Z0-9._]+\.(x86_64|noarch|i686|aarch64|ppc64le|s390x)$"

    if [[ ! "${nevra}" =~ ${pattern} ]]; then
        log_debug "Invalid NEVRA format: ${nevra}"
        return 1
    fi

    return 0
}

# Validate bundle version format
# Usage: validate_bundle_version "2024-01-15-001"
validate_bundle_version() {
    local version="$1"

    # Expected format: YYYY-MM-DD-NNN
    local pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$"

    if [[ ! "${version}" =~ ${pattern} ]]; then
        log_error "Invalid bundle version format: ${version}"
        log_error "Expected format: YYYY-MM-DD-NNN (e.g., 2024-01-15-001)"
        return 1
    fi

    return 0
}

# Export functions
export -f validate_path validate_file validate_directory
export -f validate_checksum validate_gpg_signature validate_gpg_detached
export -f validate_rpm validate_repodata validate_bom validate_manifest
export -f validate_nevra validate_bundle_version
