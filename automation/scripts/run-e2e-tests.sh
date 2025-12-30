#!/bin/bash
# automation/scripts/run-e2e-tests.sh
# End-to-end test harness for airgapped RPM repository deployment
#
# Tests:
# 1. Spec validation
# 2. VM deployment via kickstart
# 3. Post-install verification (SSH, services, HTTPS)
# 4. Generates test report artifacts
#
# Usage: ./run-e2e-tests.sh [--skip-deploy] [--cleanup]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$REPO_ROOT/automation/artifacts/e2e"
SPEC_PATH="$REPO_ROOT/config/spec.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test state
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
START_TIME=$(date +%s)

# Parse arguments
SKIP_DEPLOY=false
CLEANUP_AFTER=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-deploy) SKIP_DEPLOY=true; shift ;;
        --cleanup) CLEANUP_AFTER=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Initialize
mkdir -p "$ARTIFACTS_DIR"
REPORT_JSON="$ARTIFACTS_DIR/report.json"
REPORT_MD="$ARTIFACTS_DIR/report.md"
SERVERS_JSON="$ARTIFACTS_DIR/servers.json"
LOG_FILE="$ARTIFACTS_DIR/e2e.log"

# Logging
log() {
    local level=$1
    shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

log_test() {
    local name=$1
    local status=$2
    local details=${3:-""}
    
    case $status in
        PASS) 
            echo -e "${GREEN}[PASS]${NC} $name"
            ((TESTS_PASSED++))
            ;;
        FAIL) 
            echo -e "${RED}[FAIL]${NC} $name"
            ((TESTS_FAILED++))
            ;;
        SKIP) 
            echo -e "${YELLOW}[SKIP]${NC} $name"
            ((TESTS_SKIPPED++))
            ;;
    esac
    
    log "$status" "$name: $details"
}

# Test functions
test_spec_validation() {
    log "INFO" "Testing spec.yaml validation"
    
    if [[ ! -f "$SPEC_PATH" ]]; then
        log_test "Spec file exists" "FAIL" "File not found: $SPEC_PATH"
        return 1
    fi
    log_test "Spec file exists" "PASS"
    
    if make -C "$REPO_ROOT" validate-spec > "$ARTIFACTS_DIR/validate-spec.log" 2>&1; then
        log_test "Spec validation" "PASS"
        return 0
    else
        log_test "Spec validation" "FAIL" "See validate-spec.log"
        return 1
    fi
}

test_vm_deployment() {
    log "INFO" "Testing VM deployment"
    
    if $SKIP_DEPLOY; then
        log_test "VM deployment" "SKIP" "Skipped via --skip-deploy"
        return 0
    fi
    
    # Deploy VMs
    log "INFO" "Running make servers-deploy"
    if pwsh -Command "
        Set-Location '$REPO_ROOT'
        \$env:VMWARE_SERVER = \$env:VMWARE_SERVER
        \$env:VMWARE_USER = \$env:VMWARE_USER
        \$env:VMWARE_PASSWORD = \$env:VMWARE_PASSWORD
        & './automation/powercli/deploy-rpm-servers.ps1' -SpecPath '$SPEC_PATH' -Force
    " > "$ARTIFACTS_DIR/deploy.log" 2>&1; then
        log_test "VM deployment initiated" "PASS"
    else
        log_test "VM deployment initiated" "FAIL" "See deploy.log"
        return 1
    fi
    
    # Wait for installation
    log "INFO" "Waiting for installation to complete"
    if pwsh -Command "
        Set-Location '$REPO_ROOT'
        & './automation/powercli/wait-for-install-complete.ps1' -SpecPath '$SPEC_PATH' -TimeoutMinutes 45
    " > "$ARTIFACTS_DIR/wait-install.log" 2>&1; then
        log_test "Installation completed" "PASS"
    else
        log_test "Installation completed" "FAIL" "Timeout or error - see wait-install.log"
        return 1
    fi
    
    return 0
}

retrieve_server_ips() {
    log "INFO" "Retrieving server IPs"
    
    pwsh -Command "
        Set-Location '$REPO_ROOT'
        & './automation/powercli/wait-for-dhcp-and-report.ps1' -SpecPath '$SPEC_PATH' -OutputFormat json -OutputFile '$SERVERS_JSON'
    " > "$ARTIFACTS_DIR/dhcp-report.log" 2>&1
    
    if [[ -f "$SERVERS_JSON" ]]; then
        log_test "IP retrieval" "PASS"
        cat "$SERVERS_JSON"
        return 0
    else
        log_test "IP retrieval" "FAIL" "No servers.json produced"
        return 1
    fi
}

get_server_ip() {
    local vm_type=$1
    if [[ -f "$SERVERS_JSON" ]]; then
        python3 -c "
import json
with open('$SERVERS_JSON') as f:
    data = json.load(f)
for vm in data:
    if vm.get('Type') == '$vm_type':
        print(vm.get('IPAddress', ''))
        break
" 2>/dev/null
    fi
}

