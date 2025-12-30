#!/bin/bash
# generate_ckl.sh - Generate STIG checklist deliverables
#
# This script generates STIG Viewer-compatible checklist files from
# OpenSCAP evaluation results.
#
# Usage:
#   ./generate_ckl.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common/logging.sh"

# Configuration
COMPLIANCE_DIR="${PROJECT_ROOT}/compliance"
XCCDF_DIR="${COMPLIANCE_DIR}/xccdf"
CKL_DIR="${COMPLIANCE_DIR}/ckl"

# Input file
XCCDF_FILE=""
AUTO_DETECT=true

# Output formats
OUTPUT_FORMAT="all"  # ckl, csv, json, all

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME=$(hostname)

usage() {
    cat << 'EOF'
Generate STIG Checklist Deliverables

Generates STIG Viewer-compatible checklist files from OpenSCAP
evaluation results.

Usage:
  ./generate_ckl.sh [options]

Options:
  --xccdf FILE         Input XCCDF results file (auto-detected if not specified)
  --format FORMAT      Output format: ckl, csv, json, all (default: all)
  --output-dir DIR     Output directory (default: compliance/ckl/)
  -h, --help           Show this help message

Output Files:
  compliance/ckl/
    checklist-HOSTNAME-TIMESTAMP.ckl    STIG Viewer XML format
    checklist-HOSTNAME-TIMESTAMP.csv    CSV format for spreadsheets
    checklist-HOSTNAME-TIMESTAMP.json   JSON format for automation

Examples:
  # Generate from latest XCCDF results
  ./generate_ckl.sh

  # Generate from specific XCCDF file
  ./generate_ckl.sh --xccdf compliance/xccdf/xccdf-server1-20240115.xml

  # Generate only CSV format
  ./generate_ckl.sh --format csv

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --xccdf)
                XCCDF_FILE="$2"
                AUTO_DETECT=false
                shift 2
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --output-dir)
                CKL_DIR="$2"
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

