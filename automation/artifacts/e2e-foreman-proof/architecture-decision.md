# Architecture Decision: Foreman+Katello E2E Proof

## Date: 2025-12-31

## RHEL CDN Sync Status: BLOCKED

### Evidence

```
Foreman Server RHSM Status:
  Overall Status: Registered
  Content Access Mode: Simple Content Access (SCA)
  Consumed Subscriptions: 0

Katello Subscription Manifests:
  - CentOS Stream (Physical, Unlimited) - OK
  - Red Hat subscriptions: NONE

Tester VMs:
  - rhel8-10-tester (192.168.1.87): RHEL 8.10, NOT registered with RHSM
  - rhel9-6-tester (192.168.1.117): RHEL 9.6, NOT registered with RHSM
```

### Minimum Requirements to Unblock RHEL CDN Sync

1. **Red Hat Developer Subscription** (free, 16 systems) or **Paid RHEL Subscription**
2. **Create a Subscription Manifest** at https://access.redhat.com/management/subscription_allocations
3. **Download and import manifest** into Katello:
   ```bash
   hammer subscription upload --organization "Default Organization" --file manifest.zip
   ```
4. **Enable RHEL repositories** via Katello:
   ```bash
   hammer repository-set enable --organization "Default Organization" \
     --product "Red Hat Enterprise Linux for x86_64" \
     --name "Red Hat Enterprise Linux 8 for x86_64 - BaseOS (RPMs)" \
     --basearch x86_64 --releasever 8.10
   ```

### Alternative Approach for E2E Proof (SELECTED)

Since RHEL CDN sync is blocked, this E2E proof will use:

| Content Source | Purpose |
|----------------|---------|
| CentOS Stream 9 | RHEL 9-compatible content |
| CentOS Stream 8 | RHEL 8-compatible content (if available) |

This demonstrates the complete airgap workflow (export/import/patch) while using
freely available, RHEL-compatible content sources.

## Internal Architecture Decision

### Selected: Full Foreman+Katello on Internal (Option 2)

**Rationale:**
1. Smart Proxy with Katello plugin does NOT support disconnected content import
2. Katello content export produces archives designed for import by another Katello instance
3. Full Foreman+Katello on internal provides:
   - Complete content lifecycle management
   - Errata and package metadata preservation
   - Content View versioning
   - Standard `hammer content-import` workflow

**Trade-off:** Higher resource requirements on internal (8GB+ RAM), but cleaner
and officially supported disconnected workflow.

## Component Summary

| Role | VM | IP | Software |
|------|----|----|----------|
| External (connected) | satellite-server | 192.168.1.119 | Foreman 3.11.5 + Katello 4.13.1 |
| Internal (disconnected) | capsule-server | 192.168.1.249 | Foreman 3.11.5 + Katello 4.13.1 |
| Tester RHEL 8 | rhel8-10-tester | 192.168.1.87 | RHEL 8.10 |
| Tester RHEL 9 | rhel9-6-tester | 192.168.1.117 | RHEL 9.6 |