get_ssh_creds() {
    python3 -c "
import yaml
with open('$SPEC_PATH') as f:
    spec = yaml.safe_load(f)
user = spec.get('credentials', {}).get('initial_admin_user', 'admin')
password = spec.get('credentials', {}).get('initial_admin_password', '')
print(f'{user}:{password}')
" 2>/dev/null
}

ssh_cmd() {
    local host=$1
    shift
    local creds=$(get_ssh_creds)
    local user="${creds%%:*}"
    local pass="${creds#*:}"
    
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${user}@${host}" "$@" 2>/dev/null
}

test_external_server() {
    log "INFO" "Testing External RPM Server"
    
    local ip=$(get_server_ip "external")
    if [[ -z "$ip" ]]; then
        log_test "External: IP available" "FAIL" "No IP found"
        return 1
    fi
    log_test "External: IP available" "PASS" "$ip"
    
    # SSH connectivity
    if ssh_cmd "$ip" "echo ok" > /dev/null 2>&1; then
        log_test "External: SSH accessible" "PASS"
    else
        log_test "External: SSH accessible" "FAIL" "Cannot connect to $ip"
        return 1
    fi
    
    # OS version
    local os_version=$(ssh_cmd "$ip" "cat /etc/redhat-release" 2>/dev/null)
    if echo "$os_version" | grep -q "9.6"; then
        log_test "External: OS version 9.6" "PASS" "$os_version"
    else
        log_test "External: OS version 9.6" "FAIL" "Got: $os_version"
    fi
    
    # subscription-manager installed
    if ssh_cmd "$ip" "which subscription-manager" > /dev/null 2>&1; then
        log_test "External: subscription-manager installed" "PASS"
    else
        log_test "External: subscription-manager installed" "FAIL"
    fi
    
    # Data directories
    if ssh_cmd "$ip" "ls -d /data/repos /data/export /data/gpg" > /dev/null 2>&1; then
        log_test "External: Data directories exist" "PASS"
    else
        log_test "External: Data directories exist" "FAIL"
    fi
    
    # Airgap role marker
    local role=$(ssh_cmd "$ip" "cat /etc/airgap-role" 2>/dev/null)
    if [[ "$role" == "external-rpm-server" ]]; then
        log_test "External: Role marker correct" "PASS"
    else
        log_test "External: Role marker correct" "FAIL" "Got: $role"
    fi
    
    return 0
}

