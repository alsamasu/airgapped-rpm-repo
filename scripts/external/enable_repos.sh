#!/bin/bash
# enable_repos.sh - Enable required RHEL repositories for mirroring
#
# This script enables the RHEL repositories needed for both RHEL 8 and RHEL 9
# using subscription-manager.
#
# Usage:
#   ./enable_repos.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
CONFIG_FILE="${DATA_DIR}/external.conf"

# Default repositories
RHEL8_REPOS=(
    "rhel-8-for-x86_64-baseos-rpms"
    "rhel-8-for-x86_64-appstream-rpms"
)

RHEL9_REPOS=(
    "rhel-9-for-x86_64-baseos-rpms"
    "rhel-9-for-x86_64-appstream-rpms"
)

# Additional optional repos (disabled by default)
RHEL8_OPTIONAL_REPOS=(
    "codeready-builder-for-rhel-8-x86_64-rpms"
)

RHEL9_OPTIONAL_REPOS=(
    "codeready-builder-for-rhel-9-x86_64-rpms"
)

INCLUDE_OPTIONAL=false
RHEL8_ONLY=false
RHEL9_ONLY=false

usage() {
    cat << 'EOF'
Enable RHEL Repositories for Mirroring

This script enables the required RHEL repositories using subscription-manager.
The system must be registered before running this script.

Usage:
  ./enable_repos.sh [options]

Options:
  --rhel8-only          Only enable RHEL 8 repositories
  --rhel9-only          Only enable RHEL 9 repositories
  --include-optional    Include optional repositories (CodeReady Builder)
  --list                List available repositories
  --status              Show currently enabled repositories
  -h, --help            Show this help message

Default Repositories:
  RHEL 8:
    - rhel-8-for-x86_64-baseos-rpms
    - rhel-8-for-x86_64-appstream-rpms

  RHEL 9:
    - rhel-9-for-x86_64-baseos-rpms
    - rhel-9-for-x86_64-appstream-rpms

Optional Repositories (with --include-optional):
  RHEL 8:
    - codeready-builder-for-rhel-8-x86_64-rpms

  RHEL 9:
    - codeready-builder-for-rhel-9-x86_64-rpms

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rhel8-only)
                RHEL8_ONLY=true
                shift
                ;;
            --rhel9-only)
                RHEL9_ONLY=true
                shift
                ;;
            --include-optional)
                INCLUDE_OPTIONAL=true
                shift
                ;;
            --list)
                list_available_repos
                exit 0
                ;;
            --status)
                show_status
                exit 0
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

    if [[ "${RHEL8_ONLY}" == "true" && "${RHEL9_ONLY}" == "true" ]]; then
        log_error "Cannot specify both --rhel8-only and --rhel9-only"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v subscription-manager &>/dev/null; then
        log_error "subscription-manager not found"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check if registered
    if ! subscription-manager status &>/dev/null; then
        log_error "System is not registered with subscription-manager"
        log_error "Run: make sm-register first"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

list_available_repos() {
    log_info "Listing available repositories..."
    subscription-manager repos --list | grep -E "^Repo ID:|^Repo Name:" | \
        sed 'N;s/\n/ /' | column -t
}

show_status() {
    log_info "Currently enabled repositories:"
    subscription-manager repos --list-enabled
}

enable_repo() {
    local repo_id="$1"

    log_info "Enabling repository: ${repo_id}"

    if subscription-manager repos --enable="${repo_id}" 2>/dev/null; then
        log_success "Enabled: ${repo_id}"
        return 0
    else
        log_warn "Failed to enable: ${repo_id} (may not be available)"
        return 1
    fi
}

disable_all_repos() {
    log_info "Disabling all repositories first..."
    subscription-manager repos --disable="*" || true
}

enable_repos() {
    local repos_to_enable=()

    # Build list of repos to enable
    if [[ "${RHEL9_ONLY}" != "true" ]]; then
        repos_to_enable+=("${RHEL8_REPOS[@]}")
        if [[ "${INCLUDE_OPTIONAL}" == "true" ]]; then
            repos_to_enable+=("${RHEL8_OPTIONAL_REPOS[@]}")
        fi
    fi

    if [[ "${RHEL8_ONLY}" != "true" ]]; then
        repos_to_enable+=("${RHEL9_REPOS[@]}")
        if [[ "${INCLUDE_OPTIONAL}" == "true" ]]; then
            repos_to_enable+=("${RHEL9_OPTIONAL_REPOS[@]}")
        fi
    fi

    log_info "Enabling ${#repos_to_enable[@]} repositories..."

    local enabled=0
    local failed=0

    for repo in "${repos_to_enable[@]}"; do
        if enable_repo "${repo}"; then
            ((enabled++))
        else
            ((failed++))
        fi
    done

    log_info "Enabled: ${enabled}, Failed: ${failed}"

    if [[ ${enabled} -eq 0 ]]; then
        log_error "No repositories were enabled"
        return 1
    fi

    return 0
}

save_config() {
    log_info "Saving configuration..."

    if [[ ! -d "${DATA_DIR}" ]]; then
        mkdir -p "${DATA_DIR}"
    fi

    # Get list of enabled repos
    local enabled_repos
    enabled_repos=$(subscription-manager repos --list-enabled 2>/dev/null | \
                   grep "Repo ID:" | awk '{print $3}' | tr '\n' ' ')

    # Update config file
    if [[ -f "${CONFIG_FILE}" ]]; then
        # Update existing config
        sed -i "s/^ENABLED_REPOS=.*/ENABLED_REPOS=\"${enabled_repos}\"/" "${CONFIG_FILE}" || \
            echo "ENABLED_REPOS=\"${enabled_repos}\"" >> "${CONFIG_FILE}"
    else
        echo "ENABLED_REPOS=\"${enabled_repos}\"" > "${CONFIG_FILE}"
    fi

    log_success "Configuration saved to ${CONFIG_FILE}"
}

main() {
    parse_args "$@"

    log_section "Enable RHEL Repositories"

    check_prerequisites

    # Disable all repos first for clean state
    disable_all_repos

    # Enable required repos
    enable_repos

    # Save configuration
    save_config

    # Show final status
    echo ""
    show_status

    log_audit "REPOS_ENABLED" "RHEL repositories enabled for mirroring"

    log_success "Repository enablement complete"
    log_info "Next step: make sync"
}

main "$@"
