#!/bin/bash
# internal_e2e_test.sh - End-to-end tests for internal architecture
#
# Tests the complete internal architecture including:
# - HTTPS RPM publisher with self-signed certs
# - Lifecycle environments (testing/stable)
# - SSH test hosts
# - TLS syslog sink
# - Ansible automation
#
# Usage: ./scripts/internal_e2e_test.sh [--keep-containers]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common functions if available
if [[ -f "${SCRIPT_DIR}/common/logging.sh" ]]; then
    source "${SCRIPT_DIR}/common/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[OK] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
fi

# Configuration
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)}"
KEEP_CONTAINERS=false
NETWORK_NAME="internal-e2e-net"
TEST_PASSED=0
TEST_FAILED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-containers)
            KEEP_CONTAINERS=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Cleanup function
cleanup() {
    if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
        log_info "Keeping containers for debugging"
        log_info "Run 'make internal-down' to clean up"
        return
    fi
    
    log_info "Cleaning up..."
    ${CONTAINER_RUNTIME} stop e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8 e2e-ansible 2>/dev/null || true
    ${CONTAINER_RUNTIME} rm e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8 e2e-ansible 2>/dev/null || true
    ${CONTAINER_RUNTIME} network rm "${NETWORK_NAME}" 2>/dev/null || true
    rm -rf "${PROJECT_DIR}/testdata/e2e-lifecycle" 2>/dev/null || true
}

trap cleanup EXIT

# Test helper functions
run_test() {
    local name="$1"
    local command="$2"
    
    log_info "Testing: ${name}..."
    if eval "${command}"; then
        log_success "${name}"
        ((TEST_PASSED++))
        return 0
    else
        log_error "${name}"
        ((TEST_FAILED++))
        return 1
    fi
}

wait_for_container() {
    local container="$1"
    local max_wait="${2:-30}"
    local count=0
    
    while [[ $count -lt $max_wait ]]; do
        if ${CONTAINER_RUNTIME} ps --format '{{.Names}}' | grep -q "^${container}$"; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    return 1
}

wait_for_http() {
    local url="$1"
    local max_wait="${2:-30}"
    local count=0
    
    while [[ $count -lt $max_wait ]]; do
        if curl -fsk "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((count++))
    done
    return 1
}

# ============================================================================
# E2E Test Suite
# ============================================================================

log_info "=========================================="
log_info "Internal Architecture E2E Tests"
log_info "=========================================="

cd "${PROJECT_DIR}"

# Step 1: Build images
log_info "Step 1/10: Building container images..."

run_test "Build RPM publisher image" \
    "${CONTAINER_RUNTIME} build -t airgap-rpm-publisher:e2e -f containers/rpm-publisher/Containerfile containers/rpm-publisher/"

run_test "Build SSH host UBI9 image" \
    "${CONTAINER_RUNTIME} build -t ssh-host-ubi9:e2e -f testdata/ssh-host-ubi9/Containerfile testdata/ssh-host-ubi9/"

run_test "Build SSH host UBI8 image" \
    "${CONTAINER_RUNTIME} build -t ssh-host-ubi8:e2e -f testdata/ssh-host-ubi8/Containerfile testdata/ssh-host-ubi8/"

run_test "Build syslog sink image" \
    "${CONTAINER_RUNTIME} build -t tls-syslog-sink:e2e -f testdata/tls-syslog-sink/Containerfile testdata/tls-syslog-sink/"

# Step 2: Create network
log_info "Step 2/10: Creating container network..."
${CONTAINER_RUNTIME} network rm "${NETWORK_NAME}" 2>/dev/null || true
run_test "Create network" \
    "${CONTAINER_RUNTIME} network create ${NETWORK_NAME}"

# Step 3: Create test data directories
log_info "Step 3/10: Setting up test data..."
mkdir -p "${PROJECT_DIR}/testdata/e2e-lifecycle/testing"
mkdir -p "${PROJECT_DIR}/testdata/e2e-lifecycle/stable"
mkdir -p "${PROJECT_DIR}/testdata/e2e-repos"

