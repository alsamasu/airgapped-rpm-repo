#!/bin/bash
# run_openscap.sh - Run OpenSCAP evaluation against RHEL 9 STIG profile
#
# This script runs an OpenSCAP evaluation on the internal publisher VM
# and generates compliance reports in multiple formats.
#
# Usage:
#   ./run_openscap.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common/logging.sh"

# Configuration
COMPLIANCE_DIR="${PROJECT_ROOT}/compliance"
ARF_DIR="${COMPLIANCE_DIR}/arf"
XCCDF_DIR="${COMPLIANCE_DIR}/xccdf"
HTML_DIR="${COMPLIANCE_DIR}/html"

# OpenSCAP configuration
SCAP_SECURITY_GUIDE="/usr/share/xml/scap/ssg/content"
DATASTREAM="ssg-rhel9-ds.xml"
PROFILE="xccdf_org.ssgproject.content_profile_stig"

# Alternative profiles
PROFILE_STIG="xccdf_org.ssgproject.content_profile_stig"
PROFILE_STIG_GUI="xccdf_org.ssgproject.content_profile_stig_gui"
PROFILE_CIS="xccdf_org.ssgproject.content_profile_cis"
PROFILE_OSPP="xccdf_org.ssgproject.content_profile_ospp"

# Output files
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname)
ARF_FILE="arf-${HOSTNAME}-${TIMESTAMP}.xml"
XCCDF_FILE="xccdf-${HOSTNAME}-${TIMESTAMP}.xml"
HTML_FILE="report-${HOSTNAME}-${TIMESTAMP}.html"

usage() {
    cat << 'EOF'
Run OpenSCAP Evaluation

Runs an OpenSCAP evaluation against the RHEL 9 STIG profile and
generates compliance reports.

Usage:
  ./run_openscap.sh [options]

Options:
  --profile PROFILE    SCAP profile to evaluate (default: stig)
                       Available: stig, stig_gui, cis, ospp
  --rhel8              Use RHEL 8 datastream instead of RHEL 9
  --output-dir DIR     Output directory (default: compliance/)
  --remediate          Apply automatic remediations (CAUTION)
  --dry-run            Show what would be evaluated without running
  -h, --help           Show this help message

Output Files:
  compliance/arf/      ARF (Asset Reporting Format) XML results
  compliance/xccdf/    XCCDF XML results
  compliance/html/     Human-readable HTML reports

Examples:
  # Run STIG evaluation
  ./run_openscap.sh

  # Run CIS evaluation
  ./run_openscap.sh --profile cis

  # RHEL 8 STIG evaluation
  ./run_openscap.sh --rhel8

EOF
}

REMEDIATE=false
DRY_RUN=false
RHEL_VERSION="9"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                case "$2" in
                    stig) PROFILE="${PROFILE_STIG}" ;;
                    stig_gui) PROFILE="${PROFILE_STIG_GUI}" ;;
                    cis) PROFILE="${PROFILE_CIS}" ;;
                    ospp) PROFILE="${PROFILE_OSPP}" ;;
                    *) PROFILE="$2" ;;
                esac
                shift 2
                ;;
            --rhel8)
                RHEL_VERSION="8"
                DATASTREAM="ssg-rhel8-ds.xml"
                shift
                ;;
            --output-dir)
                COMPLIANCE_DIR="$2"
                ARF_DIR="${COMPLIANCE_DIR}/arf"
                XCCDF_DIR="${COMPLIANCE_DIR}/xccdf"
                HTML_DIR="${COMPLIANCE_DIR}/html"
                shift 2
                ;;
            --remediate)
                REMEDIATE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for oscap
    if ! command -v oscap &>/dev/null; then
        log_error "oscap not found"
        log_error "Install with: dnf install openscap-scanner"
        exit 1
    fi

    # Check for scap-security-guide
    local datastream_path="${SCAP_SECURITY_GUIDE}/${DATASTREAM}"
    if [[ ! -f "${datastream_path}" ]]; then
        log_error "SCAP Security Guide datastream not found: ${datastream_path}"
        log_error "Install with: dnf install scap-security-guide"
        exit 1
    fi

    # Check for root (required for full evaluation)
    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root - some checks may fail"
    fi

    log_success "Prerequisites check passed"
}

list_profiles() {
    log_info "Available profiles in ${DATASTREAM}:"
    oscap info "${SCAP_SECURITY_GUIDE}/${DATASTREAM}" 2>/dev/null | \
        grep -E "^\s+Id:" | sed 's/.*Id: /  /'
}

ensure_directories() {
    mkdir -p "${ARF_DIR}"
    mkdir -p "${XCCDF_DIR}"
    mkdir -p "${HTML_DIR}"
}

