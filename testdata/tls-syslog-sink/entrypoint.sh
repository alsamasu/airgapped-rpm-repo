#!/bin/bash
# entrypoint.sh - TLS Syslog Sink entrypoint
#
# Generates self-signed certificates and starts rsyslog with TLS.

set -e

CERT_DIR="/etc/pki/rsyslog"
CERT_FILE="${CERT_DIR}/server.crt"
KEY_FILE="${CERT_DIR}/server.key"
CA_FILE="${CERT_DIR}/ca.crt"

echo "=== TLS Syslog Sink ==="

# Generate self-signed certificates if not present
if [[ ! -f "${CERT_FILE}" ]] || [[ ! -f "${KEY_FILE}" ]]; then
    echo "Generating self-signed TLS certificates..."
    
    # Generate CA key and certificate
    openssl genrsa -out "${CERT_DIR}/ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" \
        -sha256 -days 365 -out "${CA_FILE}" \
        -subj "/C=US/ST=Test/L=Test/O=Test CA/CN=Syslog Test CA" \
        2>/dev/null
    
    # Generate server key and CSR
    openssl genrsa -out "${KEY_FILE}" 2048 2>/dev/null
    openssl req -new -key "${KEY_FILE}" \
        -out "${CERT_DIR}/server.csr" \
        -subj "/C=US/ST=Test/L=Test/O=Test/CN=syslog-sink" \
        2>/dev/null
    
    # Sign server certificate with CA
    openssl x509 -req -in "${CERT_DIR}/server.csr" \
        -CA "${CA_FILE}" -CAkey "${CERT_DIR}/ca.key" \
        -CAcreateserial -out "${CERT_FILE}" -days 365 -sha256 \
        -extfile <(echo "subjectAltName=DNS:syslog-sink,DNS:localhost,IP:127.0.0.1") \
        2>/dev/null
    
    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_FILE}" "${CA_FILE}"
    
    echo "TLS certificates generated"
    echo "CA certificate available at: ${CA_FILE}"
fi

# Create log directory
mkdir -p /var/log/remote

echo "Starting rsyslog..."
echo "TLS port: ${SYSLOG_TLS_PORT:-6514}"
echo "TCP port: ${SYSLOG_TCP_PORT:-514}"
echo "Logs written to: /var/log/remote/"

# Start rsyslog in foreground
exec /usr/sbin/rsyslogd -n -f /etc/rsyslog.conf
