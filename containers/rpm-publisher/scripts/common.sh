#!/bin/bash
# common.sh - Common functions for RPM Publisher scripts
#
# Provides logging and utility functions.

# Prevent double-sourcing
if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
_COMMON_SH_LOADED=1

# Color codes
readonly LOG_RED='\033[0;31m'
readonly LOG_GREEN='\033[0;32m'
readonly LOG_YELLOW='\033[0;33m'
readonly LOG_BLUE='\033[0;34m'
readonly LOG_NC='\033[0m'

# Get ISO 8601 timestamp
_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Log informational message
log_info() {
    echo -e "${LOG_BLUE}[INFO]${LOG_NC} $*"
}

# Log success message
log_success() {
    echo -e "${LOG_GREEN}[OK]${LOG_NC} $*"
}

# Log warning message
log_warn() {
    echo -e "${LOG_YELLOW}[WARN]${LOG_NC} $*" >&2
}

# Log error message
log_error() {
    echo -e "${LOG_RED}[ERROR]${LOG_NC} $*" >&2
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Verify checksum of a file
verify_checksum() {
    local file="$1"
    local expected="$2"
    local algorithm="${3:-sha256}"
    
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    
    local actual
    case "${algorithm}" in
        sha256)
            actual=$(sha256sum "${file}" | awk '{print $1}')
            ;;
        sha512)
            actual=$(sha512sum "${file}" | awk '{print $1}')
            ;;
        md5)
            actual=$(md5sum "${file}" | awk '{print $1}')
            ;;
        *)
            log_error "Unknown algorithm: ${algorithm}"
            return 1
            ;;
    esac
    
    if [[ "${actual}" == "${expected}" ]]; then
        return 0
    else
        log_error "Checksum mismatch for ${file}"
        log_error "Expected: ${expected}"
        log_error "Actual: ${actual}"
        return 1
    fi
}

# Export functions
export -f log_info log_success log_warn log_error
export -f command_exists verify_checksum
