#!/bin/bash
# sync_repos.sh - Sync RHEL content from Red Hat CDN
#
# This script uses dnf reposync to mirror content from Red Hat CDN.
#
# Usage:
#   ./sync_repos.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
MIRROR_DIR="${DATA_DIR}/mirror"
CONFIG_FILE="${DATA_DIR}/external.conf"
LOG_DIR="${RPMSERVER_LOG_DIR:-/var/log/rpmserver}"

# Sync options
NEWEST_ONLY=true
DELETE_REMOVED=false
DOWNLOAD_METADATA=true
ARCH="x86_64"
PARALLEL_DOWNLOADS=10

# Repository mapping
declare -A REPO_PROFILE_MAP=(
    ["rhel-8-for-x86_64-baseos-rpms"]="rhel8"
    ["rhel-8-for-x86_64-appstream-rpms"]="rhel8"
    ["codeready-builder-for-rhel-8-x86_64-rpms"]="rhel8"
    ["rhel-9-for-x86_64-baseos-rpms"]="rhel9"
    ["rhel-9-for-x86_64-appstream-rpms"]="rhel9"
    ["codeready-builder-for-rhel-9-x86_64-rpms"]="rhel9"
)

declare -A REPO_CHANNEL_MAP=(
    ["rhel-8-for-x86_64-baseos-rpms"]="baseos"
    ["rhel-8-for-x86_64-appstream-rpms"]="appstream"
    ["codeready-builder-for-rhel-8-x86_64-rpms"]="codeready"
    ["rhel-9-for-x86_64-baseos-rpms"]="baseos"
    ["rhel-9-for-x86_64-appstream-rpms"]="appstream"
    ["codeready-builder-for-rhel-9-x86_64-rpms"]="codeready"
)

SPECIFIC_REPOS=""
DRY_RUN=false

usage() {
    cat << 'EOF'
Sync RHEL Content from Red Hat CDN

Uses dnf reposync to mirror content from Red Hat CDN to local storage.
The system must be registered and repositories enabled before syncing.

Usage:
  ./sync_repos.sh [options]

Options:
  --repo REPO_ID        Sync specific repository only (can be repeated)
  --all-versions        Sync all package versions (not just newest)
  --delete              Delete packages no longer in upstream
  --arch ARCH           Architecture to sync (default: x86_64)
  --parallel N          Parallel downloads (default: 10)
  --dry-run             Show what would be synced without syncing
  -h, --help            Show this help message

Directory Structure:
  /data/mirror/<profile>/<arch>/<channel>/
  Example: /data/mirror/rhel9/x86_64/baseos/

Examples:
  # Sync all enabled repositories
  ./sync_repos.sh

  # Sync specific repository
  ./sync_repos.sh --repo rhel-9-for-x86_64-baseos-rpms

  # Sync with all versions
  ./sync_repos.sh --all-versions

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                if [[ -n "${SPECIFIC_REPOS}" ]]; then
                    SPECIFIC_REPOS="${SPECIFIC_REPOS} $2"
                else
                    SPECIFIC_REPOS="$2"
                fi
                shift 2
                ;;
            --all-versions)
                NEWEST_ONLY=false
                shift
                ;;
            --delete)
                DELETE_REMOVED=true
                shift
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL_DOWNLOADS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
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

    if ! command -v dnf &>/dev/null; then
        log_error "dnf not found"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check if registered
    if ! subscription-manager status &>/dev/null; then
        log_error "System is not registered with subscription-manager"
        exit 1
    fi

    # Check disk space
    local available_gb
    available_gb=$(df -BG "${MIRROR_DIR}" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ "${available_gb}" -lt 50 ]]; then
        log_warn "Low disk space: ${available_gb}GB available (recommend 50GB+)"
    fi

    log_success "Prerequisites check passed"
}

get_enabled_repos() {
    if [[ -n "${SPECIFIC_REPOS}" ]]; then
        echo "${SPECIFIC_REPOS}"
        return
    fi

    # Get enabled repos from subscription-manager
    subscription-manager repos --list-enabled 2>/dev/null | \
        grep "Repo ID:" | awk '{print $3}'
}

get_repo_path() {
    local repo_id="$1"

    local profile="${REPO_PROFILE_MAP[${repo_id}]:-unknown}"
    local channel="${REPO_CHANNEL_MAP[${repo_id}]:-${repo_id}}"

    echo "${MIRROR_DIR}/${profile}/${ARCH}/${channel}"
}

