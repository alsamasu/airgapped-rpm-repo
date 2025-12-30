# Threat Model

This document describes the threat model for the Airgapped RPM Repository System using STRIDE methodology.

## System Overview

The system consists of:
- **External Builder**: Internet-connected server syncing from Red Hat CDN
- **Internal Publisher**: Airgapped server serving repositories to internal hosts
- **Hand-Carry Media**: Physical transport between zones
- **Internal Hosts**: RHEL systems consuming packages

## Assets

### Critical Assets

| Asset | Description | Confidentiality | Integrity | Availability |
|-------|-------------|-----------------|-----------|--------------|
| GPG Private Key | Signs bundles and repositories | HIGH | HIGH | MEDIUM |
| RPM Packages | Software deployed to hosts | LOW | HIGH | HIGH |
| Repository Metadata | Package index and dependencies | LOW | HIGH | HIGH |
| Host Manifests | Installed package inventory | MEDIUM | HIGH | LOW |
| Configuration Files | System settings | MEDIUM | HIGH | MEDIUM |

### Supporting Assets

| Asset | Description | CIA Priority |
|-------|-------------|--------------|
| Audit Logs | Security event records | I > A > C |
| Bundle Archives | Transfer packages | I > A > C |
| Network Connections | Service communication | A > I > C |

## Trust Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                        BOUNDARY 1                                │
│                    Internet ↔ External Builder                   │
│                                                                  │
│  Threat: Compromised CDN, MITM, DNS poisoning                   │
│  Controls: HTTPS, Red Hat GPG verification, subscription-manager│
└─────────────────────────────────────────────────────────────────┘
                              │
                    Physical Air Gap
                              │
┌─────────────────────────────────────────────────────────────────┐
│                        BOUNDARY 2                                │
│                External Builder ↔ Hand-Carry Media              │
│                                                                  │
│  Threat: Malicious bundles, tampered media                      │
│  Controls: GPG signatures, BOM checksums, physical security     │
└─────────────────────────────────────────────────────────────────┘
                              │
                    Physical Air Gap
                              │
┌─────────────────────────────────────────────────────────────────┐
│                        BOUNDARY 3                                │
│              Hand-Carry Media ↔ Internal Publisher              │
│                                                                  │
│  Threat: Tampered bundles, counterfeit media                    │
│  Controls: GPG verification, BOM validation                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                        Network
                              │
