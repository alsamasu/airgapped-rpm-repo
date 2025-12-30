#!/bin/bash
# entrypoint.sh - RPM Publisher container entrypoint
#
# Initializes the container and starts Apache with HTTPS support.
# Handles certificate bootstrap and lifecycle environment setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LOG_DIR="${RPMSERVER_LOG_DIR:-/var/log/rpmserver}"
HTTP_PORT="${RPMSERVER_HTTP_PORT:-8080}"
HTTPS_PORT="${RPMSERVER_HTTPS_PORT:-8443}"
CERT_DIR="${DATA_DIR}/certs"

log_info "Starting RPM Publisher..."
log_info "Mode: ${RPMSERVER_MODE:-internal}"
log_info "Data directory: ${DATA_DIR}"
log_info "HTTP port: ${HTTP_PORT}, HTTPS port: ${HTTPS_PORT}"

# Create required directories
mkdir -p "${LOG_DIR}"
mkdir -p "${DATA_DIR}/repos"
mkdir -p "${DATA_DIR}/lifecycle/testing"
mkdir -p "${DATA_DIR}/lifecycle/stable"
mkdir -p "${DATA_DIR}/bundles/incoming"
mkdir -p "${DATA_DIR}/bundles/processed"
mkdir -p "${DATA_DIR}/keys"
mkdir -p "${CERT_DIR}"

# Ensure SSL certificates exist
ensure_ssl_certificates() {
    local cert_file="${CERT_DIR}/server.crt"
    local key_file="${CERT_DIR}/server.key"

    # Check if certificates already exist and are valid
    if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
        if [[ -s "${cert_file}" && -s "${key_file}" ]]; then
            # Verify certificate is not expired
            if openssl x509 -checkend 86400 -noout -in "${cert_file}" 2>/dev/null; then
                log_info "Valid SSL certificates found"
                return 0
            else
                log_warn "SSL certificate expired or expiring soon, regenerating..."
            fi
        fi
    fi

    log_info "Generating self-signed SSL certificate..."

    # Generate self-signed certificate (valid for 365 days)
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${key_file}" \
        -out "${cert_file}" \
        -subj "/C=US/ST=Internal/L=Internal/O=RPM Repository/OU=IT/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:rpm-publisher,IP:127.0.0.1" \
        2>/dev/null

    if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
        chmod 600 "${key_file}"
        chmod 644 "${cert_file}"
        log_success "Self-signed SSL certificate generated"
        log_info "To replace with CA-signed cert, mount to ${CERT_DIR}/server.crt and ${CERT_DIR}/server.key"
    else
        log_error "Failed to generate SSL certificate"
        exit 1
    fi
}

ensure_ssl_certificates

# Create index page
create_index_html() {
    local index_file="${DATA_DIR}/repos/index.html"
    
    cat > "${index_file}" << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Internal RPM Repository</title>
    <style>
        body { font-family: monospace; margin: 40px; background: #1a1a1a; color: #e0e0e0; }
        h1 { color: #4fc3f7; }
        h2 { color: #81c784; }
        .section { margin: 20px 0; padding: 20px; background: #2d2d2d; border-radius: 8px; }
        a { color: #64b5f6; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul { list-style-type: none; padding-left: 0; }
        li { padding: 8px 0; }
        .env-testing { color: #ffb74d; }
        .env-stable { color: #81c784; }
        code { background: #424242; padding: 2px 6px; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Internal RPM Repository</h1>
    <div class="section">
        <h2>Lifecycle Environments</h2>
        <ul>
            <li class="env-testing"><a href="/lifecycle/testing/">Testing</a> - Newly imported packages, pending validation</li>
            <li class="env-stable"><a href="/lifecycle/stable/">Stable</a> - Validated packages, production ready</li>
        </ul>
    </div>
    <div class="section">
        <h2>GPG Keys</h2>
        <ul>
            <li><a href="/keys/">Browse GPG Keys</a></li>
        </ul>
    </div>
    <div class="section">
        <h2>Repository Configuration</h2>
        <p>Add to <code>/etc/yum.repos.d/internal.repo</code>:</p>
        <pre style="background: #424242; padding: 15px; border-radius: 4px; overflow-x: auto;">
[internal-stable-baseos]
name=Internal Stable - BaseOS
baseurl=https://rpm-publisher:8443/lifecycle/stable/$releasever/$basearch/baseos
enabled=1
gpgcheck=1
gpgkey=https://rpm-publisher:8443/keys/RPM-GPG-KEY-internal
sslverify=1
sslcacert=/etc/pki/tls/certs/internal-ca.crt
        </pre>
    </div>
</body>
</html>
HTML

    log_info "Created index.html"
}

create_index_html

# Create health check file
echo "OK" > "${DATA_DIR}/repos/health.txt"

log_success "RPM Publisher ready"
log_info "HTTP URL: http://localhost:${HTTP_PORT}/"
log_info "HTTPS URL: https://localhost:${HTTPS_PORT}/"

# Start Apache in foreground
log_info "Starting Apache HTTP Server..."
exec /usr/sbin/httpd -DFOREGROUND
