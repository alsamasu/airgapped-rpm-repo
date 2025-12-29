# Operations Guide

This document provides operational guidance for managing the Airgapped RPM Repository System.

## Regular Operations

### Daily Tasks

1. **Check Service Status**
   ```bash
   systemctl status rpmserver
   curl http://localhost:8080/repos/
   ```

2. **Review Logs**
   ```bash
   tail -100 /var/log/rpmserver/rpmserver.log
   tail -100 /var/log/rpmserver/httpd-access.log
   ```

### Weekly Tasks

1. **Sync Content** (External Builder)
   ```bash
   make sync
   make build-repos
   ```

2. **Create Bundle** (if updates available)
   ```bash
   make export BUNDLE_NAME=weekly-$(date +%Y-W%V)
   ```

3. **Audit Log Review**
   ```bash
   cat /var/log/rpmserver/audit.log | jq -r '.action' | sort | uniq -c
   ```

### Monthly Tasks

1. **Compliance Check**
   ```bash
   make openscap
   make generate-ckl
   ```

2. **Storage Cleanup**
   ```bash
   # Remove old bundles (keep last 5)
   ls -t /data/bundles/*.tar.gz | tail -n +6 | xargs rm -f
   ```

3. **GPG Key Rotation Review**
   ```bash
   gpg --homedir /data/keys/.gnupg --list-keys
   # Check expiration dates
   ```

## Backup Procedures

### External Builder Backup

```bash
# Backup configuration
tar -czf external-config-$(date +%Y%m%d).tar.gz \
  /data/external.conf \
  /data/keys \
  /data/manifests/index

# Backup GPG private key (secure storage)
gpg --homedir /data/keys/.gnupg --armor --export-secret-keys > gpg-private.asc
```

### Internal Publisher Backup

```bash
# Full data backup
tar -czf internal-data-$(date +%Y%m%d).tar.gz /data

# Minimal backup (configuration only)
tar -czf internal-config-$(date +%Y%m%d).tar.gz \
  /data/internal.conf \
  /data/keys \
  /data/lifecycle/*/metadata.json
```

### Restore Procedure

```bash
# Stop service
systemctl stop rpmserver

# Restore data
tar -xzf internal-data-YYYYMMDD.tar.gz -C /

# Fix permissions
chown -R rpmserver:rpmserver /data
restorecon -Rv /data

# Start service
systemctl start rpmserver
```

## GPG Key Management

### Key Rotation

When GPG key approaches expiration:

1. **Generate new key** (External Builder)
   ```bash
   GPG_KEY_EMAIL=rpm-signing-new@internal.local make gpg-init
   ```

2. **Export new public key**
   ```bash
   make gpg-export
   ```

3. **Include both keys in bundle**
   - Old key for existing packages
   - New key for new signatures

4. **Update clients**
   ```bash
   rpm --import /path/to/RPM-GPG-KEY-internal-new
   ```

### Key Compromise Recovery

If GPG private key is compromised:

1. **Immediately** rotate key on External Builder
2. **Create new bundle** with new key
3. **Revoke old key** (if possible)
4. **Update all clients** with new public key
5. **Document incident**

## Storage Management

### Check Disk Usage

```bash
# Overall usage
df -h /data

# Per-directory usage
du -sh /data/*
du -sh /data/mirror/*
```

### Cleanup Old Content

```bash
# External Builder - remove old mirror content
./scripts/external/sync_repos.sh --delete

# Internal Publisher - archive old bundles
mv /data/bundles/verified/old-* /data/bundles/archive/

# Remove oldest archives
ls -t /data/bundles/archive/*.tar.gz | tail -n +11 | xargs rm -f
```

### Retention Policy

Recommended retention:
- Bundles (verified): 5 most recent
- Bundles (archive): 10 most recent
- Mirror content: Current only (with --delete)
- Manifests: 30 days
- Logs: 90 days

