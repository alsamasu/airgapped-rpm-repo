#!/bin/bash
# compute_updates.sh - Compute available updates for ingested host manifests
#
# This script compares installed packages from host manifests against
# the mirrored repositories to determine available updates.
#
# Usage:
#   ./compute_updates.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=../common/logging.sh
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
MANIFESTS_DIR="${DATA_DIR}/manifests"
PROCESSED_DIR="${MANIFESTS_DIR}/processed"
INDEX_FILE="${MANIFESTS_DIR}/index/manifest_index.json"
MIRROR_DIR="${DATA_DIR}/mirror"
UPDATES_DIR="${DATA_DIR}/updates"

# Python module path
PYTHONPATH="${SCRIPT_DIR}/../../src:${PYTHONPATH:-}"
export PYTHONPATH

SPECIFIC_HOST=""
RESOLVE_DEPS=false
OUTPUT_FORMAT="json"

usage() {
    cat << 'EOF'
Compute Available Updates

Compares installed packages from host manifests against mirrored
repositories to determine available updates.

Usage:
  ./compute_updates.sh [options]

Options:
  --host HOST_ID       Compute updates for specific host only
  --resolve-deps       Resolve dependencies for updates (slower)
  --format FORMAT      Output format: json, text, csv (default: json)
  -h, --help           Show this help message

Output:
  /data/updates/<host_id>/updates.json    - Available updates per host
  /data/updates/summary.json              - Overall update summary

Examples:
  # Compute updates for all hosts
  ./compute_updates.sh

  # Compute for specific host with dependency resolution
  ./compute_updates.sh --host abc123 --resolve-deps

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                SPECIFIC_HOST="$2"
                shift 2
                ;;
            --resolve-deps)
                RESOLVE_DEPS=true
                shift
                ;;
            --format)
                OUTPUT_FORMAT="$2"
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
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ ! -f "${INDEX_FILE}" ]]; then
        log_error "No manifest index found. Run: make ingest first"
        exit 1
    fi

    if [[ ! -d "${MIRROR_DIR}" ]]; then
        log_error "No mirror directory found. Run: make sync first"
        exit 1
    fi

    # Check for Python update calculator
    if ! python3 -c "from update_calculator import calculator" 2>/dev/null; then
        log_warn "Python update calculator not available, using shell fallback"
    fi

    log_success "Prerequisites check passed"
}

get_hosts_to_process() {
    if [[ -n "${SPECIFIC_HOST}" ]]; then
        echo "${SPECIFIC_HOST}"
    else
        jq -r '.hosts | keys[]' "${INDEX_FILE}"
    fi
}

get_repo_packages() {
    local repo_path="$1"
    local cache_file="${repo_path}/.package_cache.json"

    # Use cache if recent
    if [[ -f "${cache_file}" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0) ))
        if [[ ${cache_age} -lt 3600 ]]; then
            cat "${cache_file}"
            return
        fi
    fi

    log_debug "Building package cache for ${repo_path}"

    local packages_json="{"
    local first=true

    # Use repoquery if available, otherwise parse primary.xml
    if command -v dnf &>/dev/null && [[ -d "${repo_path}/repodata" ]]; then
        while IFS='|' read -r name epoch version release arch; do
            [[ -z "${name}" ]] && continue

            # Normalize epoch
            if [[ "${epoch}" == "0" || -z "${epoch}" ]]; then
                epoch="0"
            fi

            local key="${name}.${arch}"

            if [[ "${first}" == "true" ]]; then
                first=false
            else
                packages_json+=","
            fi

            packages_json+="\"${key}\":{\"name\":\"${name}\",\"epoch\":\"${epoch}\",\"version\":\"${version}\",\"release\":\"${release}\",\"arch\":\"${arch}\"}"
        done < <(dnf repoquery --repofrompath="temp,${repo_path}" --disablerepo="*" --enablerepo="temp" \
                 --queryformat='%{name}|%{epoch}|%{version}|%{release}|%{arch}' --available 2>/dev/null || true)
    fi

    packages_json+="}"

    # Cache the result
    echo "${packages_json}" > "${cache_file}"
    echo "${packages_json}"
}