┌─────────────────────────────────────────────────────────────────┐
│                        BOUNDARY 4                                │
│                Internal Publisher ↔ Internal Hosts              │
│                                                                  │
│  Threat: Rogue clients, unauthorized access                     │
│  Controls: Firewall, network segmentation, GPG verification     │
└─────────────────────────────────────────────────────────────────┘
```

## STRIDE Analysis

### Spoofing

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| S1 | Attacker spoofs Red Hat CDN | External Builder | LOW | HIGH | MEDIUM |
| S2 | Attacker spoofs Internal Publisher | Internal Hosts | MEDIUM | HIGH | HIGH |
| S3 | Attacker spoofs administrator | All systems | LOW | HIGH | MEDIUM |
| S4 | Counterfeit hand-carry media | Internal Publisher | LOW | HIGH | MEDIUM |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| S1 | Certificate validation | subscription-manager TLS verification |
| S1 | GPG verification | Red Hat GPG key validation on packages |
| S2 | Network segmentation | Firewall rules limiting access |
| S2 | DNS security | Internal DNS with DNSSEC |
| S3 | SSH key authentication | Password auth disabled |
| S3 | MFA | Hardware tokens for admin access |
| S4 | Physical verification | Chain of custody, tamper-evident seals |
| S4 | Cryptographic verification | GPG signature required on bundles |

### Tampering

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| T1 | Modify packages in transit | CDN → External | LOW | HIGH | MEDIUM |
| T2 | Tamper with bundle on media | Hand-carry | MEDIUM | HIGH | HIGH |
| T3 | Modify repository metadata | Internal Publisher | LOW | HIGH | MEDIUM |
| T4 | Alter host manifests | Hand-carry back | MEDIUM | MEDIUM | MEDIUM |
| T5 | Compromise bundle creation | External Builder | LOW | CRITICAL | MEDIUM |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| T1 | GPG signature verification | rpm --checksig on all packages |
| T2 | Bundle signatures | GPG-signed bundle archive |
| T2 | Bill of Materials | SHA256 checksums for all files |
| T3 | Metadata signing | repomd.xml.asc GPG signature |
| T4 | Manifest checksums | SHA256 hash file accompanying manifest |
| T5 | GPG key protection | HSM or encrypted storage for private key |
| T5 | Build process audit | All operations logged to audit.log |

### Repudiation

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| R1 | Admin denies creating malicious bundle | External Builder | LOW | HIGH | MEDIUM |
| R2 | Admin denies importing unverified bundle | Internal Publisher | LOW | MEDIUM | LOW |
| R3 | User denies installing vulnerable package | Internal Hosts | MEDIUM | LOW | LOW |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| R1 | Audit logging | JSON audit log with timestamps, user, action |
| R1 | GPG signatures | Bundle signed by identifiable key |
| R2 | Import verification logging | All import/verify operations logged |
| R2 | Promotion audit trail | Lifecycle metadata tracks all changes |
| R3 | YUM transaction history | dnf history on clients |
| R3 | Centralized logging | Forward logs to SIEM |

### Information Disclosure

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| I1 | Host manifests reveal vulnerabilities | Manifest files | MEDIUM | MEDIUM | MEDIUM |
| I2 | Repository structure reveals infrastructure | Internal Publisher | LOW | LOW | LOW |
| I3 | GPG private key disclosure | External Builder | LOW | CRITICAL | MEDIUM |
| I4 | Audit logs expose operations | All systems | LOW | MEDIUM | LOW |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| I1 | Manifest encryption | GPG encrypt manifests on media |
| I1 | Physical media control | Locked transport containers |
| I2 | Network access control | Firewall limits repository access |
| I3 | Key storage security | Encrypted filesystem, restricted access |
| I3 | HSM consideration | Hardware security module for keys |
| I4 | Log access control | Restricted permissions on log files |

### Denial of Service

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| D1 | CDN unavailable | External Builder | LOW | MEDIUM | LOW |
| D2 | Disk exhaustion on publisher | Internal Publisher | MEDIUM | HIGH | MEDIUM |
| D3 | HTTP server overwhelmed | Internal Publisher | LOW | MEDIUM | LOW |
| D4 | Corrupted bundle prevents updates | Internal Publisher | LOW | HIGH | MEDIUM |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| D1 | Local mirror cache | Retain previous sync content |
| D2 | Disk monitoring | Alert at 80% capacity |
| D2 | Retention policy | Automated cleanup of old bundles |
| D3 | Rate limiting | Apache mod_ratelimit |
| D3 | Resource limits | systemd resource constraints |
| D4 | Bundle rollback | Keep previous verified bundles |
| D4 | Verification before publish | Never publish unverified content |

### Elevation of Privilege

| Threat ID | Threat | Target | Likelihood | Impact | Risk |
|-----------|--------|--------|------------|--------|------|
| E1 | Service account escalation | All systems | LOW | HIGH | MEDIUM |
| E2 | Exploit in RPM package | Internal Hosts | LOW | CRITICAL | MEDIUM |
| E3 | Web server vulnerability | Internal Publisher | LOW | HIGH | MEDIUM |
| E4 | Container escape | Containerized deployments | LOW | HIGH | MEDIUM |

**Mitigations:**

| Threat | Mitigation | Implementation |
|--------|------------|----------------|
| E1 | Least privilege | Service accounts with no login shell |
| E1 | SELinux | Enforcing mode with custom policy |
| E2 | GPG verification | Only signed packages accepted |
| E2 | Testing | Dev channel testing before prod |
| E3 | Hardening | STIG compliance, minimal services |
| E3 | Updates | Regular security patches |
| E4 | Rootless containers | Podman rootless mode |
| E4 | Read-only root | Immutable container filesystems |

## Attack Trees

### Attack Tree 1: Compromise Internal Hosts via Malicious Package

```
Goal: Execute malicious code on internal hosts
├── 1. Compromise Red Hat CDN [Very Difficult]
│   └── Mitigated by: Multiple verification layers
├── 2. Compromise External Builder [Difficult]
│   ├── 2.1 Exploit internet-facing service
│   │   └── Mitigated by: Minimal services, patching
│   ├── 2.2 Compromise admin credentials
│   │   └── Mitigated by: SSH keys, MFA
│   └── 2.3 Insider threat
│       └── Mitigated by: Audit logging, separation of duties
├── 3. Tamper with hand-carry media [Medium]
│   ├── 3.1 Physical access to media
│   │   └── Mitigated by: Chain of custody, tamper-evident seals
│   └── 3.2 Substitute counterfeit media
│       └── Mitigated by: GPG signature verification
├── 4. Compromise Internal Publisher [Difficult]
│   ├── 4.1 Network attack (requires internal access)
│   │   └── Mitigated by: Air gap, firewall
│   └── 4.2 Insider with physical access
│       └── Mitigated by: GPG verification still required
└── 5. Man-in-the-middle internal network [Medium]
    └── Mitigated by: GPG verification on client side
