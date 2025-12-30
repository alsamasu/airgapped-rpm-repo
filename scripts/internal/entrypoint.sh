#!/bin/bash
# entrypoint.sh - Internal publisher container entrypoint
#
# This script initializes the internal publisher container and starts
# the HTTP server for serving repositories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions if available
if [[ -f "${SCRIPT_DIR}/../common/logging.sh" ]]; then
    source "${SCRIPT_DIR}/../common/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[OK] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
fi

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LOG_DIR="${RPMSERVER_LOG_DIR:-/var/log/rpmserver}"
HTTP_PORT="${RPMSERVER_HTTP_PORT:-8080}"
HTTPS_PORT="${RPMSERVER_HTTPS_PORT:-8443}"

log_info "Starting internal publisher..."
log_info "Mode: ${RPMSERVER_MODE:-internal}"
log_info "Data directory: ${DATA_DIR}"
log_info "HTTP port: ${HTTP_PORT}"

# Create required directories
mkdir -p "${LOG_DIR}"
mkdir -p "${DATA_DIR}/repos"
mkdir -p "${DATA_DIR}/lifecycle/dev"
mkdir -p "${DATA_DIR}/lifecycle/prod"
mkdir -p "${DATA_DIR}/keys"

# Create index.html for web root
create_index_html() {
    local repos_dir="${DATA_DIR}/repos"
    local index_file="${repos_dir}/index.html"

    cat > "${index_file}" << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Internal RPM Repository</title>
    <style>
        body { font-family: monospace; margin: 40px; }
        h1 { color: #333; }
        .section { margin: 20px 0; padding: 20px; background: #f5f5f5; }
        a { color: #0066cc; }
        ul { list-style-type: none; padding-left: 0; }
        li { padding: 5px 0; }
    </style>
</head>
<body>
    <h1>Internal RPM Repository</h1>
    <div class="section">
        <h2>Lifecycle Channels</h2>
        <ul>
            <li><a href="/lifecycle/dev/">Development (dev)</a></li>
            <li><a href="/lifecycle/prod/">Production (prod)</a></li>
        </ul>
    </div>
    <div class="section">
        <h2>GPG Keys</h2>
        <ul>
            <li><a href="/keys/RPM-GPG-KEY-internal">RPM-GPG-KEY-internal</a></li>
        </ul>
    </div>
    <div class="section">
        <h2>Direct Repository Access</h2>
        <ul>
            <li><a href="/repos/">Browse All Repositories</a></li>
        </ul>
    </div>
</body>
</html>
HTML

    log_info "Created index.html"
}

create_index_html

# Ensure SSL certificates exist (generate self-signed if missing)
ensure_ssl_certificates() {
    local cert_file="/etc/pki/tls/certs/localhost.crt"
    local key_file="/etc/pki/tls/private/localhost.key"

    # Check if SSL config exists
    if [[ ! -f /etc/httpd/conf.d/ssl.conf ]]; then
        log_info "SSL module not configured, skipping certificate check"
        return 0
    fi

    # Check if certificates already exist and are valid
    if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
        if [[ -s "${cert_file}" && -s "${key_file}" ]]; then
            log_info "SSL certificates already exist"
            return 0
        fi
    fi

    log_info "Generating self-signed SSL certificate..."

    # Create directories if needed
    mkdir -p /etc/pki/tls/certs /etc/pki/tls/private

    # Generate self-signed certificate (valid for 365 days)
    if command -v openssl &>/dev/null; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${key_file}" \
            -out "${cert_file}" \
            -subj "/C=US/ST=Internal/L=Internal/O=RPM Repository/OU=IT/CN=localhost" \
            2>/dev/null

        if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
            chmod 600 "${key_file}"
            chmod 644 "${cert_file}"
            log_success "Self-signed SSL certificate generated"
            return 0
        else
            log_warn "Failed to generate SSL certificate, disabling SSL"
        fi
    else
        log_warn "OpenSSL not available, disabling SSL"
    fi

    # If we couldn't generate certificates, disable SSL
    rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.modules.d/00-ssl.conf 2>/dev/null || true
    log_info "SSL disabled"
}

ensure_ssl_certificates

# Configure Apache
configure_apache() {
    log_info "Configuring Apache..."

    # Update port in configuration
    sed -i "s/Listen 8080/Listen ${HTTP_PORT}/" /etc/httpd/conf/httpd.conf 2>/dev/null || true

    # Add ServerName to avoid warning
    if ! grep -q "^ServerName" /etc/httpd/conf/httpd.conf; then
        echo "ServerName localhost" >> /etc/httpd/conf/httpd.conf
    fi

    # Update logging configuration in repos.conf (if exists)
    # Don't create duplicate Alias directives - they're already in repos.conf from Dockerfile
    if [[ -f /etc/httpd/conf.d/repos.conf ]]; then
        # Just add logging configuration
        cat >> /etc/httpd/conf.d/repos.conf << APACHE

# Runtime logging configuration
ErrorLog ${LOG_DIR}/httpd-error.log
CustomLog ${LOG_DIR}/httpd-access.log combined
APACHE
    fi

    log_info "Apache configured"
}

configure_apache

log_success "Internal publisher ready"
log_info "Repository URL: http://localhost:${HTTP_PORT}/repos/"

# Start Apache in foreground
log_info "Starting HTTP server on port ${HTTP_PORT}..."
exec /usr/sbin/httpd -DFOREGROUND
