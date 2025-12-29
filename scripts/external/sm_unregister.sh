#!/bin/bash
# sm_unregister.sh - Unregister from Red Hat subscription-manager
#
# Usage:
#   ./sm_unregister.sh [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

FORCE=false

usage() {
    cat << 'EOF'
Unregister from Red Hat Subscription Manager

Usage:
  ./sm_unregister.sh [options]

Options:
  --force    Force unregistration without confirmation
  -h, --help Show this help message

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE=true
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

main() {
    parse_args "$@"

    log_section "Red Hat Subscription Manager Unregistration"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    if ! command -v subscription-manager &>/dev/null; then
        log_error "subscription-manager not found"
        exit 1
    fi

    # Check current status
    if ! subscription-manager status &>/dev/null; then
        log_info "System is not currently registered"
        exit 0
    fi

    log_info "Current registration status:"
    subscription-manager status

    # Confirm unregistration
    if [[ "${FORCE}" != "true" ]]; then
        if ! confirm "Are you sure you want to unregister?"; then
            log_info "Unregistration cancelled"
            exit 0
        fi
    fi

    log_info "Unregistering from subscription-manager..."

    if subscription-manager unregister; then
        log_success "Unregistered successfully"
    else
        log_warn "Unregister returned non-zero status"
    fi

    # Clean subscription data
    log_info "Cleaning subscription data..."
    subscription-manager clean || true

    log_audit "SM_UNREGISTER" "System unregistered from subscription-manager"

    log_success "Unregistration complete"
}

main "$@"
