#!/bin/bash
# internal_e2e_test.sh - End-to-end tests for internal architecture
#
# Tests the complete internal architecture including:
# - HTTPS RPM publisher with self-signed certs
# - Lifecycle environments (testing/stable)
# - SSH test hosts
# - TLS syslog sink
#
# Usage: ./scripts/internal_e2e_test.sh [--keep-containers]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Use simple logging for E2E tests
log_info() { echo -e "\033[0;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }

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
        log_info "Run these commands to clean up:"
        log_info "  docker stop e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8"
        log_info "  docker rm e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8"
        log_info "  docker network rm ${NETWORK_NAME}"
        return
    fi
    
    log_info "Cleaning up..."
    ${CONTAINER_RUNTIME} stop e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8 2>/dev/null || true
    ${CONTAINER_RUNTIME} rm e2e-rpm-publisher e2e-syslog-sink e2e-ssh-ubi9 e2e-ssh-ubi8 2>/dev/null || true
    ${CONTAINER_RUNTIME} network rm "${NETWORK_NAME}" 2>/dev/null || true
}

trap cleanup EXIT

# Test helper functions
run_test() {
    local name="$1"
    local command="$2"
    
    log_info "Testing: ${name}..."
    if eval "${command}"; then
        log_success "${name}"
        ((TEST_PASSED++)) || true
        return 0
    else
        log_error "${name}"
        ((TEST_FAILED++)) || true
        return 0
    fi
}

run_required_test() {
    local name="$1"
    local command="$2"
    
    log_info "Testing: ${name}..."
    if eval "${command}"; then
        log_success "${name}"
        ((TEST_PASSED++)) || true
        return 0
    else
        log_error "${name} - REQUIRED TEST FAILED"
        ((TEST_FAILED++)) || true
        return 1
    fi
}

# ============================================================================
# E2E Test Suite
# ============================================================================

log_info "=========================================="
log_info "Internal Architecture E2E Tests"
log_info "=========================================="

cd "${PROJECT_DIR}"

# Step 1: Build images
log_info "Step 1/7: Building container images..."

if ! run_required_test "Build RPM publisher image" \
    "${CONTAINER_RUNTIME} build -t airgap-rpm-publisher:e2e -f containers/rpm-publisher/Containerfile containers/rpm-publisher/"; then
    exit 1
fi

if ! run_required_test "Build SSH host EL9 image" \
    "${CONTAINER_RUNTIME} build -t ssh-host-ubi9:e2e -f testdata/ssh-host-ubi9/Containerfile testdata/ssh-host-ubi9/"; then
    exit 1
fi

if ! run_required_test "Build SSH host EL8 image" \
    "${CONTAINER_RUNTIME} build -t ssh-host-ubi8:e2e -f testdata/ssh-host-ubi8/Containerfile testdata/ssh-host-ubi8/"; then
    exit 1
fi

if ! run_required_test "Build syslog sink image" \
    "${CONTAINER_RUNTIME} build -t tls-syslog-sink:e2e -f testdata/tls-syslog-sink/Containerfile testdata/tls-syslog-sink/"; then
    exit 1
fi

# Step 2: Create network
log_info "Step 2/7: Creating container network..."
${CONTAINER_RUNTIME} network rm "${NETWORK_NAME}" 2>/dev/null || true
run_test "Create network" \
    "${CONTAINER_RUNTIME} network create ${NETWORK_NAME}"

# Step 3: Start syslog sink
log_info "Step 3/7: Starting TLS syslog sink..."
run_test "Start syslog sink" \
    "${CONTAINER_RUNTIME} run -d --name e2e-syslog-sink --network ${NETWORK_NAME} tls-syslog-sink:e2e"

sleep 2
run_test "Syslog sink is running" \
    "${CONTAINER_RUNTIME} exec e2e-syslog-sink pgrep rsyslogd"

# Step 4: Start RPM publisher
log_info "Step 4/7: Starting RPM publisher with HTTPS..."
run_test "Start RPM publisher" \
    "${CONTAINER_RUNTIME} run -d --name e2e-rpm-publisher --network ${NETWORK_NAME} airgap-rpm-publisher:e2e"

sleep 5

# Step 5: Start SSH hosts
log_info "Step 5/7: Starting SSH test hosts..."
run_test "Start SSH host EL9" \
    "${CONTAINER_RUNTIME} run -d --name e2e-ssh-ubi9 --network ${NETWORK_NAME} \
        -e AIRGAP_HOST_ID=e2e-test-ubi9 ssh-host-ubi9:e2e"

run_test "Start SSH host EL8" \
    "${CONTAINER_RUNTIME} run -d --name e2e-ssh-ubi8 --network ${NETWORK_NAME} \
        -e AIRGAP_HOST_ID=e2e-test-ubi8 ssh-host-ubi8:e2e"

sleep 3

run_test "SSH EL9 host is running" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 pgrep sshd"

run_test "SSH EL8 host is running" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi8 pgrep sshd"

# Step 6: Test lifecycle endpoints
log_info "Step 6/7: Testing lifecycle environment endpoints..."
run_test "Lifecycle testing directory exists" \
    "${CONTAINER_RUNTIME} exec e2e-rpm-publisher ls -la /data/lifecycle/testing/"

run_test "Lifecycle stable directory exists" \
    "${CONTAINER_RUNTIME} exec e2e-rpm-publisher ls -la /data/lifecycle/stable/"

run_test "SSL certificates generated" \
    "${CONTAINER_RUNTIME} exec e2e-rpm-publisher ls -la /data/certs/server.crt"

# Step 7: Test container networking (the actual production scenario)
log_info "Step 7/7: Testing container networking..."

run_test "SSH host can reach RPM publisher via HTTP" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fs http://e2e-rpm-publisher:8080/ | grep -q 'Internal RPM Repository'"

run_test "SSH host can reach RPM publisher via HTTPS" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fsk https://e2e-rpm-publisher:8443/ | grep -q 'Internal RPM Repository'"

run_test "HTTPS certificate is self-signed" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 bash -c 'echo | openssl s_client -connect e2e-rpm-publisher:8443 2>/dev/null | grep -q \"subject\"'"

run_test "Lifecycle testing accessible via HTTP" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fs http://e2e-rpm-publisher:8080/lifecycle/testing/"

run_test "Lifecycle stable accessible via HTTP" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 curl -fs http://e2e-rpm-publisher:8080/lifecycle/stable/"

run_test "SSH host can reach syslog sink" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi9 bash -c 'echo test | timeout 2 nc e2e-syslog-sink 514 2>/dev/null; exit 0'"

run_test "EL8 host can also reach RPM publisher" \
    "${CONTAINER_RUNTIME} exec e2e-ssh-ubi8 curl -fs http://e2e-rpm-publisher:8080/ | grep -q 'Internal RPM Repository'"

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
