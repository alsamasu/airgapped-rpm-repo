#!/bin/bash
# host_collect_manifest.sh - Collect host manifest for airgapped RPM repository
#
# This script runs on RHEL 8.10 and 9.6 hosts to collect package and system
# information for the external builder to compute updates.
#
# Output: A portable manifest bundle directory and tar.gz archive
#
# Usage:
#   ./host_collect_manifest.sh [options]
#
# Options:
#   -o, --output-dir DIR    Output directory (default: /tmp/manifest-HOSTNAME-DATE)
#   -i, --host-id ID        Host identifier (default: machine-id)
#   -s, --include-services  Include running/enabled services (default: off)
#   -h, --help              Show this help message
#
# This script is READ-ONLY and SAFE to run on production systems.

set -euo pipefail

# Script metadata
SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="host_collect_manifest.sh"

# Default configuration
OUTPUT_DIR=""
HOST_ID=""
INCLUDE_SERVICES=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

usage() {
    cat << 'EOF'
Host Manifest Collection Script

Collects package and system information from RHEL 8.10/9.6 hosts for the
airgapped RPM repository system. This script is READ-ONLY and safe to run
on production systems.

Usage:
  ./host_collect_manifest.sh [options]

Options:
  -o, --output-dir DIR     Output directory (default: /tmp/manifest-HOSTNAME-DATE)
  -i, --host-id ID         Host identifier (default: /etc/machine-id)
  -s, --include-services   Include running/enabled services list (default: off)
  -v, --verbose            Verbose output
  -h, --help               Show this help message

Output Files:
  manifest.json            Main manifest file with all collected data
  packages.txt             Raw rpm -qa output in parseable format
  os-release.txt           Copy of /etc/os-release
  repos.txt                Enabled repository list
  dnf-history.txt          DNF history summary
  services.txt             Running/enabled services (if -s specified)
  SHA256SUMS               Checksums for all collected files
  README.txt               Instructions for hand-carry

Examples:
  # Basic collection with default settings
  ./host_collect_manifest.sh

  # Custom output directory and host ID
  ./host_collect_manifest.sh -o /mnt/usb/manifests -i webserver-01

  # Include services information
  ./host_collect_manifest.sh -s

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -i|--host-id)
                HOST_ID="$2"
                shift 2
                ;;
            -s|--include-services)
                INCLUDE_SERVICES=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
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

get_machine_id() {
    if [[ -f /etc/machine-id ]]; then
        cat /etc/machine-id
    else
        # Fallback to hostname + random suffix
        echo "$(hostname)-$(date +%s)"
    fi
}

get_os_version() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "${ID:-unknown}-${VERSION_ID:-unknown}"
    else
        echo "unknown"
    fi
}

detect_package_manager() {
    if command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        log_error "No supported package manager found (dnf or yum required)"
        exit 1
    fi
}

collect_packages() {
    local output_file="$1"
    local json_file="$2"

    log_info "Collecting installed packages..."

    # Get package list with queryformat for maximum information
    # Format: name|epoch|version|release|arch|installtime
    # Note: Epoch may be "(none)" if not set - we handle this
    local query_format='%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}|%{INSTALLTIME}\n'

    rpm -qa --queryformat "${query_format}" | sort > "${output_file}"

    # Count packages
    local pkg_count
    pkg_count=$(wc -l < "${output_file}")
    log_success "Collected ${pkg_count} packages"

    # Convert to JSON array for manifest
    # Handle epoch: "(none)" becomes "0", otherwise keep the value
    local packages_json="["
    local first=true

    while IFS='|' read -r name epoch version release arch installtime; do
        # Skip empty lines
        [[ -z "${name}" ]] && continue

        # Normalize epoch
        if [[ "${epoch}" == "(none)" || -z "${epoch}" ]]; then
            epoch="0"
        fi

        # Build JSON entry
        if [[ "${first}" == "true" ]]; then
            first=false
        else
            packages_json+=","
        fi

        packages_json+=$(cat << PKGJSON
{"name":"${name}","epoch":"${epoch}","version":"${version}","release":"${release}","arch":"${arch}","installtime":${installtime}}
PKGJSON
)
    done < "${output_file}"

    packages_json+="]"

    echo "${packages_json}" > "${json_file}"
}

collect_os_release() {
    local output_file="$1"

    log_info "Collecting OS release information..."

    if [[ -f /etc/os-release ]]; then
        cp /etc/os-release "${output_file}"
    else
        echo "# /etc/os-release not found" > "${output_file}"
    fi

    log_success "OS release information collected"
}

