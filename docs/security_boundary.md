# Security Boundary Definition

This document defines the security boundaries, trust relationships, and data flows for the Airgapped RPM Repository System.

## System Boundary

### Components Within Boundary

1. **External Builder**
   - Internet-connected system
   - Syncs from Red Hat CDN
   - Creates signed bundles

2. **Hand-Carry Media**
   - Signed bundle archives
   - GPG public keys
   - Host manifests

3. **Internal Publisher**
   - Airgapped RHEL 9.6 VM
   - Serves repositories
   - Manages lifecycle channels

4. **Internal Hosts**
   - RHEL 8.10 and 9.6 systems
   - Consume packages from publisher

### Components Outside Boundary

- Red Hat CDN (upstream source)
- VMware infrastructure (hosting)
- Network infrastructure
- User workstations

## Trust Zones

```
┌─────────────────────────────────────────────────────────────────────┐
│                         UNTRUSTED ZONE                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                        Internet                              │    │
│  │                     Red Hat CDN                              │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      SEMI-TRUSTED ZONE                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                   External Builder                           │    │
│  │  - Internet access (controlled)                              │    │
│  │  - Authenticated to Red Hat                                  │    │
│  │  - Creates signed bundles                                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                     Air Gap (Hand-Carry Only)
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         TRUSTED ZONE                                 │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                  Internal Publisher                          │    │
│  │  - No internet access                                        │    │
│  │  - Verifies bundle signatures                                │    │
│  │  - Serves to internal hosts                                  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Internal Hosts                            │    │
│  │  - Consume packages from publisher                           │    │
│  │  - Generate manifests                                        │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Data Flows

### Flow 1: Content Sync

```
Red Hat CDN → External Builder
Protocol: HTTPS
Authentication: subscription-manager
Data: RPM packages, metadata
Trust: Red Hat GPG signatures verified
```

### Flow 2: Bundle Transfer

```
External Builder → Hand-Carry Media → Internal Publisher
Protocol: Physical media
Authentication: GPG signature verification
Data: Signed bundle archive
Trust: Organization's GPG key, BOM checksums
```

### Flow 3: Repository Serving

```
Internal Publisher → Internal Hosts
Protocol: HTTP/HTTPS
Authentication: None (network-level trust)
Data: RPM packages, metadata
Trust: Repository GPG signatures
```

### Flow 4: Manifest Collection

```
Internal Hosts → Hand-Carry Media → External Builder
Protocol: Physical media
Authentication: SHA256 checksums
Data: Package inventory, system info
Trust: Manifest checksums, controlled process
```

## Trust Relationships

### What We Trust

1. **Red Hat CDN**
   - Authentic RHEL packages
   - Valid GPG signatures
   - Correct metadata

2. **Organization's GPG Key**
   - Private key secured on External Builder
   - Public key distributed to Internal Publisher
   - All bundles signed by this key

3. **Physical Media Handling**
   - Authorized personnel only
   - Documented transfer procedures
   - Tamper-evident packaging (if required)

### What We Verify

1. **Bundle Integrity**
   - SHA256 checksums (Bill of Materials)
   - GPG signature on bundle archive
   - GPG signatures on repository metadata

2. **Package Authenticity**
   - Red Hat GPG signatures (original packages)
   - Repository metadata signatures

3. **Manifest Integrity**
   - SHA256 checksums
   - Valid JSON structure

## Attack Vectors and Mitigations

### Supply Chain Attacks

| Threat | Mitigation |
|--------|------------|
| Compromised Red Hat packages | Red Hat GPG verification |
| Tampered bundles | GPG signature + BOM verification |
| Modified manifests | SHA256 checksums |
| Counterfeit media | Physical security, verified checksums |

### Network Attacks

| Threat | Mitigation |
|--------|------------|
| Man-in-the-middle | Air gap (no network path) |
| Network intrusion | No outbound from internal |
| Unauthorized access | Firewall, SSH key-only |

### Insider Threats

| Threat | Mitigation |
|--------|------------|
| Unauthorized bundle creation | GPG key access controls |
| Malicious package injection | Signature verification required |
| Data exfiltration | No network path out |

## Security Controls

### Cryptographic Controls

- SHA256 for all checksums
- GPG (RSA 4096-bit) for signatures
- Strong SSH key authentication
- FIPS 140-2 compliant crypto

### Access Controls

- Root access via SSH key only
- Service accounts with no login
- SELinux enforcing
- Firewall deny-by-default

### Audit Controls

- All administrative actions logged
- Repository changes audited
- Bundle operations recorded
- Centralized audit log

## Roles and Responsibilities

### External Builder Administrator

- Manages subscription-manager registration
- Performs content synchronization
- Creates and signs bundles
- Protects GPG private key

### Internal Publisher Administrator

- Imports and verifies bundles
- Manages lifecycle channels
- Generates client configuration
- Monitors system health

### Security Administrator

- Reviews audit logs
- Runs compliance scans
- Manages GPG key lifecycle
- Responds to incidents

### End Users

- Install client configuration
- Apply updates as directed
- Report issues

## Operational Assumptions

1. Physical security of External Builder is maintained
2. Hand-carry media procedures are followed
3. Internal network is segregated
4. Personnel are authorized and trained
5. Incident response procedures exist

## Related Documentation

- [Architecture](architecture.md)
- [NIST 800-53 Mapping](nist_80053_mapping.md)
- [Threat Model](threat_model.md)
- [Minimal SSP](minimal_ssp.md)
