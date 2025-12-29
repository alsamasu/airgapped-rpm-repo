#!/bin/bash
# build_repos.sh - Build repository structure for internal publisher
#
# This script creates the structured repository layout for the internal
# publisher, including signed metadata.
#
# Usage:
#   ./build_repos.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"
# shellcheck source=../common/gpg_functions.sh
source "${SCRIPT_DIR}/../common/gpg_functions.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
MIRROR_DIR="${DATA_DIR}/mirror"
REPOS_DIR="${DATA_DIR}/repos"
STAGING_DIR="${DATA_DIR}/staging"
KEYS_DIR="${DATA_DIR}/keys"

# Build options
SIGN_REPOS=true
PROFILES="rhel8 rhel9"
CHANNELS="baseos appstream"
ARCH="x86_64"

usage() {
    cat << 'EOF'
Build Repository Structure

Creates the structured repository layout for the internal publisher
with signed repodata.

Usage:
  ./build_repos.sh [options]

Options:
  --no-sign            Skip GPG signing of repository metadata
  --profiles PROFILES  Profiles to build (default: "rhel8 rhel9")
  --channels CHANNELS  Channels to build (default: "baseos appstream")
  -h, --help           Show this help message

Directory Structure:
  /data/repos/<profile>/<arch>/<channel>/
  Example: /data/repos/rhel9/x86_64/baseos/

Examples:
  # Build all repositories
  ./build_repos.sh

  # Build without signing
  ./build_repos.sh --no-sign

  # Build only RHEL 9
  ./build_repos.sh --profiles rhel9

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-sign)
                SIGN_REPOS=false
                shift
                ;;
            --profiles)
                PROFILES="$2"
                shift 2
                ;;
            --channels)
                CHANNELS="$2"
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

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v createrepo_c &>/dev/null; then
        log_error "createrepo_c not found"
        exit 1
    fi

    if [[ "${SIGN_REPOS}" == "true" ]]; then
        if ! command -v gpg &>/dev/null; then
            log_error "gpg not found (required for signing)"
            exit 1
        fi

        # Check for signing key
        local key_id
        key_id=$(gpg_get_key_id 2>/dev/null || true)
        if [[ -z "${key_id}" ]]; then
            log_warn "No GPG signing key found"
            log_info "Run: make gpg-init to generate a signing key"
            log_info "Continuing without signing..."
            SIGN_REPOS=false
        else
            log_info "Using GPG key: ${key_id}"
        fi
    fi

    if [[ ! -d "${MIRROR_DIR}" ]]; then
        log_error "Mirror directory not found: ${MIRROR_DIR}"
        log_error "Run: make sync first"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

build_repo() {
    local profile="$1"
    local arch="$2"
    local channel="$3"

    local source_dir="${MIRROR_DIR}/${profile}/${arch}/${channel}"
    local dest_dir="${REPOS_DIR}/${profile}/${arch}/${channel}"

    log_info "Building repository: ${profile}/${arch}/${channel}"

    if [[ ! -d "${source_dir}" ]]; then
        log_warn "Source directory not found: ${source_dir}"
        return 1
    fi

    # Count packages
    local pkg_count
    pkg_count=$(find "${source_dir}" -name "*.rpm" 2>/dev/null | wc -l)

    if [[ ${pkg_count} -eq 0 ]]; then
        log_warn "No packages found in ${source_dir}"
        return 1
    fi

    log_info "Found ${pkg_count} packages"

    # Create destination directory
    mkdir -p "${dest_dir}"

    # Sync packages (hard link to save space)
    log_info "Syncing packages..."
    rsync -av --link-dest="${source_dir}" "${source_dir}/" "${dest_dir}/" --exclude='repodata' --exclude='.sync_metadata' --exclude='.package_cache.json'

    # Copy comps.xml if exists
    if [[ -f "${source_dir}/comps.xml" ]]; then
        cp "${source_dir}/comps.xml" "${dest_dir}/"
    fi

    # Create repository metadata
    log_info "Creating repository metadata..."

    local createrepo_args=(
        --update
        --workers=4
        --checksum=sha256
        --simple-md-filenames
    )

    if [[ -f "${dest_dir}/comps.xml" ]]; then
        createrepo_args+=(--groupfile="${dest_dir}/comps.xml")
    fi

    createrepo_args+=("${dest_dir}")

    if ! createrepo_c "${createrepo_args[@]}"; then
        log_error "Failed to create repository metadata"
        return 1
    fi

    # Sign repository metadata
    if [[ "${SIGN_REPOS}" == "true" ]]; then
        log_info "Signing repository metadata..."
        gpg_sign_repomd "${dest_dir}/repodata"
    fi

    # Create repo metadata file
    cat > "${dest_dir}/.repo_metadata" << METADATA
{
    "profile": "${profile}",
    "arch": "${arch}",
    "channel": "${channel}",
    "package_count": ${pkg_count},
    "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "signed": ${SIGN_REPOS}
}
METADATA

    log_success "Repository built: ${dest_dir}"
    return 0
}

generate_repo_index() {
    log_info "Generating repository index..."

    local index_file="${REPOS_DIR}/repos.json"
    local repos_json="[]"

    for profile in ${PROFILES}; do
        for channel in ${CHANNELS}; do
            local repo_dir="${REPOS_DIR}/${profile}/${ARCH}/${channel}"
            local metadata_file="${repo_dir}/.repo_metadata"

            if [[ -f "${metadata_file}" ]]; then
                local repo_meta
                repo_meta=$(cat "${metadata_file}")
                repos_json=$(echo "${repos_json}" | jq ". + [${repo_meta}]")
            fi
        done
    done

    cat > "${index_file}" << INDEX
{
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "signed": ${SIGN_REPOS},
    "repositories": ${repos_json}
}
INDEX

    log_success "Repository index generated: ${index_file}"
}

main() {
    parse_args "$@"

    log_section "Build Repository Structure"

    check_prerequisites

    mkdir -p "${REPOS_DIR}"
    mkdir -p "${STAGING_DIR}"

    local total=0
    local success=0
    local failed=0

    for profile in ${PROFILES}; do
        for channel in ${CHANNELS}; do
            ((total++))
            if build_repo "${profile}" "${ARCH}" "${channel}"; then
                ((success++))
            else
                ((failed++))
            fi
        done
    done

    # Generate repository index
    generate_repo_index

    # Calculate total size
    local total_size
    total_size=$(du -sh "${REPOS_DIR}" 2>/dev/null | cut -f1)

    log_section "Build Summary"
    log_info "Total: ${total}"
    log_info "Success: ${success}"
    log_info "Failed: ${failed}"
    log_info "Total size: ${total_size}"
    log_info "Signed: ${SIGN_REPOS}"

    log_audit "REPOS_BUILT" "Built ${success}/${total} repositories, size: ${total_size}"

    log_success "Repository build complete"
    log_info "Next step: make export BUNDLE_NAME=<name>"
}

main "$@"
