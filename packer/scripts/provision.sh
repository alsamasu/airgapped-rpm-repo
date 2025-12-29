#!/bin/bash
# provision.sh - Packer provisioning script for internal publisher VM
#
# This script is run by Packer to configure the internal publisher VM.

set -euo pipefail

echo "=== Starting provisioning ==="
echo "Build Version: ${BUILD_VERSION:-unknown}"
echo "Build Timestamp: ${BUILD_TIMESTAMP:-unknown}"

# Install additional packages
echo "Installing additional packages..."
dnf install -y \
    createrepo_c \
    httpd \
    mod_ssl \
    python3 \
    python3-pip \
    python3-dnf \
    jq \
    podman \
    skopeo

# Create application directories
echo "Creating application directories..."
mkdir -p /opt/rpmserver/{scripts,src,docs}
mkdir -p /data/{bundles,repos,lifecycle,keys,client-config,staging}
mkdir -p /data/bundles/{incoming,verified,archive}
mkdir -p /data/lifecycle/{dev,prod}
mkdir -p /var/log/rpmserver

# Copy scripts from Packer file provisioner
if [[ -d /tmp/packer-scripts ]]; then
    echo "Copying provisioning scripts..."
    cp -r /tmp/packer-scripts/* /opt/rpmserver/scripts/ 2>/dev/null || true
fi

# Load container image if provided
if [[ -f /tmp/container-image.tar ]]; then
    echo "Loading container image..."
    podman load -i /tmp/container-image.tar
else
    echo "No container image provided, skipping..."
fi

# Create rpmserver user
if ! id rpmserver &>/dev/null; then
    useradd -r -m -d /opt/rpmserver -s /sbin/nologin rpmserver
fi

# Set permissions
chown -R rpmserver:rpmserver /opt/rpmserver
chown -R rpmserver:rpmserver /data
chown -R rpmserver:rpmserver /var/log/rpmserver

# Configure Apache for internal publisher
echo "Configuring Apache..."
cat > /etc/httpd/conf.d/rpmrepo.conf << 'APACHE'
# Internal RPM Repository Configuration

ServerName localhost

# Aliases
Alias /repos /data/repos
Alias /lifecycle /data/lifecycle
Alias /keys /data/keys

# Directory configurations
<Directory "/data/repos">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
    IndexOptions FancyIndexing HTMLTable VersionSort NameWidth=* DescriptionWidth=*
</Directory>

<Directory "/data/lifecycle">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
    IndexOptions FancyIndexing HTMLTable VersionSort NameWidth=* DescriptionWidth=*
</Directory>

<Directory "/data/keys">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Security headers
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Content-Security-Policy "default-src 'self'"

# Logging
ErrorLog /var/log/rpmserver/httpd-error.log
CustomLog /var/log/rpmserver/httpd-access.log combined
APACHE

# Update httpd port to 8080 (non-privileged)
sed -i 's/Listen 80/Listen 8080/' /etc/httpd/conf/httpd.conf

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/rpmserver.service << 'SERVICE'
[Unit]
Description=Internal RPM Repository Publisher
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
WorkingDirectory=/opt/rpmserver
ExecStart=/usr/sbin/httpd -DFOREGROUND
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable rpmserver.service

# Create initialization script
cat > /opt/rpmserver/init.sh << 'INIT'
#!/bin/bash
# First-boot initialization script

set -euo pipefail

DATA_DIR="/data"

# Initialize lifecycle channels
for channel in dev prod; do
    meta_file="${DATA_DIR}/lifecycle/${channel}/metadata.json"
    if [[ ! -f "${meta_file}" ]]; then
        mkdir -p "$(dirname "${meta_file}")"
        cat > "${meta_file}" << META
{
    "channel": "${channel}",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "current_bundle": null,
    "history": []
}
META
    fi
done

# Create default index.html
cat > "${DATA_DIR}/repos/index.html" << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Internal RPM Repository</title>
    <style>
        body { font-family: monospace; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 20px; }
        h1 { color: #333; }
        a { color: #0066cc; }
        ul { list-style-type: none; padding-left: 0; }
        li { padding: 10px; margin: 5px 0; background: #f9f9f9; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Internal RPM Repository</h1>
        <h2>Lifecycle Channels</h2>
        <ul>
            <li><a href="/lifecycle/dev/">Development (dev)</a></li>
            <li><a href="/lifecycle/prod/">Production (prod)</a></li>
        </ul>
        <h2>Resources</h2>
        <ul>
            <li><a href="/keys/">GPG Keys</a></li>
            <li><a href="/repos/">All Repositories</a></li>
        </ul>
    </div>
</body>
</html>
HTML

echo "Initialization complete"
INIT

chmod +x /opt/rpmserver/init.sh

# Run initialization
/opt/rpmserver/init.sh

# Configure SELinux
echo "Configuring SELinux..."
setsebool -P httpd_read_user_content 1
semanage fcontext -a -t httpd_sys_content_t "/data(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_log_t "/var/log/rpmserver(/.*)?" 2>/dev/null || true
restorecon -Rv /data /var/log/rpmserver 2>/dev/null || true

# Create build info file
cat > /opt/rpmserver/BUILD_INFO << INFO
Build Version: ${BUILD_VERSION:-unknown}
Build Timestamp: ${BUILD_TIMESTAMP:-unknown}
Build Host: $(hostname)
RHEL Version: $(cat /etc/redhat-release)
INFO

echo "=== Provisioning complete ==="
