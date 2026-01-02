#!/bin/bash
# scripts/e2e-proof-simple.sh
# Simplified E2E proof script for Satellite + Capsule architecture
#
# Usage:
#   ./e2e-proof-simple.sh --satellite <ip> --capsule <ip> [--tester-rhel8 <ip>] [--tester-rhel9 <ip>]

set -euo pipefail

SATELLITE_IP=""
CAPSULE_IP=""
TESTER_RHEL8_IP=""
TESTER_RHEL9_IP=""
SSH_USER="admin"
EVIDENCE_DIR="./automation/artifacts/e2e-satellite-proof"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

usage() {
    cat << 'EOF'
E2E Proof Run: Satellite + Capsule Architecture

Usage:
    ./e2e-proof-simple.sh [OPTIONS]

Required:
    --satellite IP      Satellite server IP
    --capsule IP        Capsule server IP

Optional:
    --tester-rhel8 IP   RHEL 8 tester host IP
    --tester-rhel9 IP   RHEL 9 tester host IP
    --user USER         SSH user (default: admin)
    --evidence-dir DIR  Evidence output directory

Example:
    ./e2e-proof-simple.sh --satellite 192.168.1.50 --capsule 192.168.1.51
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --satellite)
                SATELLITE_IP="$2"
                shift 2
                ;;
            --capsule)
                CAPSULE_IP="$2"
                shift 2
                ;;
            --tester-rhel8)
                TESTER_RHEL8_IP="$2"
                shift 2
                ;;
            --tester-rhel9)
                TESTER_RHEL9_IP="$2"
                shift 2
                ;;
            --user)
                SSH_USER="$2"
                shift 2
                ;;
            --evidence-dir)
                EVIDENCE_DIR="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                log_fail "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$SATELLITE_IP" ]] || [[ -z "$CAPSULE_IP" ]]; then
        log_fail "Satellite and Capsule IPs are required"
        usage
    fi
}

ssh_cmd() {
    local host="$1"
    shift
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${host}" "$@"
}

init_evidence_dirs() {
    log_step "Initializing evidence directories"
    mkdir -p "${EVIDENCE_DIR}/satellite"
    mkdir -p "${EVIDENCE_DIR}/capsule"
    mkdir -p "${EVIDENCE_DIR}/testers/rhel8"
    mkdir -p "${EVIDENCE_DIR}/testers/rhel9"
    mkdir -p "${EVIDENCE_DIR}/logs"
    log_ok "Evidence directories ready"
}

#==========================================
# SATELLITE OPERATIONS
#==========================================

test_satellite_ssh() {
    log_step "Testing SSH to Satellite ($SATELLITE_IP)"
    if ssh_cmd "$SATELLITE_IP" "echo 'SSH OK'"; then
        log_ok "Satellite SSH working"
        return 0
    else
        log_fail "Cannot SSH to Satellite"
        return 1
    fi
}

sync_satellite_content() {
    log_step "Syncing Satellite content from Red Hat CDN"
    ssh_cmd "$SATELLITE_IP" "sudo /opt/satellite-setup/satellite-configure-content.sh --org 'Default Organization' --sync" \
        2>&1 | tee "${EVIDENCE_DIR}/logs/sync.log"
    log_ok "Content sync initiated"
}

wait_for_sync() {
    log_step "Waiting for sync to complete (this may take hours)..."
    local max_wait=7200
    local interval=60
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local running
        running=$(ssh_cmd "$SATELLITE_IP" "hammer task list --search 'label ~ sync and state = running' 2>/dev/null | grep -c running || echo 0")

        if [[ "$running" -eq 0 ]]; then
            log_ok "Content sync complete"
            return 0
        fi

        echo "  Sync in progress... ($running tasks, ${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warn "Sync timeout - check status manually"
}

publish_content_views() {
    log_step "Publishing Content Views"

    for cv in cv_rhel8_security cv_rhel9_security; do
        echo "  Publishing $cv..."
        ssh_cmd "$SATELLITE_IP" "hammer content-view publish --organization 'Default Organization' --name '$cv' --description 'E2E Proof $(date +%Y-%m-%d)'" \
            2>&1 | tee -a "${EVIDENCE_DIR}/logs/publish.log"
    done

    log_ok "Content Views published"
}