```

### Attack Tree 2: Steal GPG Private Key

```
Goal: Obtain GPG private key for signing malicious bundles
├── 1. Compromise External Builder
│   ├── 1.1 Remote exploitation
│   │   └── Mitigated by: Internet exposure limited to CDN
│   ├── 1.2 Stolen admin credentials
│   │   └── Mitigated by: SSH keys, no password auth
│   └── 1.3 Malicious insider
│       └── Mitigated by: Key stored encrypted, audit logging
├── 2. Physical theft
│   ├── 2.1 Steal server hardware
│   │   └── Mitigated by: Physical security, disk encryption
│   └── 2.2 Steal backup media
│       └── Mitigated by: Encrypted backups
└── 3. Social engineering
    └── 3.1 Trick admin into exporting key
        └── Mitigated by: Procedures, training
```

## Risk Summary

### High Risks

| Risk | Threat | Current Controls | Recommended Actions |
|------|--------|------------------|---------------------|
| Bundle tampering | T2 | GPG signature, BOM | Tamper-evident packaging |
| Publisher spoofing | S2 | Firewall | Add client-side certificate validation |
| GPG key compromise | I3 | Encrypted storage | Consider HSM |

### Medium Risks

| Risk | Threat | Current Controls | Recommended Actions |
|------|--------|------------------|---------------------|
| Disk exhaustion | D2 | Manual cleanup | Automated monitoring and cleanup |
| Manifest disclosure | I1 | Physical control | Encrypt manifests |
| Admin repudiation | R1 | Audit logs | SIEM integration, log signing |

### Accepted Risks

| Risk | Justification |
|------|---------------|
| HTTP (not HTTPS) for internal | Network is trusted, GPG provides integrity |
| No client authentication | Network segmentation provides access control |
| Single GPG key | Operational simplicity; key rotation process exists |

## Security Controls Summary

### Preventive Controls

- Air gap isolation
- GPG signing and verification
- SHA256 checksums (BOM)
- SSH key-only authentication
- Firewall deny-by-default
- SELinux enforcing
- STIG hardening

### Detective Controls

- Audit logging (JSON format)
- OpenSCAP compliance scanning
- Bundle verification
- Signature validation

### Corrective Controls

- Bundle rollback capability
- GPG key rotation procedures
- Incident response process
- Backup and restore procedures

## Review Schedule

This threat model should be reviewed:
- Annually
- After significant architecture changes
- After security incidents
- When new threats are identified

## Related Documentation

- [Security Boundary](security_boundary.md)
- [NIST 800-53 Mapping](nist_80053_mapping.md)
- [Minimal SSP](minimal_ssp.md)
- [Architecture](architecture.md)