## Log Management

### Log Locations

| Log | Path | Purpose |
|-----|------|---------|
| Application | `/var/log/rpmserver/rpmserver.log` | General application logs |
| Audit | `/var/log/rpmserver/audit.log` | Security-relevant events |
| HTTP Access | `/var/log/rpmserver/httpd-access.log` | Client requests |
| HTTP Error | `/var/log/rpmserver/httpd-error.log` | HTTP server errors |

### Log Rotation

Configure in `/etc/logrotate.d/rpmserver`:

```
/var/log/rpmserver/*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 rpmserver rpmserver
    sharedscripts
    postrotate
        systemctl reload rpmserver >/dev/null 2>&1 || true
    endscript
}
```

### Log Analysis

```bash
# Count requests by client
awk '{print $1}' /var/log/rpmserver/httpd-access.log | sort | uniq -c | sort -rn

# Find errors
grep -E "error|fail|warn" /var/log/rpmserver/*.log

# Audit events by type
jq -r '.action' /var/log/rpmserver/audit.log | sort | uniq -c
```

## Monitoring

### Health Checks

```bash
#!/bin/bash
# health-check.sh

# Check service
if ! systemctl is-active --quiet rpmserver; then
    echo "CRITICAL: rpmserver service not running"
    exit 2
fi

# Check HTTP
if ! curl -sf http://localhost:8080/repos/ > /dev/null; then
    echo "CRITICAL: HTTP not responding"
    exit 2
fi

# Check disk space
USED=$(df /data --output=pcent | tail -1 | tr -d ' %')
if [ "$USED" -gt 90 ]; then
    echo "WARNING: /data disk usage at ${USED}%"
    exit 1
fi

echo "OK: All checks passed"
exit 0
```

### Metrics to Monitor

- Service status (up/down)
- HTTP response time
- Disk usage (/data)
- Package count per repository
- Bundle age (time since last update)

## Incident Response

### Service Outage

1. Check service status: `systemctl status rpmserver`
2. Check logs: `journalctl -u rpmserver -n 100`
3. Restart service: `systemctl restart rpmserver`
4. Verify: `curl http://localhost:8080/repos/`

### Repository Corruption

1. Stop service
2. Restore from backup
3. Verify bundle integrity
4. Re-import if needed
5. Restart service

### Security Incident

1. **Isolate** system if needed
2. **Preserve** logs and evidence
3. **Assess** scope of compromise
4. **Rotate** GPG keys if affected
5. **Document** incident and response
6. **Report** per organizational policy

## Disaster Recovery

### Complete System Loss

1. Deploy new VM from OVA
2. Restore data from backup
3. Import current GPG key
4. Import latest verified bundle
5. Publish to prod
6. Update client configurations

### Data Loss

1. Re-sync from External Builder (if available)
2. Re-import bundles from archive media
3. Rebuild repository metadata

## Performance Tuning

### Apache Optimization

```apache
# /etc/httpd/conf.d/rpmrepo.conf additions

# Enable sendfile for large files
EnableSendfile On

# Keep-alive settings
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

# MPM tuning
<IfModule mpm_prefork_module>
    StartServers          5
    MinSpareServers       5
    MaxSpareServers      10
    MaxRequestWorkers   150
    MaxConnectionsPerChild 10000
</IfModule>
```

### Storage Optimization

- Use thin provisioning for VMware
- Consider SSD for repository storage
- Use XFS filesystem with appropriate options

## Change Management

### Before Making Changes

1. Document current state
2. Plan change with rollback procedure
3. Test in dev channel first
4. Schedule maintenance window
5. Notify stakeholders

### After Making Changes

1. Verify functionality
2. Run compliance check
3. Document changes
4. Monitor for issues

## Related Documentation

- [Architecture](architecture.md)
- [Troubleshooting](troubleshooting.md)
- [STIG Hardening](stig_hardening_internal.md)
