#!/bin/bash
# automation/scripts/validate-spec.sh
# Validate spec.yaml configuration file
#
# Usage: ./validate-spec.sh [path/to/spec.yaml]
#
# Exit codes:
#   0 - Validation passed
#   1 - Validation failed
#   2 - File not found or parse error

set -euo pipefail

SPEC_PATH="${1:-config/spec.yaml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  Validating spec.yaml"
echo "=========================================="
echo ""

# Resolve path
if [[ ! "$SPEC_PATH" = /* ]]; then
    SPEC_PATH="$REPO_ROOT/$SPEC_PATH"
fi

# Check file exists
if [[ ! -f "$SPEC_PATH" ]]; then
    echo -e "${RED}[FAIL]${NC} File not found: $SPEC_PATH"
    exit 2
fi

echo "File: $SPEC_PATH"
echo ""

# Check for yq or python yaml parser
if command -v yq &> /dev/null; then
    YAML_CMD="yq"
elif command -v python3 &> /dev/null; then
    YAML_CMD="python3"
else
    echo -e "${RED}[FAIL]${NC} Neither 'yq' nor 'python3' found for YAML parsing"
    exit 2
fi

# Function to get YAML value
get_yaml() {
    local path="$1"
    if [[ "$YAML_CMD" == "yq" ]]; then
        yq -r "$path // empty" "$SPEC_PATH" 2>/dev/null || echo ""
    else
        python3 -c "
import yaml
import sys
with open('$SPEC_PATH', 'r') as f:
    data = yaml.safe_load(f)
keys = '$path'.lstrip('.').split('.')
val = data
for k in keys:
    if val is None or not isinstance(val, dict):
        val = None
        break
    val = val.get(k)
print(val if val is not None else '')
" 2>/dev/null || echo ""
    fi
}

# Validation results
ERRORS=()
WARNINGS=()

# Required fields
echo "Checking required fields..."

check_required() {
    local path="$1"
    local desc="$2"
    local value
    value=$(get_yaml "$path")
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        ERRORS+=("$path: $desc is required")
        echo -e "  ${RED}[MISSING]${NC} $path"
        return 1
    else
        echo -e "  ${GREEN}[OK]${NC} $path"
        return 0
    fi
}

check_optional() {
    local path="$1"
    local desc="$2"
    local value
    value=$(get_yaml "$path")
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        WARNINGS+=("$path: $desc (using default)")
        echo -e "  ${YELLOW}[DEFAULT]${NC} $path"
    else
        echo -e "  ${GREEN}[OK]${NC} $path"
    fi
}

echo ""
echo "--- vCenter Configuration ---"
check_required ".vcenter.server" "vCenter/ESXi server address"
check_required ".vcenter.datastore" "Datastore name"
check_optional ".vcenter.datacenter" "Datacenter name"
check_optional ".vcenter.cluster" "Cluster name"

echo ""
echo "--- ISO Configuration ---"
check_required ".isos.rhel96_iso_path" "RHEL 9.6 ISO path"

echo ""
echo "--- VM Names ---"
check_required ".vm_names.rpm_external" "External VM name"
check_required ".vm_names.rpm_internal" "Internal VM name"

echo ""
echo "--- Credentials ---"
check_required ".credentials.initial_root_password" "Initial root password"
check_optional ".credentials.initial_admin_user" "Admin username"
check_optional ".credentials.initial_admin_password" "Admin password"

echo ""
echo "--- Internal Services ---"
check_optional ".internal_services.service_user" "Service user"
check_optional ".internal_services.data_dir" "Data directory"

echo ""
echo "--- HTTPS Configuration ---"
check_optional ".https_internal_repo.https_port" "HTTPS port"
check_optional ".https_internal_repo.http_port" "HTTP port"

echo ""
echo "--- Syslog TLS ---"
check_optional ".syslog_tls.target_host" "Syslog target host"
check_optional ".syslog_tls.target_port" "Syslog target port"

echo ""
echo "--- Ansible ---"
check_optional ".ansible.ssh_username" "SSH username"
check_optional ".ansible.ssh_password" "SSH password"

# Validate password strength (basic check)
echo ""
echo "Checking password requirements..."
ROOT_PASS=$(get_yaml ".credentials.initial_root_password")
if [[ -n "$ROOT_PASS" && ${#ROOT_PASS} -lt 8 ]]; then
    WARNINGS+=("Root password should be at least 8 characters")
    echo -e "  ${YELLOW}[WARN]${NC} Root password is short (< 8 chars)"
else
    echo -e "  ${GREEN}[OK]${NC} Password length"
fi

# Validate ISO path format
echo ""
echo "Checking ISO path..."
ISO_PATH=$(get_yaml ".isos.rhel96_iso_path")
if [[ -n "$ISO_PATH" ]]; then
    if [[ "$ISO_PATH" =~ ^\[.*\] ]]; then
        echo -e "  ${GREEN}[OK]${NC} ISO path is datastore format"
    elif [[ -f "$ISO_PATH" ]]; then
        echo -e "  ${GREEN}[OK]${NC} ISO file exists locally"
    else
        WARNINGS+=("ISO file not found locally: $ISO_PATH")
        echo -e "  ${YELLOW}[WARN]${NC} ISO file not found: $ISO_PATH"
        echo -e "         (May be on remote system or datastore)"
    fi
fi

# Check syslog CA bundle if syslog is configured
SYSLOG_HOST=$(get_yaml ".syslog_tls.target_host")
if [[ -n "$SYSLOG_HOST" && "$SYSLOG_HOST" != "null" ]]; then
    echo ""
    echo "Checking syslog configuration..."
    CA_PATH=$(get_yaml ".syslog_tls.ca_bundle_local_path")
    if [[ -n "$CA_PATH" && "$CA_PATH" != "null" ]]; then
        if [[ -f "$CA_PATH" ]]; then
            echo -e "  ${GREEN}[OK]${NC} Syslog CA bundle exists"
        else
            WARNINGS+=("Syslog CA bundle not found: $CA_PATH")
            echo -e "  ${YELLOW}[WARN]${NC} Syslog CA bundle not found"
        fi
    else
        WARNINGS+=("Syslog is configured but CA bundle path is not set")
        echo -e "  ${YELLOW}[WARN]${NC} Syslog CA bundle path not configured"
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "  Validation Summary"
echo "=========================================="
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "${RED}ERRORS (${#ERRORS[@]}):${NC}"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}WARNINGS (${#WARNINGS[@]}):${NC}"
    for warn in "${WARNINGS[@]}"; do
        echo "  - $warn"
    done
    echo ""
fi

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}Validation PASSED${NC}"
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo "(with ${#WARNINGS[@]} warnings)"
    fi
    exit 0
else
    echo -e "${RED}Validation FAILED${NC}"
    echo "Fix the errors above before proceeding."
    exit 1
fi
