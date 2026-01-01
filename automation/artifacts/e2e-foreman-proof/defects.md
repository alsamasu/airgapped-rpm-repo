# E2E Foreman+Katello Proof - Defects and Issues

## Date: 2026-01-01

---

## DEFECT-001: Capsule Disk Full (100%)

**Severity**: Critical
**Component**: capsule-server infrastructure
**Status**: RESOLVED

### Description
Capsule server disk was 100% full (296G/296G), causing PostgreSQL failures and Pulpcore heartbeat issues.

### Root Cause
Insufficient initial disk provisioning for content storage.

### Resolution
Expanded disk via vSphere from 300GB to 1TB using:
```bash
govc vm.disk.change -size 1T
growpart /dev/sda 3
pvresize /dev/sda3
lvextend -l +100%FREE /dev/mapper/rhel-root
xfs_growfs /
```

### Recommendation
Provision capsule servers with at least 1TB for production deployments with multiple RHEL version CVs.

---

## DEFECT-002: Export Missing metadata.json

**Severity**: High
**Component**: Katello content-export
**Status**: RESOLVED

### Description
Initial export tarballs lacked `metadata.json` files required for import.

### Root Cause
Export was run without `--format importable` flag.

### Resolution
Re-exported with correct format:
```bash
hammer content-export complete version --content-view cv_rhel9_security \
  --version 1.0 --organization 'Default Organization' --format importable
```

### Recommendation
Always use `--format importable` for air-gapped transfers.

---

## DEFECT-003: Katello Import Bug - "wrong number of arguments (given 4, expected 3)"

**Severity**: High
**Component**: Katello 4.13.1 - importable_repositories.rb
**Status**: WORKAROUND APPLIED

### Description
Content import failed with Ruby error in `enable_repository.rb:9` called from `auto_create_redhat_repositories.rb`.

### Root Cause
Bug in Katello 4.13.1 where the `importable_repositories.rb` file differed between satellite and capsule installations.

### Workaround
Manually enable repositories before import:
```bash
hammer repository-set enable --organization 'Default Organization' \
  --product 'Red Hat Enterprise Linux for x86_64' \
  --name 'Red Hat Enterprise Linux 9 for x86_64 - BaseOS (RPMs)' \
  --basearch x86_64 --releasever 9.6
```

### Recommendation
Report bug to Red Hat; consider patching `importable_repositories.rb` from satellite to capsule.

---

## DEFECT-004: Missing Manifest on Capsule

**Severity**: Medium
**Component**: Katello subscription management
**Status**: RESOLVED

### Description
Import failed with "No manifest found" error.

### Root Cause
Capsule server did not have subscription manifest uploaded.

### Resolution
Copied manifest from satellite and uploaded:
```bash
scp satellite:/tmp/manifest.zip capsule:/tmp/
hammer subscription upload --file /tmp/manifest.zip --organization 'Default Organization'
```

### Recommendation
Document manifest transfer as required step for disconnected capsule setup.

---

## DEFECT-005: Firewall Ports Not Open on Capsule

**Severity**: Medium
**Component**: capsule-server firewalld
**Status**: RESOLVED

### Description
Testers could not connect to capsule HTTPS port (443) despite successful ping.

### Root Cause
firewalld only allowed ssh, cockpit, dhcpv6-client by default.

### Resolution
```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=5647/tcp
firewall-cmd --permanent --add-port=8000/tcp
firewall-cmd --permanent --add-port=8140/tcp
firewall-cmd --permanent --add-port=9090/tcp
firewall-cmd --reload
```

### Recommendation
Include firewall configuration in capsule setup automation.

---

## DEFECT-006: DNS Resolution for capsule.local

**Severity**: Medium
**Component**: Client registration
**Status**: RESOLVED

### Description
Testers failed registration with "Name or service not known" for capsule.local hostname.

### Root Cause
No DNS entry for capsule.local; katello-ca-consumer package hardcodes hostname.

### Resolution
Added hosts entry on testers:
```bash
echo '192.168.1.249 capsule.local capsule' | sudo tee -a /etc/hosts
```

### Recommendation
Either configure proper DNS or include hosts file updates in registration automation.

---

## DEFECT-007: Security-Only Errata Filter Missing Dependencies

**Severity**: Low
**Component**: Content View filter design
**Status**: EXPECTED BEHAVIOR (Documented)

### Description
RHEL8 security updates for SSSD required samba-client-libs which was not included in security-only errata.

### Root Cause
Security errata filters only include packages directly marked as security updates, not their dependencies.

### Workaround
Used `--nobest` flag to install available updates:
```bash
dnf update --security -y --nobest
```

### Recommendation
For complete security patching, consider using "Include all dependencies" option on CV filters, or accept that some security updates may be skipped.

---

## Summary

| ID | Severity | Status | Component |
|----|----------|--------|-----------|
| 001 | Critical | Resolved | Infrastructure |
| 002 | High | Resolved | Katello export |
| 003 | High | Workaround | Katello 4.13.1 bug |
| 004 | Medium | Resolved | Subscription management |
| 005 | Medium | Resolved | Firewall |
| 006 | Medium | Resolved | DNS/Client registration |
| 007 | Low | Expected | CV filter design |

**Total Issues**: 7
**Blocking Issues**: 0 (all resolved or workarounds applied)
**Overall Result**: E2E Proof **SUCCESSFUL**
