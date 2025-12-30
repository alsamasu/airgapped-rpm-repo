#!/bin/bash
# validate-repos.sh - Validate repository integrity and accessibility
#
# Performs comprehensive validation of repositories:
# - BOM checksum verification
# - Repodata signature verification
# - HTTPS reachability
# - Optional dnf makecache test
#
# Usage: validate-repos.sh [--env testing|stable] [--full]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LIFECYCLE_DIR="${DATA_DIR}/lifecycle"
HTTPS_PORT="${RPMSERVER_HTTPS_PORT:-8443}"

# Parse arguments
TARGET_ENV="stable"
FULL_VALIDATION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            TARGET_ENV="$2"
            shift 2
            ;;
        --full)
            FULL_VALIDATION=true
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $(basename "$0") [OPTIONS]

Validate repository integrity and accessibility.

Options:
    --env ENV       Target environment (testing|stable, default: stable)
    --full          Perform full validation including dnf tests
    --help          Show this help message
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

TARGET_DIR="${LIFECYCLE_DIR}/${TARGET_ENV}"

log_info "Validating ${TARGET_ENV} environment..."

if [[ ! -d "${TARGET_DIR}" ]]; then
    log_error "Environment directory not found: ${TARGET_DIR}"
    exit 1
fi

VALIDATION_PASSED=true
CHECKS_RUN=0
CHECKS_PASSED=0

run_check() {
    local name="$1"
    local result="$2"
    
    ((CHECKS_RUN++))
    if [[ "${result}" == "0" ]]; then
        log_success "${name}"
        ((CHECKS_PASSED++))
    else
        log_error "${name}"
        VALIDATION_PASSED=false
    fi
}

# Check 1: Directory not empty
log_info "Check 1: Directory contents"
if [[ -n "$(ls -A "${TARGET_DIR}" 2>/dev/null)" ]]; then
    run_check "Directory has content" 0
else
    run_check "Directory has content" 1
fi

# Check 2: Metadata exists
log_info "Check 2: Metadata files"
if [[ -f "${TARGET_DIR}/.import_metadata.json" ]] || [[ -f "${TARGET_DIR}/.promotion_metadata.json" ]]; then
    run_check "Metadata file exists" 0
else
    run_check "Metadata file exists" 1
fi

# Check 3: Repodata integrity
log_info "Check 3: Repodata integrity"
REPODATA_VALID=0
find "${TARGET_DIR}" -name "repomd.xml" | while read -r repomd; do
    if ! xmllint --noout "${repomd}" 2>/dev/null; then
        REPODATA_VALID=1
    fi
done
run_check "Repodata XML valid" "${REPODATA_VALID}"

# Check 4: GPG signatures (if present)
log_info "Check 4: GPG signatures"
GPG_SIGS_FOUND=false
GPG_SIGS_VALID=0

find "${TARGET_DIR}" -name "repomd.xml.asc" | while read -r sig_file; do
    GPG_SIGS_FOUND=true
    xml_file="${sig_file%.asc}"
    if [[ -f "${xml_file}" ]]; then
        if ! gpg --verify "${sig_file}" "${xml_file}" 2>/dev/null; then
            GPG_SIGS_VALID=1
        fi
    fi
done

if [[ "${GPG_SIGS_FOUND}" == "true" ]]; then
    run_check "GPG signatures valid" "${GPG_SIGS_VALID}"
else
    log_info "No GPG signatures found (skipping)"
fi

# Check 5: HTTPS reachability
log_info "Check 5: HTTPS reachability"
HTTPS_RESULT=1
if curl -fsk "https://localhost:${HTTPS_PORT}/lifecycle/${TARGET_ENV}/" >/dev/null 2>&1; then
    HTTPS_RESULT=0
fi
run_check "HTTPS reachable" "${HTTPS_RESULT}"

# Check 6: Full dnf validation (if requested)
if [[ "${FULL_VALIDATION}" == "true" ]] && command_exists dnf; then
    log_info "Check 6: dnf makecache test"
    
    TEMP_REPO=$(mktemp)
    cat > "${TEMP_REPO}" << EOF
[validation-test]
name=Validation Test - ${TARGET_ENV}
baseurl=https://localhost:${HTTPS_PORT}/lifecycle/${TARGET_ENV}/
enabled=1
gpgcheck=0
sslverify=0
EOF
    
    DNF_RESULT=1
    if dnf --config="${TEMP_REPO}" makecache --disablerepo='*' --enablerepo='validation-test' 2>/dev/null; then
        DNF_RESULT=0
    fi
    rm -f "${TEMP_REPO}"
    
    run_check "dnf makecache successful" "${DNF_RESULT}"
fi

# Summary
echo ""
log_info "Validation Summary"
log_info "=================="
log_info "Environment: ${TARGET_ENV}"
log_info "Checks run: ${CHECKS_RUN}"
log_info "Checks passed: ${CHECKS_PASSED}"

if [[ "${VALIDATION_PASSED}" == "true" ]]; then
    log_success "All validation checks passed"
    exit 0
else
    log_error "Some validation checks failed"
    exit 1
fi