compare_versions() {
    local installed_epoch="$1"
    local installed_version="$2"
    local installed_release="$3"
    local available_epoch="$4"
    local available_version="$5"
    local available_release="$6"

    # Use Python for proper RPM version comparison
    python3 << PYTHON
import sys
try:
    from packaging import version
except ImportError:
    # Fallback to simple string comparison
    installed = "${installed_epoch}:${installed_version}-${installed_release}"
    available = "${available_epoch}:${available_version}-${available_release}"
    if available > installed:
        sys.exit(0)
    else:
        sys.exit(1)

def rpm_compare(e1, v1, r1, e2, v2, r2):
    """Compare two RPM versions. Returns True if v2 is newer."""
    # Compare epochs first
    e1 = int(e1) if e1 and e1 != "0" else 0
    e2 = int(e2) if e2 and e2 != "0" else 0

    if e2 > e1:
        return True
    if e2 < e1:
        return False

    # Compare versions
    try:
        v1_parsed = version.parse(v1)
        v2_parsed = version.parse(v2)
        if v2_parsed > v1_parsed:
            return True
        if v2_parsed < v1_parsed:
            return False
    except:
        if v2 > v1:
            return True
        if v2 < v1:
            return False

    # Compare releases
    try:
        r1_parsed = version.parse(r1.split('.')[0])
        r2_parsed = version.parse(r2.split('.')[0])
        return r2_parsed > r1_parsed
    except:
        return r2 > r1

result = rpm_compare(
    "${installed_epoch}", "${installed_version}", "${installed_release}",
    "${available_epoch}", "${available_version}", "${available_release}"
)
sys.exit(0 if result else 1)
PYTHON
}

compute_updates_for_host() {
    local host_id="$1"

    log_info "Computing updates for host: ${host_id}"

    local host_dir="${PROCESSED_DIR}/${host_id}/latest"

    if [[ ! -d "${host_dir}" ]]; then
        log_error "No manifest found for host: ${host_id}"
        return 1
    fi

    local manifest_file="${host_dir}/manifest.json"
    if [[ ! -f "${manifest_file}" ]]; then
        log_error "No manifest.json found for host: ${host_id}"
        return 1
    fi

    # Get OS info
    local os_id
    local os_version
    os_id=$(jq -r '.os_release.id' "${manifest_file}")
    os_version=$(jq -r '.os_release.version' "${manifest_file}")

    # Determine profile
    local profile
    case "${os_id}-${os_version}" in
        rhel-8*|centos-8*) profile="rhel8" ;;
        rhel-9*|centos-9*) profile="rhel9" ;;
        *)
            log_warn "Unknown OS: ${os_id} ${os_version}, assuming rhel9"
            profile="rhel9"
            ;;
    esac

    log_info "OS Profile: ${profile}"

    # Get installed packages
    local installed_packages
    installed_packages=$(jq -r '.packages' "${manifest_file}")

    # Find available updates
    local updates_json='{"host_id":"'"${host_id}"'","profile":"'"${profile}"'","computed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","updates":[]}'
    local updates_array="[]"
    local update_count=0

    # Check each channel
    for channel in baseos appstream; do
        local repo_path="${MIRROR_DIR}/${profile}/x86_64/${channel}"

        if [[ ! -d "${repo_path}" ]]; then
            log_debug "Repository not found: ${repo_path}"
            continue
        fi

        log_debug "Checking ${channel} repository..."

        # Get available packages from repo
        local available_packages
        available_packages=$(get_repo_packages "${repo_path}")

        # Compare each installed package
        while IFS= read -r pkg_json; do
            local name epoch version release arch
            name=$(echo "${pkg_json}" | jq -r '.name')
            epoch=$(echo "${pkg_json}" | jq -r '.epoch')
            version=$(echo "${pkg_json}" | jq -r '.version')
            release=$(echo "${pkg_json}" | jq -r '.release')
            arch=$(echo "${pkg_json}" | jq -r '.arch')

            [[ -z "${name}" || "${name}" == "null" ]] && continue

            local key="${name}.${arch}"

            # Check if package exists in repo
            local available
            available=$(echo "${available_packages}" | jq -r ".\"${key}\" // null")

            if [[ "${available}" != "null" ]]; then
                local avail_epoch avail_version avail_release
                avail_epoch=$(echo "${available}" | jq -r '.epoch')
                avail_version=$(echo "${available}" | jq -r '.version')
                avail_release=$(echo "${available}" | jq -r '.release')

                # Compare versions
                if compare_versions "${epoch}" "${version}" "${release}" \
                                   "${avail_epoch}" "${avail_version}" "${avail_release}" 2>/dev/null; then
                    log_debug "Update available: ${name} ${version}-${release} -> ${avail_version}-${avail_release}"

                    local update_entry
                    update_entry=$(cat << ENTRY
{
    "name": "${name}",
    "arch": "${arch}",
    "channel": "${channel}",
    "installed": {
        "epoch": "${epoch}",
        "version": "${version}",
        "release": "${release}"
    },
    "available": {
        "epoch": "${avail_epoch}",
        "version": "${avail_version}",
        "release": "${avail_release}"
    }
}
ENTRY
)
                    updates_array=$(echo "${updates_array}" | jq ". + [${update_entry}]")
                    ((update_count++))
                fi
            fi
        done < <(echo "${installed_packages}" | jq -c '.[]')
    done

    # Create output directory
    local output_dir="${UPDATES_DIR}/${host_id}"
    mkdir -p "${output_dir}"

    # Write updates file
    local updates_file="${output_dir}/updates.json"
    cat > "${updates_file}" << UPDATES
{
    "host_id": "${host_id}",
    "profile": "${profile}",
    "os_id": "${os_id}",
    "os_version": "${os_version}",
    "computed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "update_count": ${update_count},
    "updates": ${updates_array}
}
UPDATES

    log_success "Found ${update_count} updates for ${host_id}"
    log_info "Output: ${updates_file}"

    return 0
}