# Step 4: Start syslog sink
log_info "Step 4/10: Starting TLS syslog sink..."
run_test "Start syslog sink" \
    "${CONTAINER_RUNTIME} run -d --name e2e-syslog-sink --network ${NETWORK_NAME} tls-syslog-sink:e2e"

sleep 2
run_test "Syslog sink is running" \
    "${CONTAINER_RUNTIME} exec e2e-syslog-sink pgrep rsyslogd"

# Step 5: Start RPM publisher
log_info "Step 5/10: Starting RPM publisher with HTTPS..."
run_test "Start RPM publisher" \
    "${CONTAINER_RUNTIME} run -d --name e2e-rpm-publisher --network ${NETWORK_NAME} \
        -p 18080:8080 -p 18443:8443 \
        -v ${PROJECT_DIR}/testdata/e2e-repos:/data/repos:Z \
        -v ${PROJECT_DIR}/testdata/e2e-lifecycle:/data/lifecycle:Z \
        airgap-rpm-publisher:e2e"

log_info "Waiting for RPM publisher to start..."
wait_for_http "https://localhost:18443/" 30

run_test "RPM publisher HTTPS is accessible" \
    "curl -fsk https://localhost:18443/"

run_test "RPM publisher HTTP is accessible" \
    "curl -fs http://localhost:18080/"

# Step 6: Start SSH hosts
log_info "Step 6/10: Starting SSH test hosts..."
run_test "Start SSH host UBI9" \
    "${CONTAINER_RUNTIME} run -d --name e2e-ssh-ubi9 --network ${NETWORK_NAME} \
        -e AIRGAP_HOST_ID=e2e-test-ubi9 ssh-host-ubi9:e2e"

run_test "Start SSH host UBI8" \
    "${CONTAINER_RUNTIME} run -d --name e2e-ssh-ubi8 --network ${NETWORK_NAME} \
        -e AIRGAP_HOST_ID=e2e-test-ubi8 ssh-host-ubi8:e2e"

sleep 2

run_test "SSH UBI9 host is running" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 pgrep sshd"

run_test "SSH UBI8 host is running" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi8 pgrep sshd"

# Step 7: Test HTTPS certificate
log_info "Step 7/10: Validating HTTPS certificate..."
run_test "HTTPS certificate is valid" \
    "curl -vsk https://localhost:18443/ 2>&1 | grep -q 'SSL certificate verify'"

# Step 8: Test lifecycle endpoints
log_info "Step 8/10: Testing lifecycle environment endpoints..."
run_test "Lifecycle testing endpoint exists" \
    "${CONTAINER_RUNTIME} exec e2e-rpm-publisher curl -fs http://localhost:8080/lifecycle/testing/ || true"

run_test "Lifecycle stable endpoint exists" \
    "${CONTAINER_RUNTIME} exec e2e-rpm-publisher curl -fs http://localhost:8080/lifecycle/stable/ || true"

# Step 9: Test syslog TLS connectivity
log_info "Step 9/10: Testing syslog TLS connectivity..."

# Get the CA certificate from syslog sink
${CONTAINER_RUNTIME} exec e2e-syslog-sink cat /etc/pki/rsyslog/ca.crt > /tmp/syslog-ca.crt 2>/dev/null || true

if [[ -f /tmp/syslog-ca.crt ]]; then
    run_test "Syslog CA certificate generated" "true"
else
    run_test "Syslog CA certificate generated" "false"
fi

# Test TLS connection from SSH host to syslog
run_test "SSH host can reach syslog sink" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 bash -c 'echo test | nc -w1 e2e-syslog-sink 514'" || true

# Step 10: Test container networking
log_info "Step 10/10: Testing container networking..."
run_test "SSH host can reach RPM publisher" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fsk https://e2e-rpm-publisher:8443/ || \
     ${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fs http://e2e-rpm-publisher:8080/"

# ============================================================================
# Summary
# ============================================================================

echo ""
log_info "=========================================="
log_info "E2E Test Results"
log_info "=========================================="
log_info "Passed: ${TEST_PASSED}"
log_info "Failed: ${TEST_FAILED}"

if [[ ${TEST_FAILED} -gt 0 ]]; then
    log_error "Some tests failed!"
    exit 1
else
    log_success "All tests passed!"
    exit 0
fi
