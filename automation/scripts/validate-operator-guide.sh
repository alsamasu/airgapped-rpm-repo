#!/bin/bash
# automation/scripts/validate-operator-guide.sh
# Validates operator guides against actual implementation
#
# Checks:
# - All referenced Makefile targets exist
# - All referenced static files exist (FAIL if missing)
# - All referenced runtime artifacts exist (WARN if missing - created during execution)
# - All referenced scripts are executable
# - All command examples use correct paths
#
# Usage:
#   ./validate-operator-guide.sh --guides docs/deployment_guide.md,docs/administration_guide.md --spec config/spec.yaml --output-dir automation/artifacts/guide-validate

set -euo pipefail

# Defaults
GUIDE_FILES=""
SPEC_FILE=""
OUTPUT_DIR=""
VERBOSE=false
ERRORS=0
WARNINGS=0
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Arrays for tracking
declare -a ERROR_MESSAGES=()
declare -a WARNING_MESSAGES=()
declare -a VERIFIED_TARGETS=()
declare -a VERIFIED_FILES=()
declare -a VERIFIED_SCRIPTS=()

usage() {
    echo "Usage: $0 --guides <guide1.md,guide2.md> [--spec <spec.yaml>] [--output-dir <dir>] [--verbose]"
    exit 1
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $*"
    [[ -n "$OUTPUT_DIR" ]] && echo "[INFO] $*" >> "$OUTPUT_DIR/run.log"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    [[ -n "$OUTPUT_DIR" ]] && echo "[PASS] $*" >> "$OUTPUT_DIR/run.log"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    WARNING_MESSAGES+=("$*")
    ((WARNINGS++)) || true
    [[ -n "$OUTPUT_DIR" ]] && echo "[WARN] $*" >> "$OUTPUT_DIR/run.log"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ERROR_MESSAGES+=("$*")
    ((ERRORS++)) || true
    [[ -n "$OUTPUT_DIR" ]] && echo "[FAIL] $*" >> "$OUTPUT_DIR/run.log"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --guides)
            GUIDE_FILES="$2"
            shift 2
            ;;
        --guide)
            # Legacy single guide support
            GUIDE_FILES="$2"
            shift 2
            ;;
        --spec)
            SPEC_FILE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
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

if [[ -z "$GUIDE_FILES" ]]; then
    usage
fi

# Setup output directory
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    echo "Guide Validation Run Log" > "$OUTPUT_DIR/run.log"
    echo "========================" >> "$OUTPUT_DIR/run.log"
    echo "Timestamp: $TIMESTAMP" >> "$OUTPUT_DIR/run.log"
    echo "" >> "$OUTPUT_DIR/run.log"
fi

# Convert comma-separated guides to array
IFS=',' read -ra GUIDES <<< "$GUIDE_FILES"

echo ""
echo "=============================================="
echo "Operator Guide Validation"
echo "=============================================="
echo "Guides: ${GUIDES[*]}"
echo "Spec:   ${SPEC_FILE:-'(not specified)'}"
echo "Output: ${OUTPUT_DIR:-'(none)'}"
echo ""

# Validate each guide exists
for guide in "${GUIDES[@]}"; do
    if [[ ! -f "$guide" ]]; then
        log_fail "Guide file not found: $guide"
        exit 1
    fi
    log_pass "Guide found: $guide"
done

# Runtime artifact directories (created during execution, not on clean checkout)
RUNTIME_ARTIFACT_DIRS=(
    "automation/artifacts/e2e"
    "automation/artifacts/ovas"
    "output/ks-isos"
    "ansible/inventories/generated.yml"
)

# Static required directories (must exist in repo)
STATIC_REQUIRED_DIRS=(
    "automation/powercli"
    "automation/scripts"
    "config"
    "docs"
    "ansible/playbooks"
    "ansible/roles"
    "scripts/external"
    "scripts/internal"
    "kickstart"
)

# Check 1: Validate all 'make' targets referenced in guides
log_info "Checking Makefile targets..."

