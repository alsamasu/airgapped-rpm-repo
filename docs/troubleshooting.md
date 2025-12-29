# Troubleshooting Guide

This document provides solutions to common issues encountered with the Airgapped RPM Repository System.

## External Builder Issues

### Subscription Manager

#### Registration Fails

**Symptom:** `subscription-manager register` returns errors.

```bash
# Check current status
subscription-manager status

# View detailed error
subscription-manager register --username=... --password=... 2>&1 | tee /tmp/sm-error.log
```

**Common causes:**

| Error | Cause | Solution |
|-------|-------|----------|
| `Network error` | No internet access | Check firewall, proxy settings |
| `Invalid credentials` | Wrong username/password | Verify credentials in Customer Portal |
| `Unable to find available subscriptions` | No entitlements | Attach subscription in Customer Portal |
| `System already registered` | Previous registration | Run `subscription-manager unregister` first |

**Proxy configuration:**

```bash
subscription-manager config --server.proxy_hostname=proxy.example.com \
    --server.proxy_port=8080 \
    --server.proxy_user=proxyuser \
    --server.proxy_password=proxypass
```

#### Repository Not Available

**Symptom:** `dnf repolist` doesn't show expected repositories.

```bash
# List available repos
subscription-manager repos --list

# Enable specific repo
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms

# Check subscription provides repos
subscription-manager list --consumed
```

### Sync Issues

#### Sync Fails Mid-Transfer

**Symptom:** `dnf reposync` fails partway through.

```bash
# Check disk space
df -h /data

# Retry with resume
dnf reposync --repoid=rhel-9-for-x86_64-baseos-rpms \
    --download-path=/data/mirror \
    --downloadcomps \
    --download-metadata

# Use smaller batch
dnf reposync --repoid=rhel-9-for-x86_64-baseos-rpms \
    --newest-only \
    --download-path=/data/mirror
```

#### Checksum Mismatch

**Symptom:** Downloaded packages fail checksum verification.

```bash
# Remove corrupted package
find /data/mirror -name "*.rpm" -exec rpm -K {} \; 2>&1 | grep -v "OK$"

# Re-download
rm /path/to/corrupted.rpm
dnf reposync --repoid=<repo> --download-path=/data/mirror
```

#### SSL Certificate Errors

**Symptom:** SSL verification fails when connecting to CDN.

```bash
# Check certificate expiration
subscription-manager status

# Refresh certificates
subscription-manager refresh

# Check system time (certificates are time-sensitive)
timedatectl status
```

### GPG Issues

#### Key Generation Fails

**Symptom:** `gpg --gen-key` hangs or fails.

```bash
# Check entropy
cat /proc/sys/kernel/random/entropy_avail

# Install and start rng-tools if low entropy
dnf install rng-tools
systemctl start rngd

# Retry key generation
gpg --homedir /data/keys/.gnupg --full-generate-key
```

#### Signing Fails

**Symptom:** `gpg --sign` returns error.

```bash
# Check key exists
gpg --homedir /data/keys/.gnupg --list-secret-keys

# Check key not expired
gpg --homedir /data/keys/.gnupg --list-keys

# Test signing
echo "test" | gpg --homedir /data/keys/.gnupg --clearsign
```

### Bundle Export Issues

#### Bundle Too Large

**Symptom:** Bundle exceeds media capacity.

```bash
# Check bundle size before creation
du -sh /data/staging/

# Split into multiple bundles by repository
./scripts/external/export_bundle.sh baseos-only --repos rhel9-baseos
./scripts/external/export_bundle.sh appstream-only --repos rhel9-appstream

# Or compress with higher ratio
tar -cJf bundle.tar.xz /data/staging/  # xz instead of gzip
```

## Internal Publisher Issues

### Bundle Import Issues

#### Extraction Fails

**Symptom:** `tar` extraction returns errors.

```bash
# Verify archive integrity
gzip -t /path/to/bundle.tar.gz

# Check archive contents
tar -tzf /path/to/bundle.tar.gz | head -20

# Extract with verbose output
tar -xzvf /path/to/bundle.tar.gz -C /data/bundles/incoming/ 2>&1 | tee /tmp/extract.log
```

#### Missing Files in Bundle

**Symptom:** Expected files not present after extraction.

