#!/bin/bash
# sm_register.sh - Register with Red Hat subscription-manager
#
# Usage:
#   ./sm_register.sh --activation-key KEY --org ORG_ID
#   ./sm_register.sh --username USER --password PASS
#
# This script registers the system with Red Hat using subscription-manager.
# Credentials are NOT stored in any files or logs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
ACTIVATION_KEY=""
ORG_ID=""
USERNAME=""
PASSWORD=""
FORCE=false
AUTO_ATTACH=true
POOL_ID=""

usage() {
    cat << 'EOF'
Register with Red Hat Subscription Manager

Usage:
  ./sm_register.sh --activation-key KEY --org ORG_ID [options]
  ./sm_register.sh --username USER --password PASS [options]

Authentication Options (mutually exclusive):
  --activation-key KEY   Activation key for registration
  --org ORG_ID          Organization ID (required with activation key)
  --username USER       Red Hat username
  --password PASS       Red Hat password

Options:
  --force               Force re-registration if already registered
  --no-auto-attach      Do not auto-attach subscriptions
  --pool POOL_ID        Attach specific subscription pool
  -h, --help            Show this help message

Environment Variables:
  ACTIVATION_KEY        Alternative to --activation-key
  ORG_ID                Alternative to --org
  SM_USER               Alternative to --username
  SM_PASS               Alternative to --password

Security Notes:
  - Credentials are not logged or stored
  - Use activation keys for automated deployments
  - Password is read from stdin if not provided

Examples:
  # Register with activation key
  ./sm_register.sh --activation-key mykey-1234 --org 12345678

  # Register with username/password
  ./sm_register.sh --username user@example.com --password 'MyP@ssw0rd'

  # Force re-registration
  ./sm_register.sh --force --activation-key mykey --org 12345678

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --activation-key)
                ACTIVATION_KEY="$2"
                shift 2
                ;;
            --org)
                ORG_ID="$2"
                shift 2
                ;;
            --username)
                USERNAME="$2"
                shift 2
                ;;
            --password)
                PASSWORD="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --no-auto-attach)
                AUTO_ATTACH=false
                shift
                ;;
            --pool)
                POOL_ID="$2"
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

    # Check environment variables as fallback
    ACTIVATION_KEY="${ACTIVATION_KEY:-${ACTIVATION_KEY_ENV:-}}"
    ORG_ID="${ORG_ID:-${ORG_ID_ENV:-}}"
    USERNAME="${USERNAME:-${SM_USER:-}}"
    PASSWORD="${PASSWORD:-${SM_PASS:-}}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v subscription-manager &>/dev/null; then
        log_error "subscription-manager not found"
        log_error "Install with: dnf install subscription-manager"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

check_registration_status() {
    log_info "Checking current registration status..."

    if subscription-manager status &>/dev/null; then
        if [[ "${FORCE}" == "true" ]]; then
            log_warn "System is already registered, will unregister first (--force)"
            return 1
        else
            log_success "System is already registered"
            subscription-manager status
            log_info "Use --force to re-register"
            exit 0
        fi
    else
        log_info "System is not registered"
        return 0
    fi
}

unregister() {
    log_info "Unregistering current subscription..."

    if subscription-manager unregister &>/dev/null; then
        log_success "Unregistered successfully"
    else
        log_warn "Unregister returned non-zero, continuing..."
    fi

    # Clean up
    subscription-manager clean &>/dev/null || true
}

register_with_activation_key() {
    log_info "Registering with activation key..."

    if [[ -z "${ACTIVATION_KEY}" ]]; then
        log_error "Activation key not provided"
        return 1
    fi

    if [[ -z "${ORG_ID}" ]]; then
        log_error "Organization ID not provided (required with activation key)"
        return 1
    fi

    local cmd=(
        subscription-manager register
        --activationkey "${ACTIVATION_KEY}"
        --org "${ORG_ID}"
    )

    if ! "${cmd[@]}"; then
        log_error "Registration with activation key failed"
        return 1
    fi

    log_success "Registered with activation key"
    log_audit "SM_REGISTER" "Registered with activation key for org ${ORG_ID}"
    return 0
}

register_with_credentials() {
    log_info "Registering with username/password..."

    if [[ -z "${USERNAME}" ]]; then
        log_error "Username not provided"
        return 1
    fi

    if [[ -z "${PASSWORD}" ]]; then
        # Try to read password interactively
        if [[ -t 0 ]]; then
            read -r -s -p "Enter password for ${USERNAME}: " PASSWORD
            echo ""
        else
            log_error "Password not provided and not running interactively"
            return 1
        fi
    fi

    local cmd=(
        subscription-manager register
        --username "${USERNAME}"
        --password "${PASSWORD}"
    )

    if [[ "${AUTO_ATTACH}" == "true" ]]; then
        cmd+=(--auto-attach)
    fi

    if ! "${cmd[@]}"; then
        log_error "Registration with username/password failed"
        return 1
    fi

    log_success "Registered with username/password"
    log_audit "SM_REGISTER" "Registered with username ${USERNAME}"
    return 0
}

attach_subscription() {
    if [[ -n "${POOL_ID}" ]]; then
        log_info "Attaching subscription pool: ${POOL_ID}"
        if ! subscription-manager attach --pool="${POOL_ID}"; then
            log_error "Failed to attach subscription pool"
            return 1
        fi
        log_success "Subscription pool attached"
    elif [[ "${AUTO_ATTACH}" == "true" ]]; then
        log_info "Auto-attaching subscriptions..."
        if ! subscription-manager attach --auto; then
            log_warn "Auto-attach completed with warnings"
        fi
        log_success "Subscriptions auto-attached"
    fi

    return 0
}

show_status() {
    log_info "Registration status:"
    echo ""
    subscription-manager status
    echo ""
    log_info "Attached subscriptions:"
    subscription-manager list --consumed 2>/dev/null || true
}

main() {
    parse_args "$@"

    log_section "Red Hat Subscription Manager Registration"

    check_prerequisites

    # Validate authentication method
    if [[ -n "${ACTIVATION_KEY}" && -n "${USERNAME}" ]]; then
        log_error "Cannot use both activation key and username/password"
        exit 1
    fi

    if [[ -z "${ACTIVATION_KEY}" && -z "${USERNAME}" ]]; then
        log_error "Must provide either --activation-key or --username"
        usage
        exit 1
    fi

    # Check current status
    if ! check_registration_status; then
        unregister
    fi

    # Register
    if [[ -n "${ACTIVATION_KEY}" ]]; then
        register_with_activation_key
    else
        register_with_credentials
    fi

    # Attach subscriptions
    attach_subscription

    # Show final status
    show_status

    log_success "Registration complete"
}

main "$@"
