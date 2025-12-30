#!/bin/bash
# gpg_functions.sh - GPG key management functions for Airgapped RPM Repository System
#
# Usage:
#   source gpg_functions.sh
#   gpg_init              - Initialize GPG keyring and generate signing key
#   gpg_export            - Export public key for distribution
#   gpg_sign_file         - Sign a file (detached signature)
#   gpg_sign_repomd       - Sign repository metadata
#   gpg_import_key        - Import a public key
#
# Can also be run directly:
#   ./gpg_functions.sh init
#   ./gpg_functions.sh export

set -euo pipefail

# Prevent double-sourcing
if [[ -n "${_GPG_FUNCTIONS_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_GPG_FUNCTIONS_SH_LOADED=1

# Source logging if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${_LOGGING_SH_LOADED:-}" ]]; then
    # shellcheck source=logging.sh
    source "${SCRIPT_DIR}/logging.sh"
fi

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
KEYS_DIR="${DATA_DIR}/keys"
GPG_HOMEDIR="${KEYS_DIR}/.gnupg"
GPG_KEY_NAME="${GPG_KEY_NAME:-RPM Repository Signing Key}"
GPG_KEY_EMAIL="${GPG_KEY_EMAIL:-rpm-signing@internal.local}"
GPG_KEY_COMMENT="${GPG_KEY_COMMENT:-Airgapped RPM Repository System}"
GPG_KEY_EXPIRE="${GPG_KEY_EXPIRE:-2y}"
GPG_KEY_LENGTH="${GPG_KEY_LENGTH:-4096}"

# Common GPG options
gpg_opts() {
    local opts=(
        --homedir "${GPG_HOMEDIR}"
        --batch
        --no-tty
    )
    echo "${opts[@]}"
}

# Initialize GPG keyring and generate signing key
gpg_init() {
    log_section "GPG Key Initialization"

    # Create keyring directory
    if [[ ! -d "${GPG_HOMEDIR}" ]]; then
        mkdir -p "${GPG_HOMEDIR}"
        chmod 700 "${GPG_HOMEDIR}"
        log_info "Created GPG homedir: ${GPG_HOMEDIR}"
    fi

    # Check if key already exists
    local existing_keys
    existing_keys=$(gpg $(gpg_opts) --list-keys 2>/dev/null | grep -c "^pub" || echo "0")

    if [[ "${existing_keys}" -gt 0 ]]; then
        log_warn "GPG key already exists in ${GPG_HOMEDIR}"
        log_info "Use gpg_export to export the public key"
        gpg $(gpg_opts) --list-keys
        return 0
    fi

    log_info "Generating new GPG signing key..."
    log_info "  Name: ${GPG_KEY_NAME}"
    log_info "  Email: ${GPG_KEY_EMAIL}"
    log_info "  Expires: ${GPG_KEY_EXPIRE}"

    # Create key generation parameters
    local keygen_params
    keygen_params=$(mktemp)
    cat > "${keygen_params}" << KEYGEN
%echo Generating RPM signing key
Key-Type: RSA
Key-Length: ${GPG_KEY_LENGTH}
Key-Usage: sign
Name-Real: ${GPG_KEY_NAME}
Name-Comment: ${GPG_KEY_COMMENT}
Name-Email: ${GPG_KEY_EMAIL}
Expire-Date: ${GPG_KEY_EXPIRE}
%no-protection
%commit
%echo Key generation complete
KEYGEN

    # Generate key
    if ! gpg $(gpg_opts) --gen-key "${keygen_params}" 2>&1; then
        rm -f "${keygen_params}"
        log_error "Failed to generate GPG key"
        return 1
    fi

    rm -f "${keygen_params}"

    # Get key ID
    local key_id
    key_id=$(gpg $(gpg_opts) --list-keys --keyid-format LONG "${GPG_KEY_EMAIL}" 2>/dev/null | \
             grep "^pub" | head -1 | awk '{print $2}' | cut -d'/' -f2)

    if [[ -z "${key_id}" ]]; then
        log_error "Failed to retrieve generated key ID"
        return 1
    fi

    log_success "GPG key generated successfully"
    log_info "Key ID: ${key_id}"

    # Save key ID to config
    echo "GPG_KEY_ID=${key_id}" > "${KEYS_DIR}/key_id.conf"

    # Export public key
    gpg_export

    log_audit "GPG_KEY_GENERATED" "Key ID: ${key_id}"
    return 0
}

# Export public key for distribution
gpg_export() {
    log_info "Exporting GPG public key..."

    if [[ ! -d "${GPG_HOMEDIR}" ]]; then
        log_error "GPG homedir does not exist: ${GPG_HOMEDIR}"
        return 1
    fi

    # Get key ID
    local key_id
    if [[ -f "${KEYS_DIR}/key_id.conf" ]]; then
        # shellcheck source=/dev/null
        source "${KEYS_DIR}/key_id.conf"
        key_id="${GPG_KEY_ID:-}"
    fi

    if [[ -z "${key_id}" ]]; then
        key_id=$(gpg $(gpg_opts) --list-keys --keyid-format LONG 2>/dev/null | \
                 grep "^pub" | head -1 | awk '{print $2}' | cut -d'/' -f2)
    fi

    if [[ -z "${key_id}" ]]; then
        log_error "No GPG key found to export"
        return 1
    fi

    # Export in ASCII armor format
    local public_key_file="${KEYS_DIR}/RPM-GPG-KEY-internal"
    gpg $(gpg_opts) --armor --export "${key_id}" > "${public_key_file}"

    # Also export in binary format for rpm --import
    local public_key_binary="${KEYS_DIR}/RPM-GPG-KEY-internal.gpg"
    gpg $(gpg_opts) --export "${key_id}" > "${public_key_binary}"

    log_success "Public key exported:"
    log_info "  ASCII: ${public_key_file}"
    log_info "  Binary: ${public_key_binary}"

    # Show fingerprint
    log_info "Key fingerprint:"
    gpg $(gpg_opts) --fingerprint "${key_id}"

    return 0
}

# Sign a file with detached signature
# Usage: gpg_sign_file "/path/to/file"
gpg_sign_file() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi

    # Get key ID
    local key_id
    if [[ -f "${KEYS_DIR}/key_id.conf" ]]; then
        # shellcheck source=/dev/null
        source "${KEYS_DIR}/key_id.conf"
        key_id="${GPG_KEY_ID:-}"
    fi

    if [[ -z "${key_id}" ]]; then
        key_id=$(gpg $(gpg_opts) --list-keys --keyid-format LONG 2>/dev/null | \
                 grep "^pub" | head -1 | awk '{print $2}' | cut -d'/' -f2)
    fi

    if [[ -z "${key_id}" ]]; then
        log_error "No GPG key found for signing"
        return 1
    fi

    local signature="${file}.asc"

    # Remove existing signature
    rm -f "${signature}"

    # Create detached ASCII signature
    if ! gpg $(gpg_opts) \
        --local-user "${key_id}" \
        --armor \
        --detach-sign \
        --output "${signature}" \
        "${file}"; then
        log_error "Failed to sign file: ${file}"
        return 1
    fi

    log_debug "Signed: ${file} -> ${signature}"
    return 0
}

# Sign repository metadata (repomd.xml)
# Usage: gpg_sign_repomd "/path/to/repodata"
gpg_sign_repomd() {
    local repodata_dir="$1"
    local repomd="${repodata_dir}/repomd.xml"

    if [[ ! -f "${repomd}" ]]; then
        log_error "repomd.xml not found: ${repomd}"
        return 1
    fi

    gpg_sign_file "${repomd}"

    log_info "Repository metadata signed: ${repomd}.asc"
    return 0
}

# Import a public key
# Usage: gpg_import_key "/path/to/key.asc"
gpg_import_key() {
    local key_file="$1"

    if [[ ! -f "${key_file}" ]]; then
        log_error "Key file not found: ${key_file}"
        return 1
    fi

    # Ensure keyring directory exists
    if [[ ! -d "${GPG_HOMEDIR}" ]]; then
        mkdir -p "${GPG_HOMEDIR}"
        chmod 700 "${GPG_HOMEDIR}"
    fi

    if ! gpg $(gpg_opts) --import "${key_file}" 2>&1; then
        log_error "Failed to import key: ${key_file}"
        return 1
    fi

    log_success "Key imported: ${key_file}"
    gpg $(gpg_opts) --list-keys

    log_audit "GPG_KEY_IMPORTED" "Key file: ${key_file}"
    return 0
}

# Verify a signature
# Usage: gpg_verify "/path/to/file.asc" OR gpg_verify "/path/to/file" "/path/to/file.sig"
gpg_verify() {
    local file="$1"
    local signature="${2:-}"

    # If signature not provided, assume detached .asc signature
    if [[ -z "${signature}" ]]; then
        if [[ "${file}" == *.asc || "${file}" == *.sig ]]; then
            signature="${file}"
            file="${file%.asc}"
            file="${file%.sig}"
        else
            signature="${file}.asc"
        fi
    fi

    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi

    if [[ ! -f "${signature}" ]]; then
        log_error "Signature not found: ${signature}"
        return 1
    fi

    local output
    if ! output=$(gpg $(gpg_opts) --verify "${signature}" "${file}" 2>&1); then
        log_error "Signature verification failed"
        log_error "${output}"
        return 1
    fi

    if echo "${output}" | grep -q "Good signature"; then
        log_success "Signature verified: ${file}"
        return 0
    else
        log_error "Signature verification failed: ${file}"
        return 1
    fi
}

# List all keys in keyring
gpg_list_keys() {
    gpg $(gpg_opts) --list-keys --keyid-format LONG
}

# Get key ID
gpg_get_key_id() {
    if [[ -f "${KEYS_DIR}/key_id.conf" ]]; then
        # shellcheck source=/dev/null
        source "${KEYS_DIR}/key_id.conf"
        echo "${GPG_KEY_ID:-}"
    else
        gpg $(gpg_opts) --list-keys --keyid-format LONG 2>/dev/null | \
            grep "^pub" | head -1 | awk '{print $2}' | cut -d'/' -f2
    fi
}

# Main function when run directly
main() {
    local command="${1:-help}"
    shift || true

    case "${command}" in
        init)
            gpg_init
            ;;
        export)
            gpg_export
            ;;
        sign)
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: gpg_functions.sh sign /path/to/file"
                exit 1
            fi
            gpg_sign_file "$1"
            ;;
        verify)
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: gpg_functions.sh verify /path/to/file.asc"
                exit 1
            fi
            gpg_verify "$1" "${2:-}"
            ;;
        import)
            if [[ -z "${1:-}" ]]; then
                log_error "Usage: gpg_functions.sh import /path/to/key.asc"
                exit 1
            fi
            gpg_import_key "$1"
            ;;
        list)
            gpg_list_keys
            ;;
        help|--help|-h)
            cat << 'EOF'
GPG Functions for Airgapped RPM Repository System

Usage: gpg_functions.sh <command> [options]

Commands:
  init       Initialize GPG keyring and generate signing key
  export     Export public key for distribution
  sign       Sign a file (creates .asc detached signature)
  verify     Verify a signature
  import     Import a public key
  list       List all keys in keyring
  help       Show this help message

Environment Variables:
  GPG_KEY_NAME     Key name (default: RPM Repository Signing Key)
  GPG_KEY_EMAIL    Key email (default: rpm-signing@internal.local)
  GPG_KEY_EXPIRE   Key expiration (default: 2y)

EOF
            ;;
        *)
            log_error "Unknown command: ${command}"
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