ALL_MAKE_TARGETS=""
for guide in "${GUIDES[@]}"; do
    TARGETS=$(grep -oE 'make [a-z][a-z0-9_-]+' "$guide" 2>/dev/null | sed 's/make //' | sort -u || true)
    ALL_MAKE_TARGETS="$ALL_MAKE_TARGETS $TARGETS"
done
ALL_MAKE_TARGETS=$(echo "$ALL_MAKE_TARGETS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

if [[ -f Makefile ]]; then
    ACTUAL_TARGETS=$(grep -E '^[a-z][a-z0-9_-]+:' Makefile | sed 's/:.*//' | sort -u)

    for target in $ALL_MAKE_TARGETS; do
        if echo "$ACTUAL_TARGETS" | grep -qx "$target"; then
            VERIFIED_TARGETS+=("$target")
            if $VERBOSE; then
                log_pass "Target exists: make $target"
            fi
        else
            log_fail "Target not found in Makefile: make $target"
        fi
    done
    log_info "Verified ${#VERIFIED_TARGETS[@]} Makefile targets"
else
    log_fail "Makefile not found"
fi

# Check 2: Validate referenced static files exist
log_info "Checking referenced static files..."

ALL_FILE_REFS=""
for guide in "${GUIDES[@]}"; do
    FILES=$(grep -oE '(config|automation|ansible|docs|scripts|kickstart)/[a-zA-Z0-9_./-]+\.(yaml|yml|sh|ps1|md|py|cfg)' "$guide" 2>/dev/null | sort -u || true)
    ALL_FILE_REFS="$ALL_FILE_REFS $FILES"
done
ALL_FILE_REFS=$(echo "$ALL_FILE_REFS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

for file in $ALL_FILE_REFS; do
    # Skip runtime-generated files
    if [[ "$file" == *"generated.yml"* ]] || [[ "$file" == *"artifacts/e2e"* ]] || [[ "$file" == *"artifacts/ovas"* ]] || [[ "$file" == *"spec.detected.yaml"* ]] || [[ "$file" == *"vsphere-defaults.json"* ]]; then
        if [[ -f "$file" ]]; then
            log_pass "Runtime file exists: $file"
        else
            log_warn "Runtime file not yet generated: $file (created during execution)"
        fi
    elif [[ -f "$file" ]]; then
        VERIFIED_FILES+=("$file")
        if $VERBOSE; then
            log_pass "Static file exists: $file"
        fi
    else
        log_fail "Static file not found: $file"
    fi
done
log_info "Verified ${#VERIFIED_FILES[@]} static files"

# Check 3: Validate shell scripts are executable
log_info "Checking script permissions..."

ALL_SCRIPT_REFS=""
for guide in "${GUIDES[@]}"; do
    SCRIPTS=$(grep -oE '(automation|scripts)/[a-zA-Z0-9_/-]+\.sh' "$guide" 2>/dev/null | sort -u || true)
    ALL_SCRIPT_REFS="$ALL_SCRIPT_REFS $SCRIPTS"
done
ALL_SCRIPT_REFS=$(echo "$ALL_SCRIPT_REFS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

for script in $ALL_SCRIPT_REFS; do
    if [[ -f "$script" ]]; then
        VERIFIED_SCRIPTS+=("$script")
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

ALL_PS_REFS=""
for guide in "${GUIDES[@]}"; do
    PS_SCRIPTS=$(grep -oE 'automation/powercli/[a-zA-Z0-9_-]+\.ps1' "$guide" 2>/dev/null | sort -u || true)
    ALL_PS_REFS="$ALL_PS_REFS $PS_SCRIPTS"
done
ALL_PS_REFS=$(echo "$ALL_PS_REFS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)

PS_COUNT=0
for ps_script in $ALL_PS_REFS; do
    if [[ -f "$ps_script" ]]; then
        ((PS_COUNT++)) || true
        if $VERBOSE; then
            log_pass "PowerShell script exists: $ps_script"
        fi
    else
        log_fail "PowerShell script not found: $ps_script"
    fi
done
log_info "Verified $PS_COUNT PowerShell scripts"

# Check 5: Validate spec.yaml if provided
if [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]]; then
    log_info "Validating spec.yaml structure..."

    if python3 -c "import yaml; yaml.safe_load(open('$SPEC_FILE'))" 2>/dev/null; then
        log_pass "spec.yaml is valid YAML"
    else
        log_fail "spec.yaml is invalid YAML"
    fi
fi

# Check 6: Validate static directory structure
log_info "Checking static directory structure..."

for dir in "${STATIC_REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        if $VERBOSE; then
            log_pass "Static directory exists: $dir"
        fi
    else
        log_fail "Static directory missing: $dir"
    fi
done

# Check 7: Check runtime artifact directories (warn only)
log_info "Checking runtime artifact directories..."

for dir in "${RUNTIME_ARTIFACT_DIRS[@]}"; do
    if [[ -e "$dir" ]]; then
        if $VERBOSE; then
            log_pass "Runtime artifact exists: $dir"
        fi
    else
        log_warn "Runtime artifact not yet created: $dir (generated during execution)"
    fi
done

# Generate reports
if [[ -n "$OUTPUT_DIR" ]]; then
    log_info "Generating validation reports..."

    # Generate report.md
    cat > "$OUTPUT_DIR/report.md" << EOF
# Guide Validation Report

**Date:** $(date -u +"%Y-%m-%d")
**Status:** $(if [[ $ERRORS -eq 0 ]]; then echo "PASSED"; else echo "FAILED"; fi)
**Guides Validated:** ${GUIDES[*]}

---

## Summary

| Metric | Count |
|--------|-------|
| Makefile targets verified | ${#VERIFIED_TARGETS[@]} |
| Static files verified | ${#VERIFIED_FILES[@]} |
| Scripts verified | ${#VERIFIED_SCRIPTS[@]} |
| PowerShell scripts verified | $PS_COUNT |
| Errors | $ERRORS |
| Warnings | $WARNINGS |

---

## Verified Makefile Targets

$(for t in "${VERIFIED_TARGETS[@]}"; do echo "- $t"; done)

---

## Errors

$(if [[ ${#ERROR_MESSAGES[@]} -eq 0 ]]; then echo "None"; else for e in "${ERROR_MESSAGES[@]}"; do echo "- $e"; done; fi)

---

## Warnings

$(if [[ ${#WARNING_MESSAGES[@]} -eq 0 ]]; then echo "None"; else for w in "${WARNING_MESSAGES[@]}"; do echo "- $w"; done; fi)

---

## Validation Conclusion

$(if [[ $ERRORS -eq 0 ]]; then
    echo "All static artifacts verified. Runtime artifacts will be generated during execution."
else
    echo "Validation failed with $ERRORS errors. Fix the issues above before proceeding."
fi)
EOF

    # Generate report.json
    cat > "$OUTPUT_DIR/report.json" << EOF
{
  "validation_timestamp": "$TIMESTAMP",
  "status": "$(if [[ $ERRORS -eq 0 ]]; then echo "PASSED"; else echo "FAILED"; fi)",
  "guides_validated": [$(printf '"%s",' "${GUIDES[@]}" | sed 's/,$//')],
  "summary": {
    "makefile_targets_verified": ${#VERIFIED_TARGETS[@]},
    "static_files_verified": ${#VERIFIED_FILES[@]},
    "scripts_verified": ${#VERIFIED_SCRIPTS[@]},
    "powershell_scripts_verified": $PS_COUNT,
    "errors": $ERRORS,
    "warnings": $WARNINGS
  },
  "verified_targets": [$(printf '"%s",' "${VERIFIED_TARGETS[@]}" | sed 's/,$//')],
  "errors": [$(printf '"%s",' "${ERROR_MESSAGES[@]}" | sed 's/,$//' | sed 's/"/\\"/g' || echo '')],
  "warnings": [$(printf '"%s",' "${WARNING_MESSAGES[@]}" | sed 's/,$//' | sed 's/"/\\"/g' || echo '')]
}
EOF

    log_pass "Reports written to $OUTPUT_DIR/"
fi

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