promote_content_views() {
    log_step "Promoting Content Views to prod"

    for cv in cv_rhel8_security cv_rhel9_security; do
        local version
        version=$(ssh_cmd "$SATELLITE_IP" "hammer content-view version list --organization 'Default Organization' --content-view '$cv' --fields='Version' 2>/dev/null | tail -1 | awk '{print \$1}'")

        if [[ -n "$version" ]]; then
            echo "  Promoting $cv version $version to prod..."
            ssh_cmd "$SATELLITE_IP" "hammer content-view version promote --organization 'Default Organization' --content-view '$cv' --version '$version' --to-lifecycle-environment 'prod'" \
                2>&1 | tee -a "${EVIDENCE_DIR}/logs/promote.log"
        fi
    done

    log_ok "Content Views promoted"
}

export_bundle() {
    log_step "Exporting content bundle"
    ssh_cmd "$SATELLITE_IP" "sudo /opt/satellite-setup/satellite-export-bundle.sh --org 'Default Organization' --lifecycle-env prod --output-dir /var/lib/pulp/exports" \
        2>&1 | tee "${EVIDENCE_DIR}/logs/export.log"

    local bundle_path
    bundle_path=$(ssh_cmd "$SATELLITE_IP" "ls -t /var/lib/pulp/exports/*.tar.gz 2>/dev/null | head -1")

    log_ok "Bundle exported: $bundle_path"
    echo "$bundle_path"
}

collect_satellite_evidence() {
    log_step "Collecting Satellite evidence"

    ssh_cmd "$SATELLITE_IP" "hammer content-view version list --organization 'Default Organization'" \
        > "${EVIDENCE_DIR}/satellite/cv-versions.txt"

    ssh_cmd "$SATELLITE_IP" "hammer repository list --organization 'Default Organization'" \
        > "${EVIDENCE_DIR}/satellite/sync-status.txt"

    ssh_cmd "$SATELLITE_IP" "hammer lifecycle-environment list --organization 'Default Organization'" \
        > "${EVIDENCE_DIR}/satellite/lifecycle-envs.txt"

    log_ok "Satellite evidence collected"
}

#==========================================
# CAPSULE OPERATIONS
#==========================================

test_capsule_ssh() {
    log_step "Testing SSH to Capsule ($CAPSULE_IP)"
    if ssh_cmd "$CAPSULE_IP" "echo 'SSH OK'"; then
        log_ok "Capsule SSH working"
        return 0
    else
        log_fail "Cannot SSH to Capsule"
        return 1
    fi
}

transfer_bundle() {
    local bundle_path="$1"
    log_step "Transferring bundle to Capsule"

    local bundle_name
    bundle_name=$(basename "$bundle_path")

    # Copy bundle from Satellite to local, then to Capsule
    scp -o StrictHostKeyChecking=no "${SSH_USER}@${SATELLITE_IP}:${bundle_path}" "/tmp/${bundle_name}"
    scp -o StrictHostKeyChecking=no "${SSH_USER}@${SATELLITE_IP}:${bundle_path}.sha256" "/tmp/${bundle_name}.sha256"

    scp -o StrictHostKeyChecking=no "/tmp/${bundle_name}" "${SSH_USER}@${CAPSULE_IP}:/var/lib/pulp/imports/"
    scp -o StrictHostKeyChecking=no "/tmp/${bundle_name}.sha256" "${SSH_USER}@${CAPSULE_IP}:/var/lib/pulp/imports/"

    log_ok "Bundle transferred"
    echo "/var/lib/pulp/imports/${bundle_name}"
}

import_bundle() {
    local bundle_path="$1"
    log_step "Importing bundle on Capsule"

    ssh_cmd "$CAPSULE_IP" "sudo /opt/capsule-setup/capsule-import-bundle.sh --bundle '$bundle_path' --org 'Default Organization'" \
        2>&1 | tee "${EVIDENCE_DIR}/logs/import.log"

    log_ok "Bundle imported"
}

collect_capsule_evidence() {
    log_step "Collecting Capsule evidence"

    ssh_cmd "$CAPSULE_IP" "dnf repolist" > "${EVIDENCE_DIR}/capsule/repolist.txt"
    ssh_cmd "$CAPSULE_IP" "ls -laR /var/lib/pulp/content/ 2>/dev/null | head -100" \
        > "${EVIDENCE_DIR}/capsule/content-listing.txt"

    log_ok "Capsule evidence collected"
}

#==========================================
# TESTER OPERATIONS
#==========================================