```bash
# List bundle contents
tar -tzf /path/to/bundle.tar.gz

# Verify against BOM
tar -xzf /path/to/bundle.tar.gz -C /tmp/verify/
cat /tmp/verify/*/BILL_OF_MATERIALS.json | python3 -m json.tool
```

### Verification Failures

#### BOM Checksum Mismatch

**Symptom:** SHA256 verification fails.

```bash
# Manually verify specific file
sha256sum /data/bundles/incoming/<bundle>/repos/rhel9/x86_64/baseos/repodata/repomd.xml

# Compare with BOM entry
jq '.files[] | select(.path | contains("repomd.xml"))' \
    /data/bundles/incoming/<bundle>/BILL_OF_MATERIALS.json

# Check for file corruption during transfer
ls -la /data/bundles/incoming/<bundle>/repos/
```

**Possible causes:**
- File corrupted during physical media transfer
- Bundle created on filesystem with different encoding
- Partial or interrupted copy

#### GPG Signature Verification Fails

**Symptom:** `gpg --verify` returns bad signature.

```bash
# Check public key is imported
gpg --homedir /data/keys/.gnupg --list-keys

# Import public key from bundle
gpg --homedir /data/keys/.gnupg --import /data/bundles/incoming/<bundle>/keys/RPM-GPG-KEY-internal

# Manually verify
gpg --homedir /data/keys/.gnupg --verify \
    /data/bundles/incoming/<bundle>/bundle.tar.gz.asc \
    /data/bundles/incoming/<bundle>/bundle.tar.gz
```

### HTTP Server Issues

#### Service Won't Start

**Symptom:** `systemctl start rpmserver` fails.

```bash
# Check status
systemctl status rpmserver

# Check logs
journalctl -u rpmserver -n 50

# Check Apache syntax
apachectl configtest

# Check port availability
ss -tlnp | grep 8080
```

**Common causes:**

| Error | Solution |
|-------|----------|
| Port already in use | Stop conflicting service or change port |
| Permission denied on logs | `chown -R rpmserver:rpmserver /var/log/rpmserver` |
| SELinux denial | `restorecon -Rv /data` |
| Missing document root | Create `/data/lifecycle/prod/repos` |

#### 403 Forbidden Errors

**Symptom:** Clients receive HTTP 403.

```bash
# Check directory permissions
ls -la /data/lifecycle/prod/repos/

# Check SELinux context
ls -laZ /data/lifecycle/prod/repos/

# Fix SELinux labels
restorecon -Rv /data

# Check Apache config allows access
grep -r "Require" /etc/httpd/conf.d/
```

#### 404 Not Found

**Symptom:** Repository URLs return 404.

```bash
# Verify directory structure
find /data/lifecycle/prod/repos -type d

# Check symlinks are valid
find /data -type l -exec ls -la {} \;

# Verify Apache DocumentRoot
grep DocumentRoot /etc/httpd/conf.d/rpmrepo.conf
```

### Client Connection Issues

#### DNF Timeout

**Symptom:** `dnf` commands timeout.

```bash
# On client: test connectivity
curl -v http://publisher:8080/repos/

# Check DNS resolution
nslookup publisher

# Check firewall
firewall-cmd --list-all

# Test with IP directly
curl http://192.168.1.100:8080/repos/
```

#### GPG Key Import Fails

**Symptom:** `rpm --import` returns error.

```bash
# Download key manually
curl -o /tmp/key http://publisher:8080/keys/RPM-GPG-KEY-internal

# Check key format
file /tmp/key

# Import with verbose
rpm -v --import /tmp/key
```

#### Metadata Errors

**Symptom:** DNF reports invalid metadata.

```bash
# On client: clean cache
dnf clean all

# Check metadata on server
ls -la /data/lifecycle/prod/repos/rhel9/x86_64/baseos/repodata/

# Verify repomd.xml
xmllint /data/lifecycle/prod/repos/rhel9/x86_64/baseos/repodata/repomd.xml

# Regenerate if corrupted
createrepo_c --update /data/lifecycle/prod/repos/rhel9/x86_64/baseos/
```

## VMware/Packer Issues

### Build Fails

#### ISO Not Found

**Symptom:** Packer can't find ISO.

```bash
# Verify path
ls -la /path/to/rhel-9.6-x86_64-dvd.iso

# Verify checksum
sha256sum /path/to/rhel-9.6-x86_64-dvd.iso

# Check Packer variable
grep iso_path variables.pkrvars.hcl
```

