#!/bin/bash
# automation/scripts/validate-operator-guide.sh
# Validates operator guide against actual implementation
#
# Checks:
# - All referenced Makefile targets exist
# - All referenced files exist
# - All referenced scripts are executable
# - All command examples use correct paths
#
# Usage:
#   ./validate-operator-guide.sh --guide docs/operator_guide_automated.md --spec config/spec.yaml

set -euo pipefail

# Defaults
GUIDE_FILE=""
SPEC_FILE=""
VERBOSE=false
ERRORS=0
WARNINGS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 --guide <guide.md> [--spec <spec.yaml>] [--verbose]"
    exit 1
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    ((WARNINGS++)) || true
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((ERRORS++)) || true
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --guide)
            GUIDE_FILE="$2"
            shift 2
            ;;
        --spec)
            SPEC_FILE="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$GUIDE_FILE" ]]; then
    usage
fi

if [[ ! -f "$GUIDE_FILE" ]]; then
    log_fail "Guide file not found: $GUIDE_FILE"
    exit 1
fi

echo ""
echo "=============================================="
echo "Operator Guide Validation"
echo "=============================================="
echo "Guide: $GUIDE_FILE"
echo "Spec:  ${SPEC_FILE:-'(not specified)'}"
echo ""

# Check 1: Validate all 'make' targets referenced in the guide
log_info "Checking Makefile targets..."

# Extract make targets from guide
MAKE_TARGETS=$(grep -oE 'make [a-z][a-z0-9_-]+' "$GUIDE_FILE" | sed 's/make //' | sort -u)

# Get actual Makefile targets
if [[ -f Makefile ]]; then
    ACTUAL_TARGETS=$(grep -E '^[a-z][a-z0-9_-]+:' Makefile | sed 's/:.*//' | sort -u)
    
    for target in $MAKE_TARGETS; do
        if echo "$ACTUAL_TARGETS" | grep -qx "$target"; then
            if $VERBOSE; then
                log_pass "Target exists: make $target"
            fi
        else
            log_fail "Target not found: make $target"
        fi
    done
else
    log_warn "Makefile not found, skipping target validation"
fi

# Check 2: Validate referenced files exist
log_info "Checking referenced files..."

# Extract file paths from guide (common patterns)
FILE_REFS=$(grep -oE '(config|automation|ansible|docs|scripts)/[a-zA-Z0-9_./-]+\.(yaml|yml|sh|ps1|md|py)' "$GUIDE_FILE" | sort -u)

for file in $FILE_REFS; do
    if [[ -f "$file" ]]; then
        if $VERBOSE; then
            log_pass "File exists: $file"
        fi
    else
        log_fail "File not found: $file"
    fi
done

# Check 3: Validate shell scripts are executable
log_info "Checking script permissions..."

SCRIPT_REFS=$(grep -oE '(automation|scripts)/[a-zA-Z0-9_/-]+\.sh' "$GUIDE_FILE" | sort -u)

for script in $SCRIPT_REFS; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            if $VERBOSE; then
                log_pass "Script executable: $script"
            fi
        else
            log_warn "Script not executable: $script (run: chmod +x $script)"
        fi
    fi
done

# Check 4: Validate PowerShell scripts exist
log_info "Checking PowerShell scripts..."

PS_REFS=$(grep -oE 'automation/powercli/[a-zA-Z0-9_-]+\.ps1' "$GUIDE_FILE" | sort -u)

for ps_script in $PS_REFS; do
    if [[ -f "$ps_script" ]]; then
        if $VERBOSE; then
            log_pass "PowerShell script exists: $ps_script"
        fi
    else
        log_fail "PowerShell script not found: $ps_script"
    fi
done

# Check 5: Validate spec.yaml if provided
if [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]]; then
    log_info "Validating spec.yaml structure..."
    
    # Check YAML is valid
    if python3 -c "import yaml; yaml.safe_load(open('$SPEC_FILE'))" 2>/dev/null; then
        log_pass "spec.yaml is valid YAML"
    else
        log_fail "spec.yaml is invalid YAML"
    fi
    
    # Check required keys exist
    REQUIRED_KEYS="vsphere vmware external_server internal_server"
    for key in $REQUIRED_KEYS; do
        if grep -q "^${key}:" "$SPEC_FILE"; then
            if $VERBOSE; then
                log_pass "Required key exists: $key"
            fi
        else
            log_warn "Required key missing: $key"
        fi
    done
fi

# Check 6: Validate directory structure
log_info "Checking directory structure..."

REQUIRED_DIRS=(
    "automation/powercli"
    "automation/scripts"
    "automation/kickstart"
    "automation/artifacts"
    "ansible/playbooks"
    "ansible/roles"
    "config"
    "docs"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        if $VERBOSE; then
            log_pass "Directory exists: $dir"
        fi
    else
        log_fail "Directory missing: $dir"
    fi
done

# Check 7: Validate E2E artifacts directory structure
log_info "Checking E2E artifacts structure..."

E2E_DIRS=(
    "automation/artifacts/e2e"
    "automation/artifacts/ovas"
)

for dir in "${E2E_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        if $VERBOSE; then
            log_pass "Artifact directory exists: $dir"
        fi
    else
        log_warn "Artifact directory missing: $dir (will be created on first run)"
    fi
done

# Summary
echo ""
echo "=============================================="
echo "Validation Summary"
echo "=============================================="
echo -e "Errors:   ${RED}$ERRORS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}Guide validation PASSED${NC}"
    exit 0
else
    echo -e "${RED}Guide validation FAILED${NC}"
    exit 1
fi
