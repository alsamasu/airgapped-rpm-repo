#!/bin/bash
# scripts/satellite/satellite-configure-content.sh
# Configure Satellite content: enable repositories, sync from CDN
#
# Usage:
#   ./satellite-configure-content.sh --org "Default Organization"
#
# This script:
#   1. Enables RHEL 8 and RHEL 9 repository sets
#   2. Synchronizes repositories from Red Hat CDN
#   3. Creates Content Views with security-only filters
#   4. Publishes and promotes Content Views

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-/var/log/satellite-setup}"
ORG_NAME="Default Organization"

# Repository configuration
RHEL8_RELEASEVER="8.10"
RHEL9_RELEASEVER="9.6"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*"; }

usage() {
    cat << 'EOF'
Satellite Content Configuration Script

Usage:
    ./satellite-configure-content.sh [OPTIONS]

Options:
    --org NAME              Organization name (default: Default Organization)
    --rhel8-release VER     RHEL 8 release version (default: 8.10)
    --rhel9-release VER     RHEL 9 release version (default: 9.6)
    --sync                  Sync repositories after enabling
    --create-cv             Create Content Views after sync
    --help                  Show this help

Example:
    ./satellite-configure-content.sh --org "MyOrg" --sync --create-cv
EOF
    exit 1
}

DO_SYNC=false
DO_CREATE_CV=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --org)
                ORG_NAME="$2"
                shift 2
                ;;
            --rhel8-release)
                RHEL8_RELEASEVER="$2"
                shift 2
                ;;
            --rhel9-release)
                RHEL9_RELEASEVER="$2"
                shift 2
                ;;
            --sync)
                DO_SYNC=true
                shift
                ;;
            --create-cv)
                DO_CREATE_CV=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

enable_rhel8_repos() {
    log_step "Enabling RHEL 8 repositories..."

    local product="Red Hat Enterprise Linux for x86_64"

    # Enable RHEL 8 BaseOS
    log_info "Enabling RHEL 8 BaseOS..."
    hammer repository-set enable \
        --organization "$ORG_NAME" \
        --product "$product" \
        --name "Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)" \
        --releasever "$RHEL8_RELEASEVER" \
        --basearch "x86_64" 2>/dev/null || log_info "RHEL 8 BaseOS already enabled"

    # Enable RHEL 8 AppStream
    log_info "Enabling RHEL 8 AppStream..."
    hammer repository-set enable \
        --organization "$ORG_NAME" \
        --product "$product" \
        --name "Red Hat Enterprise Linux 8 for x86_64 - AppStream (RPMs)" \
        --releasever "$RHEL8_RELEASEVER" \
        --basearch "x86_64" 2>/dev/null || log_info "RHEL 8 AppStream already enabled"

    log_info "RHEL 8 repositories enabled"
}

enable_rhel9_repos() {
    log_step "Enabling RHEL 9 repositories..."

    local product="Red Hat Enterprise Linux for x86_64"

    # Enable RHEL 9 BaseOS
    log_info "Enabling RHEL 9 BaseOS..."
    hammer repository-set enable \
        --organization "$ORG_NAME" \
        --product "$product" \
        --name "Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)" \
        --releasever "$RHEL9_RELEASEVER" \
        --basearch "x86_64" 2>/dev/null || log_info "RHEL 9 BaseOS already enabled"

    # Enable RHEL 9 AppStream
    log_info "Enabling RHEL 9 AppStream..."
    hammer repository-set enable \
        --organization "$ORG_NAME" \
        --product "$product" \
        --name "Red Hat Enterprise Linux 9 for x86_64 - AppStream (RPMs)" \
        --releasever "$RHEL9_RELEASEVER" \
        --basearch "x86_64" 2>/dev/null || log_info "RHEL 9 AppStream already enabled"

    log_info "RHEL 9 repositories enabled"
}

list_enabled_repos() {
    log_step "Listing enabled repositories..."

    hammer repository list \
        --organization "$ORG_NAME" \
        --fields="Id,Name,Content Type,Sync State"
}

sync_repositories() {
    log_step "Synchronizing repositories from Red Hat CDN..."
    log_warn "This may take several hours depending on network speed."

    local product="Red Hat Enterprise Linux for x86_64"

    # Sync entire product (all enabled repos)
    hammer product synchronize \
        --organization "$ORG_NAME" \
        --name "$product" \
        --async

    log_info "Sync started in background. Monitor with:"
    log_info "  hammer sync-plan list --organization '$ORG_NAME'"
    log_info "  hammer task list --search 'label ~ sync'"
}

wait_for_sync() {
    log_step "Waiting for repository sync to complete..."

    local max_wait=14400  # 4 hours
    local interval=60
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local running
        running=$(hammer task list --search 'label ~ sync and state = running' 2>/dev/null | grep -c "running" || echo 0)

        if [[ "$running" -eq 0 ]]; then
            log_info "All sync tasks completed"
            return 0
        fi

        log_info "Sync in progress... ($running tasks running, ${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warn "Sync timeout after ${max_wait}s. Check task status manually."
}

