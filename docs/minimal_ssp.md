# Minimal System Security Plan (SSP)

## Document Information

| Field | Value |
|-------|-------|
| System Name | Airgapped RPM Repository System |
| System Identifier | ARRS-001 |
| Version | 1.0 |
| Date | 2024-01-01 |
| Classification | UNCLASSIFIED |
| Security Categorization | MODERATE |

## 1. System Description

### 1.1 Purpose

The Airgapped RPM Repository System provides secure distribution of Red Hat Enterprise Linux (RHEL) software packages to hosts operating in an isolated (airgapped) network environment. The system ensures that software updates can be safely transferred from internet-connected sources to airgapped hosts while maintaining integrity and authenticity.

### 1.2 System Function

The system performs the following functions:
- Synchronizes RHEL packages from Red Hat Content Delivery Network
- Collects package inventories from internal hosts
- Computes required updates based on host inventories
- Creates cryptographically signed bundles for physical transfer
- Verifies bundle integrity and authenticity
- Serves packages via HTTP repository to internal hosts
- Manages lifecycle channels (development, production)

### 1.3 System Components

| Component | Type | Location | Function |
|-----------|------|----------|----------|
| External Builder | Virtual Machine | Semi-trusted network | CDN sync, bundle creation |
| Internal Publisher | Virtual Machine | Airgapped network | Repository serving |
| Hand-Carry Media | Physical USB/DVD | Physical transport | Bundle transfer |
| Internal Hosts | Various | Airgapped network | Package consumers |

## 2. System Boundary

### 2.1 Authorization Boundary

The authorization boundary includes:

**Within Boundary:**
- External Builder VM and all installed software
- Internal Publisher VM and all installed software
- Hand-carry media during transfer operations
- Network connections between Internal Publisher and Internal Hosts
- All data stored on system components

**Outside Boundary:**
- Red Hat Content Delivery Network
- VMware virtualization infrastructure
- Physical network infrastructure
- User workstations (except during administrative sessions)
- Internal host operating systems (beyond repository client)

### 2.2 Boundary Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AUTHORIZATION BOUNDARY                               │
│                                                                              │
│  ┌──────────────────────┐        Physical         ┌──────────────────────┐  │
│  │   EXTERNAL BUILDER   │         Media           │  INTERNAL PUBLISHER  │  │
│  │                      │◄──────────────────────►│                      │  │
│  │  - Sync scripts      │     (Hand-Carry)       │  - Import scripts    │  │
│  │  - Build scripts     │                        │  - Verify scripts    │  │
│  │  - GPG private key   │                        │  - HTTP server       │  │
│  │  - Mirror storage    │                        │  - Repository data   │  │
│  │  - Manifest storage  │                        │  - Lifecycle mgmt    │  │
│  └──────────┬───────────┘                        └──────────┬───────────┘  │
│             │                                               │               │
│             │ HTTPS                                         │ HTTP          │
│             ▼                                               ▼               │
│  ┌──────────────────────┐                        ┌──────────────────────┐  │
│  │    Red Hat CDN       │                        │   Internal Hosts     │  │
│  │   (Outside Boundary) │                        │   (Client portion    │  │
│  └──────────────────────┘                        │    within boundary)  │  │
│                                                  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 3. Trust Zones

### 3.1 Zone Definitions

| Zone | Trust Level | Components | Security Posture |
|------|-------------|------------|------------------|
| Untrusted | None | Internet, Red Hat CDN | No trust assumed; all data verified |
| Semi-Trusted | Limited | External Builder | Controlled internet access; monitored |
| Trusted | High | Internal Publisher, Internal Hosts | Air-gapped; no external connectivity |

### 3.2 Zone Transitions

| From | To | Mechanism | Verification |
|------|-----|-----------|--------------|
| Untrusted → Semi-Trusted | HTTPS + subscription-manager | Red Hat GPG signatures |
| Semi-Trusted → Trusted | Physical media | GPG signatures, BOM checksums |
| Trusted → Semi-Trusted | Physical media | SHA256 checksums |

## 4. Roles and Responsibilities

### 4.1 Role Definitions

