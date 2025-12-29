#!/bin/bash
# entrypoint.sh - Internal publisher container entrypoint
#
# This script initializes the internal publisher container and starts
# the HTTP server for serving repositories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/../common/logging.sh"

# Configuration
DATA_DIR="${RPMSERVER_DATA_DIR:-/data}"
LOG_DIR="${RPMSERVER_LOG_DIR:-/var/log/rpmserver}"
HTTP_PORT="${RPMSERVER_HTTP_PORT:-8080}"
HTTPS_PORT="${RPMSERVER_HTTPS_PORT:-8443}"

log_info "Starting internal publisher..."
log_info "Mode: ${RPMSERVER_MODE:-internal}"
log_info "Data directory: ${DATA_DIR}"
log_info "HTTP port: ${HTTP_PORT}"

# Initialize if needed
if [[ ! -f "${DATA_DIR}/internal.conf" ]]; then
    log_info "Initializing internal publisher environment..."
    "${SCRIPT_DIR}/../../rpmserverctl" init-internal
fi

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

# Configure Apache
configure_apache() {
    log_info "Configuring Apache..."

    # Update port in configuration
    sed -i "s/Listen 8080/Listen ${HTTP_PORT}/" /etc/httpd/conf/httpd.conf 2>/dev/null || true

    # Create custom configuration
    cat > /etc/httpd/conf.d/rpmrepo.conf << APACHE
# Internal RPM Repository Configuration

ServerName localhost

# Aliases for repository paths
Alias /repos ${DATA_DIR}/repos
Alias /lifecycle ${DATA_DIR}/lifecycle
Alias /keys ${DATA_DIR}/keys

# Directory configurations
<Directory "${DATA_DIR}/repos">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
    IndexOptions FancyIndexing HTMLTable VersionSort NameWidth=* DescriptionWidth=*
</Directory>

<Directory "${DATA_DIR}/lifecycle">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
    IndexOptions FancyIndexing HTMLTable VersionSort NameWidth=* DescriptionWidth=*
</Directory>

<Directory "${DATA_DIR}/keys">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Security headers
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"
</IfModule>

# Logging
ErrorLog ${LOG_DIR}/httpd-error.log
CustomLog ${LOG_DIR}/httpd-access.log combined

# Performance
EnableSendfile On
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5
APACHE

    log_info "Apache configured"
}

configure_apache

# Show status
"${SCRIPT_DIR}/../../rpmserverctl" status

log_success "Internal publisher ready"
log_info "Repository URL: http://localhost:${HTTP_PORT}/repos/"
log_info ""
log_info "Available commands:"
log_info "  make import       - Import bundle"
log_info "  make verify       - Verify bundle"
log_info "  make publish      - Publish to channel"
log_info "  make promote      - Promote between channels"

# Start Apache in foreground
log_info "Starting HTTP server on port ${HTTP_PORT}..."
exec /usr/sbin/httpd -DFOREGROUND
