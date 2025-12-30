# NIST SP 800-53 Control Mapping

This document maps the implemented security controls and procedures in this repository to NIST SP 800-53 Rev 5 control families.

## Overview

This mapping documents how the Airgapped RPM Repository System implements controls aligned with NIST SP 800-53 Rev 5. The system is designed for deployment in airgapped environments where DISA STIG compliance is required.

**Scope**: This mapping covers the Internal Publisher VM and operational procedures. It does not constitute a full certification assessment.

## Control Mapping

### AC - Access Control

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| AC-2 | Account Management | Service accounts created with nologin shell; root access limited | `packer/scripts/provision.sh`, `packer/http/ks.cfg` |
| AC-3 | Access Enforcement | SELinux enforcing; file permissions restricted | `packer/scripts/harden.sh` |
| AC-6 | Least Privilege | Service runs as dedicated user; containers use non-root where possible | `Dockerfile`, `scripts/internal/entrypoint.sh` |
| AC-7 | Unsuccessful Logon Attempts | Account lockout configured via PAM | `packer/scripts/harden.sh` |
| AC-8 | System Use Notification | DOD warning banner displayed | `packer/scripts/harden.sh` (SSH Banner) |
| AC-17 | Remote Access | SSH key-only authentication; password auth disabled | `packer/scripts/harden.sh` (SSHD config) |

### AU - Audit and Accountability

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| AU-2 | Event Logging | Comprehensive audit rules; application logging | `packer/scripts/harden.sh` (audit rules), `scripts/common/logging.sh` |
| AU-3 | Content of Audit Records | Timestamped JSON audit entries with caller info | `scripts/common/logging.sh` (log_audit function) |
| AU-6 | Audit Record Review | Audit logs stored; AIDE for integrity | `packer/scripts/harden.sh` |
| AU-8 | Time Stamps | NTP configured via chronyd | `packer/http/ks.cfg` |
| AU-9 | Protection of Audit Information | Separate /var/log/audit partition | `packer/http/ks.cfg` |
| AU-12 | Audit Record Generation | Auditd enabled and configured | `packer/scripts/harden.sh` |

### CA - Assessment, Authorization, and Monitoring

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| CA-7 | Continuous Monitoring | OpenSCAP evaluation capability | `scripts/run_openscap.sh` |
| CA-8 | Penetration Testing | Container scanning in CI/CD | `.github/workflows/security.yml` |

### CM - Configuration Management

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| CM-2 | Baseline Configuration | Kickstart + Packer automation | `packer/http/ks.cfg`, `packer/rhel9-internal.pkr.hcl` |
| CM-3 | Configuration Change Control | Git version control; CI/CD pipeline | `.github/workflows/ci.yml` |
| CM-5 | Access Restrictions for Change | GPG signing required for bundles | `scripts/common/gpg_functions.sh` |
| CM-6 | Configuration Settings | STIG-aligned hardening | `packer/scripts/harden.sh` |
| CM-7 | Least Functionality | Minimal packages; disabled services | `packer/http/ks.cfg`, `packer/scripts/harden.sh` |
| CM-8 | System Component Inventory | Package manifests collected | `scripts/host_collect_manifest.sh` |
| CM-11 | User-Installed Software | Controlled through repository management | System design |

### IA - Identification and Authentication

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| IA-2 | Identification and Authentication | SSH key authentication | `packer/scripts/harden.sh` |
| IA-5 | Authenticator Management | Password policy configured | `packer/scripts/harden.sh` (pwquality) |
| IA-7 | Cryptographic Module Authentication | FIPS mode enabled | `packer/scripts/harden.sh` |

### MA - Maintenance

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| MA-2 | Controlled Maintenance | Documented procedures; airgapped updates | `docs/operations.md` |
| MA-3 | Maintenance Tools | Controlled through bundle mechanism | System design |

### MP - Media Protection

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| MP-2 | Media Access | Controlled hand-carry procedures | System design |
| MP-4 | Media Storage | N/A - airgapped environment | System design |
| MP-5 | Media Transport | Signed bundles with checksums | `scripts/external/export_bundle.sh` |