create_content_view_rhel8() {
    log_step "Creating RHEL 8 Security Content View..."

    local cv_name="cv_rhel8_security"
    local product="Red Hat Enterprise Linux for x86_64"

    # Create Content View
    hammer content-view create \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --description "RHEL 8 Security Updates Only" 2>/dev/null || log_info "CV $cv_name already exists"

    # Add repositories to Content View
    log_info "Adding RHEL 8 repositories to Content View..."

    hammer content-view add-repository \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --product "$product" \
        --repository "Red Hat Enterprise Linux 8 for x86_64 - BaseOS RPMs ${RHEL8_RELEASEVER}" 2>/dev/null || true

    hammer content-view add-repository \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --product "$product" \
        --repository "Red Hat Enterprise Linux 8 for x86_64 - AppStream RPMs ${RHEL8_RELEASEVER}" 2>/dev/null || true

    # Create security errata filter (inclusion filter)
    log_info "Creating security errata filter..."

    hammer content-view filter create \
        --organization "$ORG_NAME" \
        --content-view "$cv_name" \
        --name "security_errata_only" \
        --type "erratum" \
        --inclusion true 2>/dev/null || log_info "Filter already exists"

    hammer content-view filter rule create \
        --organization "$ORG_NAME" \
        --content-view "$cv_name" \
        --content-view-filter "security_errata_only" \
        --types "security" 2>/dev/null || log_info "Filter rule already exists"

    log_info "RHEL 8 Security Content View created"
}

create_content_view_rhel9() {
    log_step "Creating RHEL 9 Security Content View..."

    local cv_name="cv_rhel9_security"
    local product="Red Hat Enterprise Linux for x86_64"

    # Create Content View
    hammer content-view create \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --description "RHEL 9 Security Updates Only" 2>/dev/null || log_info "CV $cv_name already exists"

    # Add repositories to Content View
    log_info "Adding RHEL 9 repositories to Content View..."

    hammer content-view add-repository \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --product "$product" \
        --repository "Red Hat Enterprise Linux 9 for x86_64 - BaseOS RPMs ${RHEL9_RELEASEVER}" 2>/dev/null || true

    hammer content-view add-repository \
        --organization "$ORG_NAME" \
        --name "$cv_name" \
        --product "$product" \
        --repository "Red Hat Enterprise Linux 9 for x86_64 - AppStream RPMs ${RHEL9_RELEASEVER}" 2>/dev/null || true

    # Create security errata filter
    log_info "Creating security errata filter..."

    hammer content-view filter create \
        --organization "$ORG_NAME" \
        --content-view "$cv_name" \
        --name "security_errata_only" \
        --type "erratum" \
        --inclusion true 2>/dev/null || log_info "Filter already exists"

    hammer content-view filter rule create \
        --organization "$ORG_NAME" \
        --content-view "$cv_name" \
        --content-view-filter "security_errata_only" \
        --types "security" 2>/dev/null || log_info "Filter rule already exists"

    log_info "RHEL 9 Security Content View created"
}

publish_content_views() {
    log_step "Publishing Content Views..."

    for cv in cv_rhel8_security cv_rhel9_security; do
        log_info "Publishing $cv..."
        hammer content-view publish \
            --organization "$ORG_NAME" \
            --name "$cv" \
            --description "Initial publish $(date +%Y-%m-%d)" \
            --async
    done

    log_info "Content View publish tasks started"
}

promote_to_test() {
    log_step "Promoting Content Views to test environment..."

    for cv in cv_rhel8_security cv_rhel9_security; do
        # Get latest version
        local version
        version=$(hammer content-view version list \
            --organization "$ORG_NAME" \
            --content-view "$cv" \
            --fields="Version" 2>/dev/null | tail -1 | awk '{print $1}')

        if [[ -n "$version" ]]; then
            log_info "Promoting $cv version $version to test..."
            hammer content-view version promote \
                --organization "$ORG_NAME" \
                --content-view "$cv" \
                --version "$version" \
                --to-lifecycle-environment "test" \
                --async 2>/dev/null || log_warn "Could not promote $cv"
        fi
    done
}

generate_content_report() {
    log_step "Generating content configuration report..."

    local report_file="${LOG_DIR}/content-report-$(date +%Y%m%d-%H%M%S).txt"

    cat > "$report_file" << REPORT
================================================================================
Satellite Content Configuration Report
================================================================================
Date: $(date)
Organization: ${ORG_NAME}

Enabled Repositories:
$(hammer repository list --organization "$ORG_NAME" 2>/dev/null || echo "Could not list")

Content Views:
$(hammer content-view list --organization "$ORG_NAME" 2>/dev/null || echo "Could not list")

Content View Versions:
$(hammer content-view version list --organization "$ORG_NAME" 2>/dev/null || echo "Could not list")

Lifecycle Environments:
$(hammer lifecycle-environment list --organization "$ORG_NAME" 2>/dev/null || echo "Could not list")

================================================================================
REPORT

    log_info "Report saved to: $report_file"
}

main() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "${LOG_DIR}/content-configure-$(date +%Y%m%d-%H%M%S).log") 2>&1

    parse_args "$@"

    log_info "Configuring Satellite content for organization: $ORG_NAME"

    enable_rhel8_repos
    enable_rhel9_repos
    list_enabled_repos

    if [[ "$DO_SYNC" == "true" ]]; then
        sync_repositories
        wait_for_sync
    else
        log_info "Skipping sync (use --sync to enable)"
    fi

    if [[ "$DO_CREATE_CV" == "true" ]]; then
        create_content_view_rhel8
        create_content_view_rhel9
        publish_content_views
        promote_to_test
    else
        log_info "Skipping Content View creation (use --create-cv to enable)"
    fi

    generate_content_report

    log_info "Content configuration complete!"
}

main "$@"
