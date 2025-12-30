# Administration Guide

## Overview

This guide covers day-to-day operations and maintenance of the airgapped RPM repository infrastructure. It assumes:

- RHEL 9.6 internal server deployed per the Deployment Guide
- Rootless Podman running under the `rpmops` service user
- Repository served over HTTPS on port 443
- Managed hosts onboarded and consuming packages from the internal repository

---

## System Components

### Key File Locations

| Path | Server | Purpose |
|------|--------|---------|
| `/var/lib/airgap-rpm/repo/` | Internal | Repository content root |
| `/var/lib/airgap-rpm/tls/` | Internal | TLS certificates |
| `/var/lib/airgap-rpm/import/` | Internal | Bundle import staging |
| `/var/lib/airgap-rpm/export/` | External | Bundle export staging |
| `/var/lib/airgap-rpm/sync/` | External | Synced repository mirror |
| `/var/lib/airgap-rpm/manifests/` | Both | Host manifest storage |

---

## Routine Operations

### Check Service Status

```bash
ssh admin@<internal-ip> "systemctl --user -M rpmops@ status airgap-rpm-publisher.service"
```

### Restart Repository Service

```bash
ssh admin@<internal-ip> "systemctl --user -M rpmops@ restart airgap-rpm-publisher.service"
```

### View Service Logs

```bash
ssh admin@<internal-ip> "journalctl --user -M rpmops@ -u airgap-rpm-publisher.service -n 50"
```

---

## Host Onboarding

### Run Onboarding Playbook

```bash
make ansible-onboard INVENTORY=ansible/inventories/lab.yml
```

To limit to specific hosts, run the playbook directly:
```bash
cd ansible && ansible-playbook -i inventories/lab.yml playbooks/onboard_hosts.yml --limit new-host
```

### Onboarding Tags

| Tag | Purpose |
|-----|---------|
| preflight | Pre-flight checks |
| identity | Configure host identity |
| repository | Configure DNF repositories |
| syslog | Configure syslog TLS forwarding |
| manifest | Collect host manifest |
| verify | Validate onboarding success |

---

## Manifest Collection

```bash
make manifests INVENTORY=ansible/inventories/lab.yml
```

---

## RPM Lifecycle Management

### Lifecycle Environments

| Environment | Path | Purpose |
|-------------|------|---------|
| testing | `/var/lib/airgap-rpm/repo/testing/` | Newly imported packages |
| stable | `/var/lib/airgap-rpm/repo/stable/` | Production-ready packages |

### Sync Repositories (External Server)

```bash
ssh admin@<external-ip> "sudo /opt/airgap-rpm/scripts/external/sync_repos.sh"
```

### Export Bundle for Hand-Carry

```bash
ssh admin@<external-ip> "sudo /opt/airgap-rpm/scripts/external/export_bundle.sh"
```

### Import Bundle (Internal Server)

```bash
make import BUNDLE_PATH=/var/lib/airgap-rpm/import/bundle-YYYYMMDD.tar.gz
```

### Promote from Testing to Stable

```bash
make promote FROM=testing TO=stable
```

---

## Monthly Patch Cycle

```bash
make patch INVENTORY=ansible/inventories/lab.yml
```

---

## TLS and Certificates

### Check Certificate Expiration

```bash
ssh admin@<internal-ip> "openssl x509 -in /var/lib/airgap-rpm/tls/server.crt -noout -dates"
```

### Replace TLS Certificate

```bash
ansible-playbook -i ansible/inventories/lab.yml ansible/playbooks/replace_repo_tls_cert.yml \
  -e "cert_path=/tmp/new-certs/server.crt" \
  -e "key_path=/tmp/new-certs/server.key"
```

---

## Backup, Recovery, and Rollback

### Backup Repository Content

```bash
ssh admin@<internal-ip> "sudo tar -czf /var/lib/airgap-rpm/backups/repo-$(date +%Y%m%d).tar.gz -C /var/lib/airgap-rpm repo/"
```

### Restore from Backup

1. Stop service
2. Extract backup to `/var/lib/airgap-rpm/`
3. Fix ownership: `chown -R rpmops:rpmops /var/lib/airgap-rpm/repo/`
4. Start service

---

## Decommissioning

### Remove Managed Host

1. Collect final manifest
2. Remove from inventory
3. Optionally restore original repo configuration

### Decommission Server

1. Backup repository and certificates
2. Stop and disable services
3. Remove from vSphere: `make servers-destroy`

---

## Troubleshooting Reference

### Repository Service Won't Start
- Check logs: `journalctl --user -M rpmops@ -u airgap-rpm-publisher.service`
- Verify TLS certificate validity
- Check port conflicts: `ss -tlnp | grep -E ':80|:443'`

### Managed Host Cannot Access Repository
- Check firewall on internal server
- Verify repository URL in `/etc/yum.repos.d/airgap-*.repo`
- Test with: `curl -vk https://<internal-ip>/repo/stable/`

### Package Import Fails
- Verify bundle structure (BILL_OF_MATERIALS.json exists)
- Check disk space: `df -h /var/lib/airgap-rpm`
- Review import log

### Ansible Playbook Fails
- Run with `-vvv` for verbose output
- Check SSH connectivity
- Verify Python interpreter path in inventory
