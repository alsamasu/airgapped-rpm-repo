#!/bin/bash
# publish_repos.sh - Publish repositories to lifecycle channel
#
# This script publishes verified bundles to a lifecycle channel
# (dev or prod) for serving to internal hosts.
#
# Usage:
#   ./publish_repos.sh <lifecycle_channel>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
BUNDLES_DIR="${DATA_DIR}/bundles"
VERIFIED_DIR="${BUNDLES_DIR}/verified"
LIFECYCLE_DIR="${DATA_DIR}/lifecycle"
REPOS_DIR="${DATA_DIR}/repos"
KEYS_DIR="${DATA_DIR}/keys"

LIFECYCLE=""
BUNDLE_NAME=""
FORCE=false

usage() {
    cat << 'EOF'
Publish Repositories to Lifecycle Channel

Publishes verified bundles to a lifecycle channel for serving
to internal hosts.

Usage:
  ./publish_repos.sh <lifecycle> [options]

Arguments:
  lifecycle            Channel to publish to (dev or prod)

Options:
  --bundle BUNDLE      Specific bundle to publish (default: latest)
  --force              Force publish even if bundle is already published
  -h, --help           Show this help message

Lifecycle Channels:
  dev    - Development/testing channel
  prod   - Production channel

Examples:
  # Publish latest bundle to dev
  ./publish_repos.sh dev

  # Publish specific bundle to prod
  ./publish_repos.sh prod --bundle security-update-2024-01-15-001

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)
                BUNDLE_NAME="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "${LIFECYCLE}" ]]; then
                    LIFECYCLE="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${LIFECYCLE}" ]]; then
        log_error "Lifecycle channel required"
        usage
        exit 1
    fi

    # Validate lifecycle
    case "${LIFECYCLE}" in
        dev|prod)
            ;;
        *)
            log_error "Invalid lifecycle channel: ${LIFECYCLE}"
            log_error "Valid channels: dev, prod"
            exit 1
            ;;
    esac
}

get_latest_bundle() {
    local latest
    latest=$(find "${VERIFIED_DIR}" -mindepth 1 -maxdepth 1 -type d \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -z "${latest}" ]]; then
        log_error "No verified bundles found"
        exit 1
    fi

    basename "${latest}"
}

check_bundle() {
    local bundle_name="$1"
    local bundle_dir="${VERIFIED_DIR}/${bundle_name}"

    if [[ ! -d "${bundle_dir}" ]]; then
        log_error "Bundle not found: ${bundle_dir}"
        log_error "Verify the bundle first: make verify"
        exit 1
    fi

    if [[ ! -d "${bundle_dir}/repos" ]]; then
        log_error "Bundle does not contain repos directory"
        exit 1
    fi

    log_info "Bundle verified: ${bundle_name}"
}

backup_current() {
    local channel="$1"
    local channel_dir="${LIFECYCLE_DIR}/${channel}"
    local metadata_file="${channel_dir}/metadata.json"

    if [[ -f "${metadata_file}" ]]; then
        local current_bundle
        current_bundle=$(jq -r '.current_bundle // empty' "${metadata_file}")

        if [[ -n "${current_bundle}" ]]; then
            log_info "Current bundle in ${channel}: ${current_bundle}"

            # Archive current state
            local archive_dir="${channel_dir}/.archive"
            mkdir -p "${archive_dir}"

            local archive_name="${current_bundle}-$(date +%Y%m%d%H%M%S)"
            if [[ -d "${channel_dir}/repos" ]]; then
                mv "${channel_dir}/repos" "${archive_dir}/${archive_name}"
                log_info "Archived: ${archive_name}"
            fi
        fi
    fi
}

publish_bundle() {
    local bundle_name="$1"
    local channel="$2"

    local bundle_dir="${VERIFIED_DIR}/${bundle_name}"
    local channel_dir="${LIFECYCLE_DIR}/${channel}"

    log_info "Publishing ${bundle_name} to ${channel}..."

    # Create channel directory
    mkdir -p "${channel_dir}"

    # Backup current
    backup_current "${channel}"

    # Copy repositories
    log_info "Copying repositories..."
    mkdir -p "${channel_dir}/repos"
    rsync -av --delete "${bundle_dir}/repos/" "${channel_dir}/repos/"

    # Copy keys
    if [[ -d "${bundle_dir}/keys" ]]; then
        mkdir -p "${channel_dir}/keys"
        rsync -av "${bundle_dir}/keys/" "${channel_dir}/keys/"
    fi

    # Copy updates if present
    if [[ -d "${bundle_dir}/updates" ]]; then
        mkdir -p "${channel_dir}/updates"
        rsync -av "${bundle_dir}/updates/" "${channel_dir}/updates/"
    fi

    # Update metadata
    update_channel_metadata "${channel}" "${bundle_name}"

    log_success "Published ${bundle_name} to ${channel}"
}

