#!/bin/bash
# entrypoint.sh - External builder container entrypoint
#
# This script initializes the external builder container environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LOG_DIR="${RPMSERVER_LOG_DIR:-/var/log/rpmserver}"

log_info "Starting external builder..."
log_info "Mode: ${RPMSERVER_MODE:-external}"
log_info "Data directory: ${DATA_DIR}"

# Initialize if needed
if [[ ! -f "${DATA_DIR}/external.conf" ]]; then
    log_info "Initializing external builder environment..."
    "${SCRIPT_DIR}/../../rpmserverctl" init-external
fi

# Show status
"${SCRIPT_DIR}/../../rpmserverctl" status

log_success "External builder ready"
log_info "Available commands:"
log_info "  make sm-register    - Register with subscription-manager"
log_info "  make enable-repos   - Enable RHEL repositories"
log_info "  make sync           - Sync content from CDN"
log_info "  make ingest         - Ingest host manifests"
log_info "  make compute        - Compute updates"
log_info "  make build-repos    - Build repositories"
log_info "  make export         - Export bundle"

# Keep container running
exec tail -f /dev/null