run_evaluation() {
    local datastream_path="${SCAP_SECURITY_GUIDE}/${DATASTREAM}"
    local arf_output="${ARF_DIR}/${ARF_FILE}"
    local xccdf_output="${XCCDF_DIR}/${XCCDF_FILE}"
    local html_output="${HTML_DIR}/${HTML_FILE}"

    log_section "OpenSCAP Evaluation"
    log_info "Datastream: ${DATASTREAM}"
    log_info "Profile: ${PROFILE}"
    log_info "Host: ${HOSTNAME}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN - Would execute:"
        echo "oscap xccdf eval \\"
        echo "  --profile ${PROFILE} \\"
        echo "  --results ${xccdf_output} \\"
        echo "  --results-arf ${arf_output} \\"
        echo "  --report ${html_output} \\"
        echo "  ${datastream_path}"
        return 0
    fi

    log_info "Running evaluation (this may take several minutes)..."

    local oscap_args=(
        xccdf eval
        --profile "${PROFILE}"
        --results "${xccdf_output}"
        --results-arf "${arf_output}"
        --report "${html_output}"
    )

    if [[ "${REMEDIATE}" == "true" ]]; then
        log_warn "Remediation enabled - changes will be applied"
        oscap_args+=(--remediate)
    fi

    oscap_args+=("${datastream_path}")

    local start_time
    start_time=$(date +%s)

    # oscap returns non-zero if any rules fail, so we capture the exit code
    local exit_code=0
    oscap "${oscap_args[@]}" 2>&1 | tee "${COMPLIANCE_DIR}/oscap-output.log" || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "Evaluation completed in ${duration} seconds"

    # Parse results
    parse_results "${xccdf_output}"

    log_success "Results written to:"
    log_info "  ARF:   ${arf_output}"
    log_info "  XCCDF: ${xccdf_output}"
    log_info "  HTML:  ${html_output}"

    return ${exit_code}
}

parse_results() {
    local xccdf_file="$1"

    if [[ ! -f "${xccdf_file}" ]]; then
        log_warn "Cannot parse results - file not found"
        return
    fi

    log_section "Evaluation Summary"

    # Extract statistics using oscap
    local info
    info=$(oscap xccdf generate stats "${xccdf_file}" 2>/dev/null || true)

    if [[ -n "${info}" ]]; then
        echo "${info}"
    else
        # Manual parsing if oscap stats fails
        local pass fail notapplicable notchecked

        pass=$(grep -c 'result="pass"' "${xccdf_file}" 2>/dev/null || echo "0")
        fail=$(grep -c 'result="fail"' "${xccdf_file}" 2>/dev/null || echo "0")
        notapplicable=$(grep -c 'result="notapplicable"' "${xccdf_file}" 2>/dev/null || echo "0")
        notchecked=$(grep -c 'result="notchecked"' "${xccdf_file}" 2>/dev/null || echo "0")

        echo "Pass:           ${pass}"
        echo "Fail:           ${fail}"
        echo "Not Applicable: ${notapplicable}"
        echo "Not Checked:    ${notchecked}"
    fi
}

generate_fix_script() {
    local xccdf_file="${XCCDF_DIR}/${XCCDF_FILE}"
    local fix_script="${COMPLIANCE_DIR}/remediation-${HOSTNAME}-${TIMESTAMP}.sh"

    if [[ ! -f "${xccdf_file}" ]]; then
        log_warn "Cannot generate fix script - no results file"
        return
    fi

    log_info "Generating remediation script..."

    if oscap xccdf generate fix \
        --profile "${PROFILE}" \
        --fix-type bash \
        --output "${fix_script}" \
        "${xccdf_file}" 2>/dev/null; then
        log_success "Remediation script: ${fix_script}"
        log_warn "Review carefully before executing!"
    else
        log_warn "Could not generate remediation script"
    fi
}

create_summary_json() {
    local summary_file="${COMPLIANCE_DIR}/summary-${HOSTNAME}-${TIMESTAMP}.json"
    local xccdf_file="${XCCDF_DIR}/${XCCDF_FILE}"

    cat > "${summary_file}" << SUMMARY
{
    "hostname": "${HOSTNAME}",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "rhel_version": "${RHEL_VERSION}",
    "profile": "${PROFILE}",
    "datastream": "${DATASTREAM}",
    "results": {
        "arf": "${ARF_DIR}/${ARF_FILE}",
        "xccdf": "${XCCDF_DIR}/${XCCDF_FILE}",
        "html": "${HTML_DIR}/${HTML_FILE}"
    },
    "oscap_version": "$(oscap --version | head -1)"
}
SUMMARY

    log_info "Summary: ${summary_file}"
}

main() {
    parse_args "$@"

    log_section "OpenSCAP STIG Evaluation"

    check_prerequisites
    ensure_directories

    # Run evaluation
    local eval_result=0
    run_evaluation || eval_result=$?

    # Generate additional outputs
    generate_fix_script
    create_summary_json

    log_section "Evaluation Complete"

    if [[ ${eval_result} -eq 0 ]]; then
        log_success "All evaluated rules passed"
    elif [[ ${eval_result} -eq 2 ]]; then
        log_warn "Some rules failed - review HTML report for details"
    else
        log_error "Evaluation encountered errors"
    fi

    log_info "View HTML report: ${HTML_DIR}/${HTML_FILE}"

    log_audit "OPENSCAP_EVALUATION" "Profile: ${PROFILE}, Host: ${HOSTNAME}"

    return ${eval_result}
}

main "$@"