find_latest_xccdf() {
    local latest
    latest=$(find "${XCCDF_DIR}" -name "xccdf-*.xml" -type f \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    if [[ -z "${latest}" ]]; then
        log_error "No XCCDF results found in ${XCCDF_DIR}"
        log_error "Run OpenSCAP evaluation first: make openscap"
        exit 1
    fi

    echo "${latest}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ "${AUTO_DETECT}" == "true" ]]; then
        XCCDF_FILE=$(find_latest_xccdf)
        log_info "Using latest XCCDF: ${XCCDF_FILE}"
    fi

    if [[ ! -f "${XCCDF_FILE}" ]]; then
        log_error "XCCDF file not found: ${XCCDF_FILE}"
        exit 1
    fi

    # Check for XML tools
    if ! command -v python3 &>/dev/null; then
        log_error "python3 required for checklist generation"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

ensure_directories() {
    mkdir -p "${CKL_DIR}"
}

parse_xccdf_results() {
    local xccdf_file="$1"

    log_info "Parsing XCCDF results..."

    python3 << PYTHON
import xml.etree.ElementTree as ET
import json
import sys

# Namespace handling
ns = {
    'xccdf': 'http://checklists.nist.gov/xccdf/1.2',
    'xccdf11': 'http://checklists.nist.gov/xccdf/1.1',
    'oval': 'http://oval.mitre.org/XMLSchema/oval-results-5',
    'cpe': 'http://cpe.mitre.org/language/2.0'
}

def get_text(element, default=''):
    if element is not None and element.text:
        return element.text.strip()
    return default

def parse_results(xccdf_file):
    try:
        tree = ET.parse(xccdf_file)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"Error parsing XML: {e}", file=sys.stderr)
        return []

    results = []

    # Try both XCCDF 1.2 and 1.1 namespaces
    for prefix in ['xccdf:', 'xccdf11:', '']:
        rule_results = root.findall(f'.//{prefix}rule-result', ns) if prefix else \
                       root.findall('.//rule-result')
        if rule_results:
            break

    for rule_result in rule_results:
        idref = rule_result.get('idref', '')
        severity = rule_result.get('severity', 'medium')

        result_elem = rule_result.find('result', ns) or \
                      rule_result.find(f'{{{ns.get("xccdf", "")}}}result') or \
                      rule_result.find('.//result')

        result = get_text(result_elem, 'unknown')

        # Map result to STIG status
        status_map = {
            'pass': 'NotAFinding',
            'fail': 'Open',
            'notapplicable': 'Not_Applicable',
            'notchecked': 'Not_Reviewed',
            'error': 'Open',
            'unknown': 'Not_Reviewed',
            'informational': 'Not_Reviewed',
            'fixed': 'NotAFinding'
        }
        status = status_map.get(result.lower(), 'Not_Reviewed')

        # Severity mapping
        severity_map = {
            'high': 'high',
            'medium': 'medium',
            'low': 'low',
            'unknown': 'medium'
        }
        cat_severity = severity_map.get(severity.lower(), 'medium')

        results.append({
            'rule_id': idref,
            'vuln_id': '',  # Would need STIG mapping
            'title': idref.replace('xccdf_org.ssgproject.content_rule_', '').replace('_', ' ').title(),
            'severity': cat_severity,
            'result': result,
            'status': status,
            'finding_details': f'Automated check result: {result}',
            'comments': 'Evaluated by OpenSCAP'
        })

    return results

results = parse_results('${xccdf_file}')
print(json.dumps(results, indent=2))
PYTHON
}

generate_ckl_xml() {
    local results_json="$1"
    local output_file="${CKL_DIR}/checklist-${HOSTNAME}-${TIMESTAMP}.ckl"

    log_info "Generating CKL XML..."

    python3 << PYTHON
import json
import xml.etree.ElementTree as ET
from xml.dom import minidom

results = json.loads('''${results_json}''')

# Create CKL structure
checklist = ET.Element('CHECKLIST')

# Asset information
asset = ET.SubElement(checklist, 'ASSET')
ET.SubElement(asset, 'ROLE').text = 'None'
ET.SubElement(asset, 'ASSET_TYPE').text = 'Computing'
ET.SubElement(asset, 'HOST_NAME').text = '${HOSTNAME}'
ET.SubElement(asset, 'HOST_IP').text = ''
ET.SubElement(asset, 'HOST_MAC').text = ''
ET.SubElement(asset, 'HOST_FQDN').text = '${HOSTNAME}'
ET.SubElement(asset, 'TARGET_COMMENT').text = ''
ET.SubElement(asset, 'TECH_AREA').text = ''
ET.SubElement(asset, 'TARGET_KEY').text = ''
ET.SubElement(asset, 'WEB_OR_DATABASE').text = 'false'
ET.SubElement(asset, 'WEB_DB_SITE').text = ''
ET.SubElement(asset, 'WEB_DB_INSTANCE').text = ''

# STIG information
stigs = ET.SubElement(checklist, 'STIGS')
istig = ET.SubElement(stigs, 'iSTIG')

stig_info = ET.SubElement(istig, 'STIG_INFO')
si_data = ET.SubElement(stig_info, 'SI_DATA')
ET.SubElement(si_data, 'SID_NAME').text = 'version'
ET.SubElement(si_data, 'SID_DATA').text = '1'

si_data = ET.SubElement(stig_info, 'SI_DATA')
ET.SubElement(si_data, 'SID_NAME').text = 'title'
ET.SubElement(si_data, 'SID_DATA').text = 'RHEL 9 STIG - OpenSCAP Results'

si_data = ET.SubElement(stig_info, 'SI_DATA')
ET.SubElement(si_data, 'SID_NAME').text = 'releaseinfo'
ET.SubElement(si_data, 'SID_DATA').text = 'Generated from OpenSCAP'

# Vulnerabilities
for i, result in enumerate(results):
    vuln = ET.SubElement(istig, 'VULN')

    # STIG Data
    stig_data = ET.SubElement(vuln, 'STIG_DATA')
    ET.SubElement(stig_data, 'VULN_ATTRIBUTE').text = 'Vuln_Num'
    ET.SubElement(stig_data, 'ATTRIBUTE_DATA').text = f'V-{i+1:05d}'

    stig_data = ET.SubElement(vuln, 'STIG_DATA')
    ET.SubElement(stig_data, 'VULN_ATTRIBUTE').text = 'Severity'
    ET.SubElement(stig_data, 'ATTRIBUTE_DATA').text = result['severity']

    stig_data = ET.SubElement(vuln, 'STIG_DATA')
    ET.SubElement(stig_data, 'VULN_ATTRIBUTE').text = 'Rule_ID'
    ET.SubElement(stig_data, 'ATTRIBUTE_DATA').text = result['rule_id']

    stig_data = ET.SubElement(vuln, 'STIG_DATA')
    ET.SubElement(stig_data, 'VULN_ATTRIBUTE').text = 'Rule_Title'
    ET.SubElement(stig_data, 'ATTRIBUTE_DATA').text = result['title']

    # Status
    ET.SubElement(vuln, 'STATUS').text = result['status']
    ET.SubElement(vuln, 'FINDING_DETAILS').text = result['finding_details']
    ET.SubElement(vuln, 'COMMENTS').text = result['comments']
    ET.SubElement(vuln, 'SEVERITY_OVERRIDE').text = ''
    ET.SubElement(vuln, 'SEVERITY_JUSTIFICATION').text = ''

# Write XML with pretty printing
xml_str = minidom.parseString(ET.tostring(checklist, encoding='unicode')).toprettyxml(indent='  ')
with open('${output_file}', 'w') as f:
    f.write(xml_str)

print('${output_file}')
PYTHON

    log_success "CKL file generated: ${output_file}"
}

generate_csv() {
    local results_json="$1"
    local output_file="${CKL_DIR}/checklist-${HOSTNAME}-${TIMESTAMP}.csv"

    log_info "Generating CSV..."

    python3 << PYTHON
import json
import csv

results = json.loads('''${results_json}''')

with open('${output_file}', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['Rule ID', 'Vuln ID', 'Title', 'Severity', 'Result', 'Status', 'Finding Details', 'Comments'])

    for result in results:
        writer.writerow([
            result['rule_id'],
            result['vuln_id'],
            result['title'],
            result['severity'],
            result['result'],
            result['status'],
            result['finding_details'],
            result['comments']
        ])

print('${output_file}')
PYTHON

    log_success "CSV file generated: ${output_file}"
}

generate_json() {
    local results_json="$1"
    local output_file="${CKL_DIR}/checklist-${HOSTNAME}-${TIMESTAMP}.json"

    log_info "Generating JSON..."

    python3 << PYTHON
import json
from datetime import datetime

results = json.loads('''${results_json}''')

output = {
    'metadata': {
        'hostname': '${HOSTNAME}',
        'generated_at': datetime.utcnow().isoformat() + 'Z',
        'source_file': '${XCCDF_FILE}',
        'total_rules': len(results),
        'summary': {
            'pass': len([r for r in results if r['status'] == 'NotAFinding']),
            'fail': len([r for r in results if r['status'] == 'Open']),
            'not_applicable': len([r for r in results if r['status'] == 'Not_Applicable']),
            'not_reviewed': len([r for r in results if r['status'] == 'Not_Reviewed'])
        }
    },
    'rules': results
}

with open('${output_file}', 'w') as f:
    json.dump(output, f, indent=2)

print('${output_file}')
PYTHON

    log_success "JSON file generated: ${output_file}"
}

generate_summary() {
    local results_json="$1"

    python3 << PYTHON
import json

results = json.loads('''${results_json}''')

pass_count = len([r for r in results if r['status'] == 'NotAFinding'])
fail_count = len([r for r in results if r['status'] == 'Open'])
na_count = len([r for r in results if r['status'] == 'Not_Applicable'])
nr_count = len([r for r in results if r['status'] == 'Not_Reviewed'])

total = len(results)
if total > 0:
    pass_pct = (pass_count / total) * 100
else:
    pass_pct = 0

print(f"""
Checklist Summary
=================
Total Rules:       {total}
Pass (NotAFinding): {pass_count} ({pass_pct:.1f}%)
Fail (Open):        {fail_count}
Not Applicable:     {na_count}
Not Reviewed:       {nr_count}
""")

# High severity failures
high_fails = [r for r in results if r['status'] == 'Open' and r['severity'] == 'high']
if high_fails:
    print(f"HIGH Severity Failures ({len(high_fails)}):")
    for r in high_fails[:10]:
        print(f"  - {r['title']}")
    if len(high_fails) > 10:
        print(f"  ... and {len(high_fails) - 10} more")
PYTHON
}

main() {
    parse_args "$@"

    log_section "Generate STIG Checklist"

    check_prerequisites
    ensure_directories

    # Parse XCCDF results
    local results_json
    results_json=$(parse_xccdf_results "${XCCDF_FILE}")

    if [[ -z "${results_json}" || "${results_json}" == "[]" ]]; then
        log_warn "No results found in XCCDF file"
        results_json="[]"
    fi

    # Generate outputs based on format
    case "${OUTPUT_FORMAT}" in
        ckl)
            generate_ckl_xml "${results_json}"
            ;;
        csv)
            generate_csv "${results_json}"
            ;;
        json)
            generate_json "${results_json}"
            ;;
        all)
            generate_ckl_xml "${results_json}"
            generate_csv "${results_json}"
            generate_json "${results_json}"
            ;;
        *)
            log_error "Unknown format: ${OUTPUT_FORMAT}"
            exit 1
            ;;
    esac

    # Show summary
    generate_summary "${results_json}"

    log_section "Checklist Generation Complete"
    log_info "Output directory: ${CKL_DIR}"

    log_audit "CKL_GENERATED" "Generated checklist from ${XCCDF_FILE}"
}

main "$@"