collect_system_info() {
    local output_file="$1"

    log_info "Collecting system information..."

    cat > "${output_file}" << SYSINFO
# System Information
# Collected: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

hostname=$(hostname)
kernel=$(uname -r)
arch=$(uname -m)
processor=$(uname -p)
SYSINFO

    # systemd version if available
    if command -v systemctl &>/dev/null; then
        echo "systemd_version=$(systemctl --version | head -1)" >> "${output_file}"
    fi

    # RHEL subscription status (safe read-only check)
    if command -v subscription-manager &>/dev/null; then
        local sub_status
        sub_status=$(subscription-manager status 2>/dev/null | grep -E "^Overall Status:" | cut -d: -f2 | tr -d ' ' || echo "unknown")
        echo "subscription_status=${sub_status}" >> "${output_file}"
    fi

    log_success "System information collected"
}

collect_repos() {
    local output_file="$1"
    local json_file="$2"
    local pkg_mgr="$3"

    log_info "Collecting enabled repositories..."

    if [[ "${pkg_mgr}" == "dnf" ]]; then
        dnf repolist -v 2>/dev/null > "${output_file}" || \
            dnf repolist 2>/dev/null > "${output_file}" || \
            echo "# Failed to collect repository list" > "${output_file}"
    else
        yum repolist -v 2>/dev/null > "${output_file}" || \
            yum repolist 2>/dev/null > "${output_file}" || \
            echo "# Failed to collect repository list" > "${output_file}"
    fi

    # Extract repo IDs for JSON
    local repos_json="["
    local first=true

    while read -r line; do
        if [[ "${line}" =~ ^Repo-id[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            local repo_id="${BASH_REMATCH[1]}"
            # Remove trailing slash and whitespace
            repo_id="${repo_id%%/}"
            repo_id="${repo_id%% *}"

            if [[ "${first}" == "true" ]]; then
                first=false
            else
                repos_json+=","
            fi
            repos_json+="\"${repo_id}\""
        fi
    done < "${output_file}"

    repos_json+="]"

    # Fallback: parse simple repolist output
    if [[ "${repos_json}" == "[]" ]]; then
        repos_json="["
        first=true
        while read -r line; do
            # Skip header and summary lines
            [[ "${line}" =~ ^repo\ id || "${line}" =~ ^repolist: ]] && continue
            [[ -z "${line}" ]] && continue

            local repo_id
            repo_id=$(echo "${line}" | awk '{print $1}')
            [[ -z "${repo_id}" ]] && continue

            if [[ "${first}" == "true" ]]; then
                first=false
            else
                repos_json+=","
            fi
            repos_json+="\"${repo_id}\""
        done < "${output_file}"
        repos_json+="]"
    fi

    echo "${repos_json}" > "${json_file}"
    log_success "Repository information collected"
}

collect_dnf_history() {
    local output_file="$1"
    local pkg_mgr="$2"

    log_info "Collecting package manager history..."

    if [[ "${pkg_mgr}" == "dnf" ]]; then
        dnf history 2>/dev/null | head -50 > "${output_file}" || \
            echo "# Failed to collect DNF history" > "${output_file}"
    else
        yum history 2>/dev/null | head -50 > "${output_file}" || \
            echo "# Failed to collect YUM history" > "${output_file}"
    fi

    log_success "Package manager history collected"
}

collect_services() {
    local output_file="$1"

    log_info "Collecting services information..."

    if ! command -v systemctl &>/dev/null; then
        echo "# systemctl not available" > "${output_file}"
        return
    fi

    {
        echo "# Running Services"
        systemctl list-units --type=service --state=running --no-pager 2>/dev/null || true
        echo ""
        echo "# Enabled Services"
        systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null || true
    } > "${output_file}"

    log_success "Services information collected"
}

generate_checksums() {
    local manifest_dir="$1"

    log_info "Generating SHA256 checksums..."

    (
        cd "${manifest_dir}"
        find . -type f ! -name "SHA256SUMS" -exec sha256sum {} \; | sort > SHA256SUMS
    )

    log_success "Checksums generated"
}

create_manifest_json() {
    local manifest_dir="$1"
    local host_id="$2"
    local include_services="$3"

    log_info "Creating manifest.json..."

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local os_id=""
    local os_version=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        os_id="${ID:-unknown}"
        os_version="${VERSION_ID:-unknown}"
    fi

    local kernel
    kernel=$(uname -r)

    local arch
    arch=$(uname -m)

    local hostname_val
    hostname_val=$(hostname)

    # Read collected data
    local packages_json
    packages_json=$(cat "${manifest_dir}/packages.json")

    local repos_json
    repos_json=$(cat "${manifest_dir}/repos.json")

    # Create manifest
    cat > "${manifest_dir}/manifest.json" << MANIFEST
{
    "manifest_version": "1.0",
    "script_version": "${SCRIPT_VERSION}",
    "host_id": "${host_id}",
    "hostname": "${hostname_val}",
    "timestamp": "${timestamp}",
    "os_release": {
        "id": "${os_id}",
        "version": "${os_version}"
    },
    "kernel": "${kernel}",
    "arch": "${arch}",
    "packages": ${packages_json},
    "enabled_repos": ${repos_json},
    "include_services": ${include_services}
}
MANIFEST

    # Validate JSON
    if command -v python3 &>/dev/null; then
        if ! python3 -m json.tool "${manifest_dir}/manifest.json" > /dev/null 2>&1; then
            log_warn "Generated manifest.json may have JSON syntax issues"
        fi
    fi

    log_success "manifest.json created"
}

create_readme() {
    local manifest_dir="$1"
    local host_id="$2"

    cat > "${manifest_dir}/README.txt" << README
AIRGAPPED RPM REPOSITORY - HOST MANIFEST
========================================

Host ID: ${host_id}
Collected: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Hostname: $(hostname)
OS: $(get_os_version)

Contents:
---------
- manifest.json    Main manifest file (JSON format)
- packages.txt     Raw package list (rpm -qa output)
- packages.json    Package list in JSON format
- os-release.txt   OS release information
- system-info.txt  System information (kernel, arch, etc.)
- repos.txt        Enabled repository list
- repos.json       Repository list in JSON format
- dnf-history.txt  Package manager history summary
- services.txt     Running/enabled services (if collected)
- SHA256SUMS       Checksums for verification

Instructions:
-------------
1. Transfer this bundle to the external builder via hand-carry media
2. Place in the manifests/incoming directory
3. Run: make ingest MANIFEST_DIR=/path/to/this/directory
4. The external builder will index and process this manifest

Verification:
-------------
To verify file integrity:
  cd /path/to/manifest/directory
  sha256sum -c SHA256SUMS

Security Notes:
---------------
- This manifest contains package inventory only
- No credentials or secrets are included
- No system configurations beyond package list
- Safe for transport on removable media

README
}

create_archive() {
    local manifest_dir="$1"
    local archive_name="$2"

    log_info "Creating archive: ${archive_name}.tar.gz"

    local parent_dir
    parent_dir=$(dirname "${manifest_dir}")
    local dir_name
    dir_name=$(basename "${manifest_dir}")

    (
        cd "${parent_dir}"
        tar -czf "${archive_name}.tar.gz" "${dir_name}"
    )

    log_success "Archive created: ${parent_dir}/${archive_name}.tar.gz"
    echo "${parent_dir}/${archive_name}.tar.gz"
}

main() {
    parse_args "$@"

    log_info "Host Manifest Collection Script v${SCRIPT_VERSION}"
    log_info "=========================================="

    # Set host ID
    if [[ -z "${HOST_ID}" ]]; then
        HOST_ID=$(get_machine_id)
    fi
    log_info "Host ID: ${HOST_ID}"

    # Set output directory
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    if [[ -z "${OUTPUT_DIR}" ]]; then
        OUTPUT_DIR="/tmp/manifest-$(hostname)-${timestamp}"
    fi

    # Create output directory
    mkdir -p "${OUTPUT_DIR}"
    log_info "Output directory: ${OUTPUT_DIR}"

    # Detect package manager
    local pkg_mgr
    pkg_mgr=$(detect_package_manager)
    log_info "Package manager: ${pkg_mgr}"

    # Collect all information
    collect_packages "${OUTPUT_DIR}/packages.txt" "${OUTPUT_DIR}/packages.json"
    collect_os_release "${OUTPUT_DIR}/os-release.txt"
    collect_system_info "${OUTPUT_DIR}/system-info.txt"
    collect_repos "${OUTPUT_DIR}/repos.txt" "${OUTPUT_DIR}/repos.json" "${pkg_mgr}"
    collect_dnf_history "${OUTPUT_DIR}/dnf-history.txt" "${pkg_mgr}"

    if [[ "${INCLUDE_SERVICES}" == "true" ]]; then
        collect_services "${OUTPUT_DIR}/services.txt"
    fi

    # Create main manifest JSON
    create_manifest_json "${OUTPUT_DIR}" "${HOST_ID}" "${INCLUDE_SERVICES}"

    # Create README
    create_readme "${OUTPUT_DIR}" "${HOST_ID}"

    # Generate checksums (must be last)
    generate_checksums "${OUTPUT_DIR}"

    # Create archive
    local archive_name="manifest-${HOST_ID}-${timestamp}"
    local archive_path
    archive_path=$(create_archive "${OUTPUT_DIR}" "${archive_name}")

    # Summary
    echo ""
    log_success "Manifest collection complete!"
    echo ""
    echo "Output directory: ${OUTPUT_DIR}"
    echo "Archive: ${archive_path}"
    echo ""
    echo "Next steps:"
    echo "  1. Transfer the archive to the external builder"
    echo "  2. Run: make ingest MANIFEST_DIR=/path/to/extracted/manifest"
    echo ""
}

main "$@"