### SC - System and Communications Protection

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| SC-5 | Denial of Service Protection | Firewall configured | `packer/scripts/harden.sh` |
| SC-7 | Boundary Protection | Airgapped network design | System architecture |
| SC-8 | Transmission Confidentiality | HTTPS supported; GPG signatures | `Dockerfile`, `scripts/common/gpg_functions.sh` |
| SC-12 | Cryptographic Key Management | GPG key management procedures | `scripts/common/gpg_functions.sh`, `docs/operations.md` |
| SC-13 | Cryptographic Protection | SHA256 for integrity; GPG for authenticity | Throughout system |
| SC-23 | Session Authenticity | SSH session configuration | `packer/scripts/harden.sh` |

### SI - System and Information Integrity

| Control ID | Control Name | Implementation | Evidence |
|------------|--------------|----------------|----------|
| SI-2 | Flaw Remediation | Controlled update process | System design |
| SI-3 | Malicious Code Protection | Container scanning; SBOM generation | `.github/workflows/security.yml` |
| SI-4 | System Monitoring | Audit logging; AIDE | `packer/scripts/harden.sh` |
| SI-7 | Software and Information Integrity | GPG signatures; BOM verification | `scripts/internal/verify_bundle.sh` |

## Coverage Summary

### Implemented Controls

| Family | Controls Addressed | Implementation Level |
|--------|-------------------|---------------------|
| AC | 7 | Full |
| AU | 6 | Full |
| CA | 2 | Partial |
| CM | 7 | Full |
| IA | 3 | Full |
| MA | 2 | Partial |
| MP | 3 | Full |
| SC | 7 | Full |
| SI | 4 | Full |

### Out of Scope

The following control families are organizational in nature and not directly implemented by this system:

- **AT** (Awareness and Training) - Organizational responsibility
- **CP** (Contingency Planning) - Requires organizational procedures
- **IR** (Incident Response) - Organizational responsibility
- **PE** (Physical and Environmental Protection) - Facility-dependent
- **PL** (Planning) - Organizational responsibility
- **PS** (Personnel Security) - Organizational responsibility
- **RA** (Risk Assessment) - Organizational responsibility
- **SA** (System and Services Acquisition) - Organizational responsibility

## Evidence Artifacts

### Configuration Evidence

1. **Kickstart file**: `packer/http/ks.cfg`
   - Partition layout
   - Package selection
   - Initial hardening

2. **Hardening script**: `packer/scripts/harden.sh`
   - SSH configuration
   - Audit rules
   - Kernel parameters
   - Password policy

3. **Container security**: `Dockerfile`
   - Minimal base image
   - Non-root user
   - Security headers

### Compliance Reports

Generated by `make openscap` and `make generate-ckl`:

1. **OpenSCAP ARF**: `compliance/arf/*.xml`
2. **OpenSCAP XCCDF**: `compliance/xccdf/*.xml`
3. **HTML Reports**: `compliance/html/*.html`
4. **Checklists**: `compliance/ckl/*.ckl`, `*.csv`, `*.json`

### Operational Evidence

1. **Audit logs**: `/var/log/rpmserver/audit.log`
2. **Application logs**: `/var/log/rpmserver/rpmserver.log`
3. **Bundle manifests**: `bundle_manifest.json`
4. **Bill of Materials**: `BILL_OF_MATERIALS.json`

## Continuous Compliance

### Regular Assessment

```bash
# Run OpenSCAP evaluation
make openscap

# Generate checklists
make generate-ckl

# Review compliance reports
ls compliance/html/
```

### CI/CD Integration

The GitHub Actions workflows automatically:
- Scan for secrets (gitleaks)
- Scan containers (Trivy)
- Generate SBOM (Syft)
- Run security analysis (CodeQL)

## References

- NIST SP 800-53 Rev 5: https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final
- DISA STIG: https://public.cyber.mil/stigs/
- SCAP Security Guide: https://github.com/ComplianceAsCode/content