sync_repo() {
    local repo_id="$1"
    local dest_path
    dest_path=$(get_repo_path "${repo_id}")

    log_info "Syncing repository: ${repo_id}"
    log_info "Destination: ${dest_path}"

    # Create destination directory
    mkdir -p "${dest_path}"

    # Build reposync command
    local cmd=(
        dnf reposync
        --repoid="${repo_id}"
        --download-path="${dest_path}"
        --arch="${ARCH}"
        --arch="noarch"
        --downloadcomps
        --download-metadata
        --norepopath
    )

    if [[ "${NEWEST_ONLY}" == "true" ]]; then
        cmd+=(--newest-only)
    fi

    if [[ "${DELETE_REMOVED}" == "true" ]]; then
        cmd+=(--delete)
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN: ${cmd[*]}"
        return 0
    fi

    # Create log file
    local sync_log="${LOG_DIR}/sync-${repo_id}-$(date +%Y%m%d-%H%M%S).log"

    log_info "Sync log: ${sync_log}"

    # Execute reposync
    local start_time
    start_time=$(date +%s)

    if "${cmd[@]}" 2>&1 | tee "${sync_log}"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Sync complete: ${repo_id} (${duration}s)"

        # Count packages
        local pkg_count
        pkg_count=$(find "${dest_path}" -name "*.rpm" 2>/dev/null | wc -l)
        log_info "Packages synced: ${pkg_count}"

        # Record sync metadata
        cat > "${dest_path}/.sync_metadata" << METADATA
{
    "repo_id": "${repo_id}",
    "sync_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "duration_seconds": ${duration},
    "package_count": ${pkg_count},
    "newest_only": ${NEWEST_ONLY},
    "arch": "${ARCH}"
}
METADATA

        return 0
    else
        log_error "Sync failed: ${repo_id}"
        return 1
    fi
}

create_repo_metadata() {
    local repo_path="$1"
    local repo_id="$2"

    log_info "Creating repository metadata for ${repo_id}..."

    if ! command -v createrepo_c &>/dev/null; then
        log_error "createrepo_c not found"
        return 1
    fi

    # Check for comps.xml
    local comps_arg=""
    if [[ -f "${repo_path}/comps.xml" ]]; then
        comps_arg="--groupfile=${repo_path}/comps.xml"
    fi

    local cmd=(
        createrepo_c
        --update
        --workers=4
        --checksum=sha256
    )

    if [[ -n "${comps_arg}" ]]; then
        cmd+=("${comps_arg}")
    fi

    cmd+=("${repo_path}")

    if "${cmd[@]}"; then
        log_success "Repository metadata created: ${repo_path}"
        return 0
    else
        log_error "Failed to create repository metadata: ${repo_path}"
        return 1
    fi
}

main() {
    parse_args "$@"

    log_section "RHEL Repository Sync"

    check_prerequisites

    # Ensure mirror directory exists
    mkdir -p "${MIRROR_DIR}"
    mkdir -p "${LOG_DIR}"

    # Get list of repos to sync
    local repos
    repos=$(get_enabled_repos)

    if [[ -z "${repos}" ]]; then
        log_error "No repositories to sync"
        log_error "Run: make enable-repos first"
        exit 1
    fi

    log_info "Repositories to sync:"
    echo "${repos}" | while read -r repo; do
        echo "  - ${repo}"
    done
    echo ""

    # Sync each repository
    local total=0
    local success=0
    local failed=0

    for repo_id in ${repos}; do
        ((total++))
        if sync_repo "${repo_id}"; then
            ((success++))

            # Create repo metadata after sync
            local repo_path
            repo_path=$(get_repo_path "${repo_id}")
            create_repo_metadata "${repo_path}" "${repo_id}"
        else
            ((failed++))
        fi
    done

    # Summary
    echo ""
    log_section "Sync Summary"
    log_info "Total: ${total}"
    log_info "Success: ${success}"
    log_info "Failed: ${failed}"

    # Calculate total size
    local total_size
    total_size=$(du -sh "${MIRROR_DIR}" 2>/dev/null | cut -f1)
    log_info "Total mirror size: ${total_size}"

    # Record overall sync metadata
    cat > "${MIRROR_DIR}/.last_sync" << METADATA
{
    "sync_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "total_repos": ${total},
    "success": ${success},
    "failed": ${failed},
    "total_size": "${total_size}"
}
METADATA

    log_audit "REPO_SYNC" "Synced ${success}/${total} repositories, size: ${total_size}"

    if [[ ${failed} -gt 0 ]]; then
        log_warn "Some repositories failed to sync"
        exit 1
    fi

    log_success "Repository sync complete"
    log_info "Next step: make ingest (to process host manifests)"
}

main "$@"
