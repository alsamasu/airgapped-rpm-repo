# Rootless Podman Deployment

This directory contains systemd user service files for deploying the airgapped
RPM repository infrastructure using rootless Podman.

## Prerequisites

1. RHEL 9.6 or compatible system
2. Podman installed (`dnf install podman`)
3. Service user created (e.g., `rpmops`)

## Setup

### 1. Create the service user

```bash
sudo useradd -r -m -d /home/rpmops -s /bin/bash rpmops
sudo loginctl enable-linger rpmops
```

### 2. Create data directories

```bash
sudo -u rpmops mkdir -p /home/rpmops/{data,ansible}
sudo -u rpmops mkdir -p /home/rpmops/data/{repos,lifecycle,bundles,keys,certs}
sudo -u rpmops mkdir -p /home/rpmops/ansible/{inventory,artifacts}
sudo -u rpmops mkdir -p /home/rpmops/.ssh
```

### 3. Build container images

```bash
# As the rpmops user
sudo -u rpmops podman build -t airgap-rpm-publisher:latest \
    -f containers/rpm-publisher/Containerfile containers/rpm-publisher/

sudo -u rpmops podman build -t airgap-ansible-control:latest \
    -f containers/ansible-ee/Containerfile containers/ansible-ee/
```

### 4. Install systemd services

```bash
sudo -u rpmops mkdir -p /home/rpmops/.config/systemd/user

sudo cp deployment/systemd/airgap-rpm-publisher.service \
    /home/rpmops/.config/systemd/user/
sudo cp deployment/systemd/airgap-ansible-control.service \
    /home/rpmops/.config/systemd/user/

sudo chown -R rpmops:rpmops /home/rpmops/.config
```

### 5. Enable and start services

```bash
# As the rpmops user
sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    systemctl --user daemon-reload

sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    systemctl --user enable --now airgap-rpm-publisher

sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    systemctl --user enable --now airgap-ansible-control
```

## Service Management

### Check status

```bash
sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    systemctl --user status airgap-rpm-publisher airgap-ansible-control
```

### View logs

```bash
sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    journalctl --user -u airgap-rpm-publisher -f
```

### Restart services

```bash
sudo -u rpmops XDG_RUNTIME_DIR=/run/user/$(id -u rpmops) \
    systemctl --user restart airgap-rpm-publisher
```

## Running Ansible Playbooks

Execute playbooks via the ansible-control container:

```bash
sudo -u rpmops podman exec -it airgap-ansible-control \
    ansible-playbook /runner/project/playbooks/collect_manifests.yml
```

Or use the helper script:

```bash
./deployment/run-ansible.sh playbooks/patch_monthly_security.yml
```

## Certificate Management

### Replace self-signed certificate with CA-signed

1. Obtain certificate from your CA
2. Copy to the certs volume:
   ```bash
   cp your-cert.crt /home/rpmops/data/certs/server.crt
   cp your-key.key /home/rpmops/data/certs/server.key
   chmod 600 /home/rpmops/data/certs/server.key
   ```
3. Restart the publisher:
   ```bash
   systemctl --user restart airgap-rpm-publisher
   ```

## Syslog TLS Configuration

Configure the syslog target in the Ansible inventory:

```yaml
all:
  vars:
    syslog_tls_target_host: your-syslog-server.example.com
    syslog_tls_target_port: 6514
    syslog_tls_ca_bundle_path: /etc/pki/tls/certs/syslog-ca.crt
```

Then deploy the CA certificate and run the STIG playbook:

```bash
sudo -u rpmops podman exec -it airgap-ansible-control \
    ansible-playbook /runner/project/playbooks/stig_harden_internal_vm.yml
```
