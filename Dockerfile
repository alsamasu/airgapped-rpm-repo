# Airgapped RPM Repository Server
# Multi-stage build for both external and internal modes

FROM almalinux:9 AS base

LABEL maintainer="DevSecOps Team"
LABEL description="Airgapped Two-Tier RPM Repository System"
LABEL version="1.0.0"

# Enable CRB repo for createrepo_c and install dependencies
RUN dnf install -y --setopt=tsflags=nodocs dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf install -y --setopt=tsflags=nodocs \
    createrepo_c \
    gnupg2 \
    httpd \
    mod_ssl \
    python3 \
    python3-pip \
    python3-dnf \
    python3-rpm \
    rsync \
    tar \
    gzip \
    xz \
    bzip2 \
    openssh-clients \
    jq \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Create application user
RUN groupadd -r rpmserver && useradd -r -g rpmserver -d /opt/rpmserver -s /sbin/nologin rpmserver

# Create directory structure
RUN mkdir -p /data/mirror \
    /data/manifests \
    /data/bundles \
    /data/repos \
    /data/keys \
    /data/staging \
    /data/lifecycle/dev \
    /data/lifecycle/prod \
    /opt/rpmserver/scripts \
    /opt/rpmserver/src \
    /var/log/rpmserver \
    /run/httpd \
    && chown -R rpmserver:rpmserver /data /opt/rpmserver /var/log/rpmserver

# External builder stage - includes subscription-manager tooling
FROM base AS external

# Install subscription-manager and reposync dependencies
RUN dnf install -y --setopt=tsflags=nodocs \
    subscription-manager \
    yum-utils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Copy scripts for external mode
COPY --chown=rpmserver:rpmserver scripts/common/ /opt/rpmserver/scripts/common/
COPY --chown=rpmserver:rpmserver scripts/external/ /opt/rpmserver/scripts/external/
COPY --chown=rpmserver:rpmserver src/ /opt/rpmserver/src/

# Install Python dependencies
COPY requirements.txt /opt/rpmserver/
RUN pip3 install --no-cache-dir -r /opt/rpmserver/requirements.txt

ENV RPMSERVER_MODE=external
ENV RPMSERVER_DATA_DIR=/data
ENV RPMSERVER_LOG_DIR=/var/log/rpmserver

WORKDIR /opt/rpmserver

USER rpmserver

CMD ["/opt/rpmserver/scripts/external/entrypoint.sh"]

# Internal publisher stage - no subscription-manager, HTTP server focused
FROM base AS internal

# Configure Apache for repository serving
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf \
    && sed -i 's/^Listen 443 https$/Listen 8443 https/' /etc/httpd/conf.d/ssl.conf || true \
    && echo "ServerName localhost" >> /etc/httpd/conf/httpd.conf

# Create Apache configuration for repos
RUN cat > /etc/httpd/conf.d/repos.conf << 'APACHE_CONF'
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

Alias /repos /data/repos
Alias /lifecycle /data/lifecycle
Alias /keys /data/keys

# Security headers
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Content-Security-Policy "default-src 'self'"
APACHE_CONF

# Copy scripts for internal mode
COPY --chown=rpmserver:rpmserver scripts/common/ /opt/rpmserver/scripts/common/
COPY --chown=rpmserver:rpmserver scripts/internal/ /opt/rpmserver/scripts/internal/
COPY --chown=rpmserver:rpmserver src/ /opt/rpmserver/src/

# Install Python dependencies
COPY requirements.txt /opt/rpmserver/
RUN pip3 install --no-cache-dir -r /opt/rpmserver/requirements.txt

# Set permissions for Apache to run as non-root
RUN chown -R rpmserver:rpmserver /run/httpd /var/log/httpd \
    && chmod -R 755 /etc/httpd/conf.d

ENV RPMSERVER_MODE=internal
ENV RPMSERVER_DATA_DIR=/data
ENV RPMSERVER_LOG_DIR=/var/log/rpmserver
ENV RPMSERVER_HTTP_PORT=8080
ENV RPMSERVER_HTTPS_PORT=8443

WORKDIR /opt/rpmserver

EXPOSE 8080 8443

# Run as root for Apache (httpd requires it for initial setup)
# In production, use systemd to manage the service properly
USER root

COPY --chown=root:root scripts/internal/entrypoint.sh /opt/rpmserver/scripts/internal/
RUN chmod +x /opt/rpmserver/scripts/internal/entrypoint.sh

CMD ["/opt/rpmserver/scripts/internal/entrypoint.sh"]

# Default target is internal (most common deployment)
FROM internal AS default