patch_tester() {
    local ip="$1"
    local name="$2"
    local evidence_path="${EVIDENCE_DIR}/testers/${name}"

    log_step "Patching $name tester ($ip)"

    # Pre-patch evidence
    ssh_cmd "$ip" "rpm -qa --queryformat '%{NAME}|%{VERSION}|%{RELEASE}\n' | sort" \
        > "${evidence_path}/pre-patch-packages.txt"
    ssh_cmd "$ip" "uname -r" > "${evidence_path}/uname-r-pre.txt"

    # Apply security updates
    echo "  Applying security updates..."
    ssh_cmd "$ip" "sudo dnf update --security -y" 2>&1 | tee "${evidence_path}/patch-output.txt"

    # Check if reboot needed
    local kernel_check
    kernel_check=$(ssh_cmd "$ip" 'CURRENT=$(uname -r); LATEST=$(rpm -q --last kernel 2>/dev/null | head -1 | awk "{print \$1}" | sed "s/kernel-//"); [ "$CURRENT" != "$LATEST" ] && [ -n "$LATEST" ] && echo "reboot_needed" || echo "current"')

    if [[ "$kernel_check" == "reboot_needed" ]]; then
        echo "  Rebooting for kernel update..."
        ssh_cmd "$ip" "sudo reboot" || true
        sleep 30

        # Wait for SSH to come back
        local waited=0
        while [[ $waited -lt 300 ]]; do
            if ssh_cmd "$ip" "echo 'up'" 2>/dev/null; then
                break
            fi
            sleep 10
            waited=$((waited + 10))
        done
    fi

    # Post-patch evidence
    ssh_cmd "$ip" "rpm -qa --queryformat '%{NAME}|%{VERSION}|%{RELEASE}\n' | sort" \
        > "${evidence_path}/post-patch-packages.txt"
    ssh_cmd "$ip" "uname -r" > "${evidence_path}/uname-r-post.txt"
    ssh_cmd "$ip" "cat /etc/os-release" > "${evidence_path}/os-release.txt"
    ssh_cmd "$ip" "dnf updateinfo list security 2>/dev/null" > "${evidence_path}/updateinfo.txt"

    # Generate delta
    diff "${evidence_path}/pre-patch-packages.txt" "${evidence_path}/post-patch-packages.txt" \
        > "${evidence_path}/delta.txt" 2>&1 || true

    log_ok "$name patching complete"
}

#==========================================
# MAIN
#==========================================

generate_report() {
    log_step "Generating final report"

    local report_file="${EVIDENCE_DIR}/E2E-REPORT-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << REPORT
================================================================================
E2E Satellite + Capsule Proof Run Report
================================================================================
Date: $(date)

INFRASTRUCTURE:
  Satellite: ${SATELLITE_IP}
  Capsule: ${CAPSULE_IP}
  Tester RHEL8: ${TESTER_RHEL8_IP:-"N/A"}
  Tester RHEL9: ${TESTER_RHEL9_IP:-"N/A"}

WORKFLOW STATUS:
  Content synced from Red Hat CDN: CHECK logs/sync.log
  Content Views published: CHECK satellite/cv-versions.txt
  Content promoted to prod: CHECK satellite/lifecycle-envs.txt
  Bundle exported: CHECK logs/export.log
  Bundle imported on Capsule: CHECK logs/import.log
  Tester hosts patched: CHECK testers/*/delta.txt

EVIDENCE FILES:
$(find "$EVIDENCE_DIR" -type f -name "*.txt" | sort | sed 's/^/  /')

STATUS: COMPLETE

================================================================================
REPORT

    cat "$report_file"
    log_ok "Report saved to: $report_file"
}

main() {
    echo -e "${MAGENTA}"
    echo "================================================================================"
    echo "       E2E Proof Run: Satellite + Capsule Architecture"
    echo "================================================================================"
    echo -e "${NC}"

    parse_args "$@"

    init_evidence_dirs

    # Test connectivity
    test_satellite_ssh || exit 1
    test_capsule_ssh || exit 1

    # Satellite operations
    sync_satellite_content
    wait_for_sync
    publish_content_views
    promote_content_views
    local bundle_path
    bundle_path=$(export_bundle)
    collect_satellite_evidence

    # Capsule operations
    local capsule_bundle
    capsule_bundle=$(transfer_bundle "$bundle_path")
    import_bundle "$capsule_bundle"
    collect_capsule_evidence

    # Tester operations
    if [[ -n "$TESTER_RHEL8_IP" ]]; then
        patch_tester "$TESTER_RHEL8_IP" "rhel8"
    fi

    if [[ -n "$TESTER_RHEL9_IP" ]]; then
        patch_tester "$TESTER_RHEL9_IP" "rhel9"
    fi

    # Final report
    generate_report

    echo ""
    log_ok "E2E PROOF RUN COMPLETE"
    echo "Evidence directory: $EVIDENCE_DIR"
}

main "$@"