| Role | Responsibilities | Access Level |
|------|------------------|--------------|
| System Owner | Overall accountability, risk acceptance | Policy |
| Security Officer | Security oversight, compliance | Review |
| External Builder Admin | CDN sync, bundle creation, GPG key management | Root on External Builder |
| Internal Publisher Admin | Bundle import, repository management | Root on Internal Publisher |
| System Administrator | VM management, OS maintenance | VMware admin |
| End User | Package installation | User on Internal Hosts |

### 4.2 Separation of Duties

| Action | Required Roles | Rationale |
|--------|----------------|-----------|
| GPG key creation | External Builder Admin + Security Officer | Key protection |
| Bundle creation | External Builder Admin | Authorized content only |
| Bundle import | Internal Publisher Admin | Verification required |
| Promotion to production | Internal Publisher Admin + Change approval | Change control |
| Compliance review | Security Officer | Independent verification |

## 5. Data Flows

### 5.1 Content Sync Flow

```
Source: Red Hat CDN
Destination: External Builder
Protocol: HTTPS (TLS 1.2+)
Authentication: Subscription certificate
Data: RPM packages, repository metadata
Verification: Red Hat GPG signatures
Frequency: Weekly or as needed
```

### 5.2 Bundle Transfer Flow

```
Source: External Builder
Destination: Internal Publisher
Protocol: Physical media (USB, DVD)
Authentication: GPG signature verification
Data: Signed bundle (packages, metadata, BOM)
Verification: GPG signature + SHA256 checksums
Frequency: Weekly or as needed
```

### 5.3 Repository Serving Flow

```
Source: Internal Publisher
Destination: Internal Hosts
Protocol: HTTP (port 8080)
Authentication: None (network trust)
Data: RPM packages, repository metadata
Verification: GPG signatures on metadata
Frequency: On-demand
```

### 5.4 Manifest Collection Flow

```
Source: Internal Hosts
Destination: External Builder
Protocol: Physical media (USB)
Authentication: SHA256 checksum
Data: Package inventory (JSON)
Verification: Checksum verification
Frequency: As needed
```

## 6. Operational Assumptions

### 6.1 Security Assumptions

1. **Physical Security**: External Builder and Internal Publisher are located in physically secured facilities with appropriate access controls.

2. **Personnel Security**: All administrators have appropriate clearances and have completed security awareness training.

3. **Media Handling**: Hand-carry media is handled by authorized personnel following documented procedures.

4. **Network Isolation**: The internal network is properly air-gapped with no electronic connection to external networks.

5. **Red Hat Trust**: Red Hat CDN and GPG signatures are trustworthy sources for RHEL content.

### 6.2 Operational Assumptions

1. **Patch Frequency**: Bundles are created and transferred at least monthly.

2. **Testing**: All bundles are tested in development channel before production promotion.

3. **Backup**: System configurations and data are backed up according to policy.

4. **Monitoring**: Systems are monitored for availability and security events.

5. **Incident Response**: Procedures exist for responding to security incidents.

## 7. Security Controls Summary

### 7.1 Technical Controls

| Control Family | Controls Implemented |
|----------------|---------------------|
| Access Control (AC) | SSH key auth, service accounts, firewall |
| Audit (AU) | JSON audit logs, systemd journal |
| Configuration Management (CM) | STIG baselines, OpenSCAP |
| Identification & Authentication (IA) | SSH keys, no password auth |
| System & Communications Protection (SC) | Air gap, GPG encryption/signing |
| System & Information Integrity (SI) | GPG verification, BOM checksums |

### 7.2 Operational Controls

| Control Family | Controls Implemented |
|----------------|---------------------|
| Awareness & Training (AT) | Admin training, procedures |
| Contingency Planning (CP) | Backups, recovery procedures |
| Incident Response (IR) | Response procedures, logging |
| Maintenance (MA) | Patching, hardening |
| Media Protection (MP) | Physical handling procedures |
| Physical Protection (PE) | Facility security |

### 7.3 Management Controls

| Control Family | Controls Implemented |
|----------------|---------------------|
| Planning (PL) | This SSP, policies |
| Program Management (PM) | Security oversight |
| Risk Assessment (RA) | Threat model, risk analysis |
| Security Assessment (CA) | OpenSCAP scans, reviews |