#### Boot Timeout

**Symptom:** VM doesn't boot within timeout.

```bash
# Increase timeout in HCL
boot_wait = "30s"

# Check boot command
# Ensure boot_command is correct for RHEL 9

# Run with debug
PACKER_LOG=1 packer build -var-file=variables.pkrvars.hcl rhel9-internal.pkr.hcl
```

#### SSH Connection Fails

**Symptom:** Packer can't connect via SSH after install.

```bash
# Check kickstart enables SSH
grep -E "sshd|firewall.*ssh" http/ks.cfg

# Verify root password in kickstart matches Packer
grep ssh_password variables.pkrvars.hcl
grep rootpw http/ks.cfg

# Check network in VM
```

### OVA Deployment Issues

#### Import Fails

**Symptom:** vSphere rejects OVA.

```bash
# Verify OVA integrity
sha256sum output/rhel9-internal-publisher.ova

# Check OVA structure
tar -tvf output/rhel9-internal-publisher.ova

# Try extracting and re-importing OVF
tar -xvf rhel9-internal-publisher.ova
```

#### VM Won't Start After Deploy

**Symptom:** VM fails to boot in vSphere.

- Check VM hardware version compatibility
- Verify sufficient resources (CPU, RAM, disk)
- Check ESXi/vSphere version requirements
- Review VM console for boot errors

## Compliance Issues

### OpenSCAP Failures

#### Profile Not Found

**Symptom:** OpenSCAP can't find STIG profile.

```bash
# List available profiles
oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Check SCAP content installed
rpm -qa | grep scap-security-guide

# Install if missing
dnf install scap-security-guide
```

#### Scan Errors

**Symptom:** OpenSCAP evaluation fails.

```bash
# Run with verbose output
oscap xccdf eval --verbose ERROR \
    --profile xccdf_org.ssgproject.content_profile_stig \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml

# Check for unsupported rules
oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml | grep -i rule
```

### CKL Generation Issues

**Symptom:** STIG checklist generation fails.

```bash
# Verify XCCDF results exist
ls /opt/rpmserver/compliance/xccdf/

# Check Python dependencies
python3 -c "import xml.etree.ElementTree"

# Run manually
./scripts/generate_ckl.sh --input /opt/rpmserver/compliance/xccdf/results.xml
```

## Performance Issues

### Slow Repository Access

**Symptom:** Package downloads are slow.

```bash
# Check server load
top
iostat -x 1 5

# Check Apache settings
grep -E "KeepAlive|MaxClient" /etc/httpd/conf/httpd.conf

# Enable sendfile for static content
# In Apache config:
EnableSendfile On
```

### High Memory Usage

**Symptom:** Service consumes excessive memory.

```bash
# Check memory usage
free -h
ps aux --sort=-%mem | head

# Tune Apache prefork
<IfModule mpm_prefork_module>
    StartServers       2
    MinSpareServers    2
    MaxSpareServers    5
    MaxRequestWorkers 50
</IfModule>
```

## Log Analysis

### Finding Errors

```bash
# All errors across logs
grep -rhi "error\|fail\|crit" /var/log/rpmserver/

# Recent audit events
tail -100 /var/log/rpmserver/audit.log | jq .

# HTTP errors
awk '$9 >= 400' /var/log/rpmserver/httpd-access.log
```

### Common Log Locations

| Component | Log Path |
|-----------|----------|
| Application | `/var/log/rpmserver/rpmserver.log` |
| HTTP Access | `/var/log/rpmserver/httpd-access.log` |
| HTTP Errors | `/var/log/rpmserver/httpd-error.log` |
| Audit | `/var/log/rpmserver/audit.log` |
| SELinux | `/var/log/audit/audit.log` |
| System | `journalctl -u rpmserver` |

## Getting Help

If you're unable to resolve an issue:

1. Collect diagnostic information:
   ```bash
   ./scripts/common/collect_diagnostics.sh > /tmp/diag.tar.gz
   ```

2. Review logs in `/var/log/rpmserver/`

3. Check SELinux audit log for denials

4. Verify configuration files are valid

## Related Documentation

- [Architecture](architecture.md)
- [Operations](operations.md)
- [Security Boundary](security_boundary.md)