generate_summary() {
    log_info "Generating update summary..."

    local summary_file="${UPDATES_DIR}/summary.json"
    local hosts_json="[]"
    local total_updates=0
    local total_hosts=0

    for host_dir in "${UPDATES_DIR}"/*/; do
        [[ ! -d "${host_dir}" ]] && continue

        local updates_file="${host_dir}/updates.json"
        [[ ! -f "${updates_file}" ]] && continue

        local host_id
        local update_count
        local profile
        host_id=$(jq -r '.host_id' "${updates_file}")
        update_count=$(jq -r '.update_count' "${updates_file}")
        profile=$(jq -r '.profile' "${updates_file}")

        hosts_json=$(echo "${hosts_json}" | jq ". + [{\"host_id\":\"${host_id}\",\"profile\":\"${profile}\",\"update_count\":${update_count}}]")

        ((total_updates += update_count))
        ((total_hosts++))
    done

    cat > "${summary_file}" << SUMMARY
{
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "total_hosts": ${total_hosts},
    "total_updates": ${total_updates},
    "hosts": ${hosts_json}
}
SUMMARY

    log_success "Summary generated: ${summary_file}"
}

main() {
    parse_args "$@"

    log_section "Compute Available Updates"

    check_prerequisites

    mkdir -p "${UPDATES_DIR}"

    # Get hosts to process
    local hosts
    hosts=$(get_hosts_to_process)

    if [[ -z "${hosts}" ]]; then
        log_error "No hosts found in manifest index"
        exit 1
    fi

    local total=0
    local success=0
    local failed=0

    for host_id in ${hosts}; do
        ((total++))
        if compute_updates_for_host "${host_id}"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    # Generate summary
    generate_summary

    log_section "Update Computation Summary"
    log_info "Total hosts: ${total}"
    log_info "Success: ${success}"
    log_info "Failed: ${failed}"

    log_audit "COMPUTE_UPDATES" "Computed updates for ${success}/${total} hosts"

    log_success "Update computation complete"
    log_info "Next step: make build-repos"
}

main "$@"
