# E2E Proof Run Instructions

## Current Status

**INFRASTRUCTURE: DEPLOYED**

| Component | IP Address | OS | Status |
|-----------|------------|-----|--------|
| Satellite Server | 192.168.1.119 | RHEL 9.6 | VM ready, SSH accessible |
| Capsule Server | 192.168.1.249 | RHEL 9.6 | VM ready, SSH accessible |
| Tester RHEL 8 | 192.168.1.87 | RHEL 8.10 | VM ready, SSH accessible |
| Tester RHEL 9 | 192.168.1.117 | RHEL 9.6 | VM ready, SSH accessible |

**PHASES 1-6: COMPLETE** - All implementation artifacts created

**PHASE 7 STATUS: REQUIRES RED HAT SUBSCRIPTION**

The infrastructure is deployed and ready. To complete the E2E proof, you need:
1. Red Hat subscription with Satellite entitlements
2. Manifest file from Red Hat Customer Portal

## SSH Access

All VMs are accessible via SSH with key-based authentication:

```bash
# From binhex-dev container or Windows operator laptop
ssh dev1@192.168.1.119  # Satellite
ssh dev1@192.168.1.249  # Capsule
ssh dev1@192.168.1.87   # RHEL 8 tester
ssh dev1@192.168.1.117  # RHEL 9 tester
```

SSH key: `binhex-dev/ssh/id_ed25519`

## To Complete E2E Proof

### Step 1: Register Systems with Red Hat

```bash
# On Satellite server
ssh dev1@192.168.1.119
sudo subscription-manager register --org=<ORG_ID> --activationkey=<KEY>
# OR
sudo subscription-manager register --username=<RHSM_USER> --password=<RHSM_PASS>
```

### Step 2: Install Satellite

```bash
# On Satellite server
cd ~/satellite-setup
sudo ./satellite-install.sh --manifest /path/to/manifest.zip
```

### Step 3: Configure Content and Sync

```bash
# On Satellite server
sudo ~/satellite-setup/satellite-configure-content.sh \
  --org "Default Organization" \
  --sync \
  --create-cv
```

### Step 4: Export Bundle

```bash
# On Satellite server
sudo ~/satellite-setup/satellite-export-bundle.sh \
  --org "Default Organization" \
  --lifecycle-env prod
```

### Step 5: Transfer and Import on Capsule

```bash
# Copy bundle to Capsule (simulating USB transfer)
scp dev1@192.168.1.119:/var/lib/pulp/exports/*.tar.gz dev1@192.168.1.249:~/

# On Capsule server
ssh dev1@192.168.1.249
sudo ~/capsule-setup/capsule-import-bundle.sh --bundle ~/airgap-security-bundle-*.tar.gz
```

### Step 6: Patch Testers

From the management host with Ansible:
```bash
cd /srv/airgap/ansible
ansible-playbook -i inventories/lab.yml playbooks/patch_monthly_security.yml
```

Or manually:
```bash
# On testers
ssh dev1@192.168.1.87  # RHEL 8
sudo dnf update --security -y

ssh dev1@192.168.1.117  # RHEL 9
sudo dnf update --security -y
```

### Step 7: Collect Evidence

```bash
# Satellite evidence
ssh dev1@192.168.1.119 'hammer content-view version list --organization "Default Organization"'
ssh dev1@192.168.1.119 'hammer repository list --organization "Default Organization"'

# Capsule evidence
ssh dev1@192.168.1.249 'dnf repolist'

# Tester evidence
ssh dev1@192.168.1.87 'dnf updateinfo list security'
ssh dev1@192.168.1.117 'dnf updateinfo list security'
```

## PowerShell E2E Script

For Windows operators, use the PowerShell script:

```powershell
$env:VMWARE_USER = "administrator@vsphere.local"
$env:VMWARE_PASSWORD = "your-password"

.\scripts\e2e-satellite-proof.ps1 `
  -SatelliteIP 192.168.1.119 `
  -CapsuleIP 192.168.1.249 `
  -TesterRhel8IP 192.168.1.87 `
  -TesterRhel9IP 192.168.1.117
```

## Bash E2E Script

For Linux/macOS:

```bash
./scripts/e2e-proof-simple.sh \
  --satellite 192.168.1.119 \
  --capsule 192.168.1.249 \
  --tester-rhel8 192.168.1.87 \
  --tester-rhel9 192.168.1.117 \
  --user dev1
```

## What Was Accomplished

1. **VM Deployment**: 4 VMs deployed from RHEL templates via vSphere
2. **SSH Configuration**: SSH key-based access configured on all VMs
3. **Script Distribution**: Satellite and Capsule setup scripts deployed
4. **Infrastructure Documentation**: Evidence collected in `infrastructure/status.txt`

## What Remains (Requires Subscription)

1. Red Hat subscription registration
2. Satellite software installation
3. Content sync from Red Hat CDN
4. Content View publication
5. Bundle export/import workflow
6. Security patching demonstration

## Evidence Locations

```
automation/artifacts/e2e-satellite-proof/
├── infrastructure/
│   └── status.txt       # Current VM status
├── satellite/           # (populated after Satellite setup)
├── capsule/             # (populated after Capsule import)
├── testers/             # (populated after patching)
└── INSTRUCTIONS.md      # This file
```