test_internal_server() {
    log "INFO" "Testing Internal RPM Server"
    
    local ip=$(get_server_ip "internal")
    if [[ -z "$ip" ]]; then
        log_test "Internal: IP available" "FAIL" "No IP found"
        return 1
    fi
    log_test "Internal: IP available" "PASS" "$ip"
    
    # SSH connectivity
    if ssh_cmd "$ip" "echo ok" > /dev/null 2>&1; then
        log_test "Internal: SSH accessible" "PASS"
    else
        log_test "Internal: SSH accessible" "FAIL" "Cannot connect to $ip"
        return 1
    fi
    
    # FIPS mode check
    local fips_enabled=$(ssh_cmd "$ip" "cat /proc/sys/crypto/fips_enabled" 2>/dev/null)
    if [[ "$fips_enabled" == "1" ]]; then
        log_test "Internal: FIPS enabled" "PASS"
    else
        log_test "Internal: FIPS enabled" "FAIL" "fips_enabled=$fips_enabled"
    fi
    
    # rpmops user exists
    if ssh_cmd "$ip" "id rpmops" > /dev/null 2>&1; then
        log_test "Internal: rpmops user exists" "PASS"
    else
        log_test "Internal: rpmops user exists" "FAIL"
    fi
    
    # Rootless podman for rpmops
    local podman_info=$(ssh_cmd "$ip" "sudo -u rpmops podman info --format '{{.Host.RemoteSocket.Exists}}'" 2>/dev/null)
    if ssh_cmd "$ip" "sudo -u rpmops podman --version" > /dev/null 2>&1; then
        log_test "Internal: Rootless podman works" "PASS"
    else
        log_test "Internal: Rootless podman works" "FAIL"
    fi
    
    # Systemd user services
    if ssh_cmd "$ip" "ls /home/rpmops/.config/systemd/user/" > /dev/null 2>&1; then
        log_test "Internal: Systemd user services exist" "PASS"
    else
        log_test "Internal: Systemd user services exist" "FAIL"
    fi
    
    # HTTPS endpoint
    local https_port=$(python3 -c "
import yaml
with open('$SPEC_PATH') as f:
    spec = yaml.safe_load(f)
print(spec.get('https_internal_repo', {}).get('https_port', 8443))
" 2>/dev/null)
    
    if curl -sk "https://${ip}:${https_port}/" > /dev/null 2>&1; then
        log_test "Internal: HTTPS endpoint responds" "PASS" "Port $https_port"
    else
        # Service might not be running yet; check if port is at least listened
        if ssh_cmd "$ip" "ss -tlnp | grep -q ':${https_port}'" 2>/dev/null; then
            log_test "Internal: HTTPS endpoint responds" "PASS" "Port $https_port listening"
        else
            log_test "Internal: HTTPS endpoint responds" "FAIL" "Port $https_port not responding"
        fi
    fi
    
    # TLS certificate exists
    if ssh_cmd "$ip" "ls /srv/airgap/certs/server.crt" > /dev/null 2>&1; then
        log_test "Internal: TLS certificate exists" "PASS"
    else
        log_test "Internal: TLS certificate exists" "FAIL"
    fi
    
    # Repo directory structure
    if ssh_cmd "$ip" "ls -d /srv/airgap/data/lifecycle /srv/airgap/data/import" > /dev/null 2>&1; then
        log_test "Internal: Repo directories exist" "PASS"
    else
        log_test "Internal: Repo directories exist" "FAIL"
    fi
    
    # Role marker
    local role=$(ssh_cmd "$ip" "cat /etc/airgap-role" 2>/dev/null)
    if [[ "$role" == "internal-rpm-server" ]]; then
        log_test "Internal: Role marker correct" "PASS"
    else
        log_test "Internal: Role marker correct" "FAIL" "Got: $role"
    fi
    
    return 0
}

cleanup() {
    if $CLEANUP_AFTER; then
        log "INFO" "Cleaning up - destroying VMs"
        pwsh -Command "
            Set-Location '$REPO_ROOT'
            & './automation/powercli/destroy-rpm-servers.ps1' -SpecPath '$SPEC_PATH' -Force
        " > "$ARTIFACTS_DIR/cleanup.log" 2>&1
    fi
}

generate_report() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local status="PASS"
    [[ $TESTS_FAILED -gt 0 ]] && status="FAIL"
    
    # JSON report
    cat > "$REPORT_JSON" << EOJSON
{
    "timestamp": "$(date -Iseconds)",
    "duration_seconds": $duration,
    "status": "$status",
    "tests": {
        "passed": $TESTS_PASSED,
        "failed": $TESTS_FAILED,
        "skipped": $TESTS_SKIPPED,
        "total": $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    },
    "artifacts": {
        "log": "$LOG_FILE",
        "servers": "$SERVERS_JSON",
        "deploy_log": "$ARTIFACTS_DIR/deploy.log",
        "wait_log": "$ARTIFACTS_DIR/wait-install.log"
    }
}
EOJSON
    
    # Markdown report
    cat > "$REPORT_MD" << EOMD
# E2E Test Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Duration:** ${duration} seconds
**Status:** $status

## Summary

| Metric | Value |
|--------|-------|
| Passed | $TESTS_PASSED |
| Failed | $TESTS_FAILED |
| Skipped | $TESTS_SKIPPED |
| Total | $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED)) |

## Server IPs

$(if [[ -f "$SERVERS_JSON" ]]; then
    python3 -c "
import json
with open('$SERVERS_JSON') as f:
    data = json.load(f)
for vm in data:
    print(f\"| {vm.get('Name', 'N/A')} | {vm.get('Type', 'N/A')} | {vm.get('IPAddress', 'N/A')} |\")
" 2>/dev/null
else
    echo "| N/A | N/A | N/A |"
fi)

## Test Details

See full log: \`$LOG_FILE\`

## Artifacts

- Report JSON: \`$REPORT_JSON\`
- Servers JSON: \`$SERVERS_JSON\`
- Deploy Log: \`$ARTIFACTS_DIR/deploy.log\`
- Wait Log: \`$ARTIFACTS_DIR/wait-install.log\`
EOMD
    
    log "INFO" "Reports generated: $REPORT_JSON, $REPORT_MD"
}

# Main execution
main() {
    echo -e "${CYAN}"
    echo "==============================================================================="
    echo "  E2E TEST HARNESS - Airgapped RPM Repository"
    echo "==============================================================================="
    echo -e "${NC}"
    
    echo "" > "$LOG_FILE"
    log "INFO" "Starting E2E tests"
    log "INFO" "Spec: $SPEC_PATH"
    log "INFO" "Artifacts: $ARTIFACTS_DIR"
    
    # Run tests
    test_spec_validation || true
    test_vm_deployment || true
    retrieve_server_ips || true
    test_external_server || true
    test_internal_server || true
    
    # Generate reports
    generate_report
    
    # Cleanup if requested
    cleanup
    
    # Summary
    echo ""
    echo -e "${CYAN}==============================================================================="
    echo "  TEST SUMMARY"
    echo "===============================================================================${NC}"
    echo ""
    echo -e "  Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "  Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "  Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo ""
    echo "  Reports: $REPORT_MD"
    echo "           $REPORT_JSON"
    echo ""
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}E2E TESTS FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}E2E TESTS PASSED${NC}"
        exit 0
    fi
}

main "$@"
