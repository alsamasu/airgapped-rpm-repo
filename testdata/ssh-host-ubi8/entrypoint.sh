#!/bin/bash
# entrypoint.sh - SSH host test container entrypoint
#
# Starts SSH daemon and keeps container running.

set -e

# Generate host keys if missing
if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
    ssh-keygen -A
fi

# Set host identity if provided
if [[ -n "${AIRGAP_HOST_ID:-}" ]]; then
    echo "${AIRGAP_HOST_ID}" > /etc/airgap_host_id
    echo "Host ID set: ${AIRGAP_HOST_ID}"
fi

# Start rsyslog if available
if command -v rsyslogd &>/dev/null; then
    rsyslogd 2>/dev/null || true
fi

echo "Starting SSH daemon..."
echo "Host: $(hostname)"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"

# Start SSH in foreground
exec /usr/sbin/sshd -D -e