update_channel_metadata() {
    local channel="$1"
    local bundle_name="$2"

    local channel_dir="${LIFECYCLE_DIR}/${channel}"
    local metadata_file="${channel_dir}/metadata.json"

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -f "${metadata_file}" ]]; then
        local current
        current=$(cat "${metadata_file}")

        # Add to history
        local history_entry
        history_entry="{\"bundle\":\"${bundle_name}\",\"published_at\":\"${now}\"}"

        echo "${current}" | jq \
            --arg bundle "${bundle_name}" \
            --arg now "${now}" \
            --argjson entry "${history_entry}" \
            '.current_bundle = $bundle | .last_updated = $now | .history = [$entry] + .history[:9]' \
            > "${metadata_file}"
    else
        cat > "${metadata_file}" << METADATA
{
    "channel": "${channel}",
    "created": "${now}",
    "current_bundle": "${bundle_name}",
    "last_updated": "${now}",
    "history": [
        {
            "bundle": "${bundle_name}",
            "published_at": "${now}"
        }
    ]
}
METADATA
    fi

    log_info "Channel metadata updated"
}

show_channel_status() {
    local channel="$1"
    local channel_dir="${LIFECYCLE_DIR}/${channel}"
    local metadata_file="${channel_dir}/metadata.json"

    echo ""
    log_info "Channel Status: ${channel}"
    echo "=========================================="

    if [[ -f "${metadata_file}" ]]; then
        local current_bundle
        local last_updated
        current_bundle=$(jq -r '.current_bundle' "${metadata_file}")
        last_updated=$(jq -r '.last_updated' "${metadata_file}")

        echo "Current Bundle: ${current_bundle}"
        echo "Last Updated: ${last_updated}"

        # Count repos and packages
        local repo_count=0
        local pkg_count=0

        if [[ -d "${channel_dir}/repos" ]]; then
            repo_count=$(find "${channel_dir}/repos" -name "repomd.xml" | wc -l)
            pkg_count=$(find "${channel_dir}/repos" -name "*.rpm" | wc -l)
        fi

        echo "Repositories: ${repo_count}"
        echo "Packages: ${pkg_count}"

        # Show history
        echo ""
        echo "History:"
        jq -r '.history[:5][] | "  \(.published_at): \(.bundle)"' "${metadata_file}" 2>/dev/null || true
    else
        echo "No metadata found"
    fi
}

main() {
    parse_args "$@"

    log_section "Publish to ${LIFECYCLE}"

    # Get bundle to publish
    if [[ -z "${BUNDLE_NAME}" ]]; then
        BUNDLE_NAME=$(get_latest_bundle)
        log_info "Using latest bundle: ${BUNDLE_NAME}"
    fi

    # Verify bundle exists
    check_bundle "${BUNDLE_NAME}"

    # Check if already published
    local metadata_file="${LIFECYCLE_DIR}/${LIFECYCLE}/metadata.json"
    if [[ -f "${metadata_file}" && "${FORCE}" != "true" ]]; then
        local current_bundle
        current_bundle=$(jq -r '.current_bundle // empty' "${metadata_file}")

        if [[ "${current_bundle}" == "${BUNDLE_NAME}" ]]; then
            log_warn "Bundle ${BUNDLE_NAME} is already published to ${LIFECYCLE}"
            log_info "Use --force to republish"
            exit 0
        fi
    fi

    # Publish
    publish_bundle "${BUNDLE_NAME}" "${LIFECYCLE}"

    # Show status
    show_channel_status "${LIFECYCLE}"

    log_audit "BUNDLE_PUBLISHED" "Published ${BUNDLE_NAME} to ${LIFECYCLE}"

    log_success "Publication complete"

    if [[ "${LIFECYCLE}" == "dev" ]]; then
        log_info "Next step: Test, then make promote FROM=dev TO=prod"
    fi
}

main "$@"
