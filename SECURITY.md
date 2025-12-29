# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability in the Airgapped RPM Repository System, please report it responsibly.

### How to Report

1. **Do NOT** create a public GitHub issue for security vulnerabilities.

2. **Email**: Send details to [security contact - to be configured]

3. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Any suggested mitigations

### What to Expect

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 5 business days
- **Status Updates**: Every 7 days until resolved
- **Resolution Target**: 30-90 days depending on severity

### Severity Classification

| Severity | Response Time | Examples |
|----------|---------------|----------|
| Critical | 24 hours | GPG key exposure, remote code execution |
| High | 48 hours | Authentication bypass, privilege escalation |
| Medium | 5 days | Information disclosure, denial of service |
| Low | 30 days | Minor configuration issues |

## Security Considerations

### Design Security

This system is designed for airgapped environments with the following security properties:

1. **Air Gap**: Internal Publisher has no network connectivity to external systems
2. **Cryptographic Verification**: All bundles are GPG-signed and checksum-verified
3. **Defense in Depth**: Multiple verification layers (Red Hat GPG, organization GPG, BOM)
4. **Least Privilege**: Service accounts with minimal permissions

### Operational Security

- GPG private keys should be protected with strong passphrases
- Hand-carry media should follow chain-of-custody procedures
- Audit logs should be reviewed regularly
- STIG compliance should be verified monthly

### Known Limitations

1. **HTTP Repository Serving**: The Internal Publisher serves content over HTTP (not HTTPS). This is acceptable in airgapped environments where network trust is established through physical isolation. GPG signatures provide integrity verification.

2. **No Client Authentication**: Repository clients are not authenticated. Access control relies on network segmentation.

3. **Single GPG Key**: The system uses a single GPG key for signing. Consider HSM integration for enhanced key protection.

## Security Updates

Security updates for system dependencies should be applied promptly:

```bash
# On External Builder (internet-connected)
dnf update --security

# Create emergency bundle if critical updates exist
make export BUNDLE_NAME=security-$(date +%Y%m%d)
```

## Compliance

The system is designed to support:

- NIST SP 800-53 (Moderate baseline)
- DISA RHEL 9 STIG

See [docs/nist_80053_mapping.md](docs/nist_80053_mapping.md) for control mappings.

## Security Contacts

- System Administrator: [To be configured]
- Security Officer: [To be configured]

## Related Documentation

- [Threat Model](docs/threat_model.md)
- [Security Boundary](docs/security_boundary.md)
- [Minimal SSP](docs/minimal_ssp.md)