## 8. Interconnections

### 8.1 External Interconnections

| System | Direction | Protocol | Data | Security |
|--------|-----------|----------|------|----------|
| Red Hat CDN | Outbound from External Builder | HTTPS | RPM packages | TLS, GPG verification |

### 8.2 Internal Interconnections

| System | Direction | Protocol | Data | Security |
|--------|-----------|----------|------|----------|
| Internal Hosts | Inbound to Internal Publisher | HTTP | Package requests | Network segmentation |

## 9. Ports and Protocols

### 9.1 External Builder

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22/tcp | SSH | Inbound | Administration |
| 443/tcp | HTTPS | Outbound | Red Hat CDN |

### 9.2 Internal Publisher

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 22/tcp | SSH | Inbound | Administration |
| 8080/tcp | HTTP | Inbound | Repository serving |

## 10. Cryptographic Standards

### 10.1 Algorithms in Use

| Purpose | Algorithm | Key Size | Standard |
|---------|-----------|----------|----------|
| Package signing | RSA | 4096-bit | GPG |
| Bundle signing | RSA | 4096-bit | GPG |
| Checksums | SHA-256 | 256-bit | FIPS 180-4 |
| Transport | TLS 1.2+ | 256-bit | FIPS 140-2 |
| SSH | Ed25519 or RSA | 256-bit / 4096-bit | FIPS 186-4 |

### 10.2 Key Management

| Key | Location | Protection | Rotation |
|-----|----------|------------|----------|
| GPG Private Key | External Builder | Encrypted filesystem | Annual or on compromise |
| GPG Public Key | Internal Publisher, clients | Public distribution | With private key |
| SSH Host Keys | All systems | File permissions | On reinstall |
| SSH User Keys | Admin workstations | Passphrase protected | Annual |

## 11. Compliance

### 11.1 Applicable Standards

- NIST SP 800-53 Rev 5 (Moderate baseline)
- DISA RHEL 9 STIG
- FIPS 140-2 (cryptographic modules)

### 11.2 Compliance Verification

| Method | Frequency | Responsibility |
|--------|-----------|----------------|
| OpenSCAP STIG scan | Monthly | Internal Publisher Admin |
| Manual STIG review | Quarterly | Security Officer |
| Audit log review | Weekly | Security Officer |
| Configuration review | Monthly | System Administrator |

## 12. Contingency Planning

### 12.1 Backup Strategy

| Data | Frequency | Retention | Location |
|------|-----------|-----------|----------|
| Configuration | Daily | 30 days | Secure storage |
| GPG Keys | On change | Indefinite | Offline secure storage |
| Repository data | Weekly | 2 versions | Local + offsite |
| Audit logs | Daily | 1 year | Centralized logging |

### 12.2 Recovery Objectives

| Metric | Target |
|--------|--------|
| Recovery Time Objective (RTO) | 24 hours |
| Recovery Point Objective (RPO) | 1 week |

## 13. Incident Response

### 13.1 Security Events

| Event | Response |
|-------|----------|
| GPG key compromise | Immediate key rotation, bundle re-signing |
| Unauthorized bundle import | System isolation, investigation |
| System compromise | Isolation, forensics, rebuild |

### 13.2 Escalation

| Severity | Response Time | Escalation |
|----------|---------------|------------|
| Critical | 1 hour | Security Officer, System Owner |
| High | 4 hours | Security Officer |
| Medium | 24 hours | System Administrator |
| Low | 5 business days | System Administrator |

## 14. Document Maintenance

This SSP shall be reviewed and updated:
- Annually
- Upon significant system changes
- Following security incidents
- When referenced standards are updated

## 15. Approval

| Role | Name | Signature | Date |
|------|------|-----------|------|
| System Owner | | | |
| Security Officer | | | |
| Authorizing Official | | | |

## Related Documentation

- [Architecture](architecture.md)
- [Security Boundary](security_boundary.md)
- [Threat Model](threat_model.md)
- [NIST 800-53 Mapping](nist_80053_mapping.md)
- [Operations](operations.md)
