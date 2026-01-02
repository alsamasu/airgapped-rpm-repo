# E2E Deployment Defects

## DEFECT-001: RHEL 9.6 Automated Kickstart Deployment Fails [RESOLVED]

### Guide Reference
- docs/deployment_guide.md - Server deployment section
- automation/powercli/deploy-rpm-servers.ps1

### Symptom
VMs rpm-external and rpm-internal remain stuck after power-on with:
- No guest OS detection
- No IP address assigned
- No VMware Tools status

### Root Cause Analysis
The RHEL 9.6 installer does not automatically detect and use a kickstart file from
an OEMDRV-labeled CD-ROM without explicit kernel boot parameters (`inst.ks=...`).

The deployment workflow attempts to:
1. Generate kickstart ISO labeled "OEMDRV" with ks.cfg
2. Mount RHEL 9.6 DVD + kickstart ISO to VM
3. Power on VM expecting automated installation

However, RHEL 9.6 requires one of:
- Modified RHEL ISO with embedded kickstart boot menu entry
- Kernel parameter `inst.ks=cdrom:/dev/sr1:/ks.cfg` passed at boot
- PXE boot with kickstart URL
- Manual boot menu intervention

### Resolution Applied
**Option A was implemented: Custom Boot ISOs with Embedded Kickstart Parameters**

Modified RHEL 9.6 boot ISOs were created with `inst.ks=cdrom:/dev/sr1:/ks.cfg`
embedded in the boot menu entries. These custom ISOs are included in the
`airgapped-deps.zip` package.

Deployment workflow updated to:
1. Mount custom boot ISO as primary CD (for bootloader with embedded ks param)
2. Mount kickstart OEMDRV ISO as secondary CD (with ks.cfg file)
3. Mount RHEL 9.6 DVD as third CD (installation source)

### Status
**RESOLVED** - Custom boot ISOs enable fully automated kickstart deployment

### Resolution Date
2025-12-31

---

## DEFECT-002: SSH Authentication from Container Environment [ACTIVE]

### Symptom
SSH password authentication fails when connecting from Claude Code container
(172.20.0.x network) to VMs (192.168.1.x network).

```
sshpass: detected prompt, again. Wrong password. Terminating.
Permission denied, please try again.
```

### Evidence
- Network connectivity verified (HTTP access works to 192.168.1.22)
- SSH port 22 is accessible
- Password authentication is enabled on VMs
- Same password works from Windows operator machine

### Impact
- Phase 6 (Internal Import): BLOCKED
- Phase 7 (Ansible Patch): BLOCKED

### Root Cause Analysis
The password `12qwaszx!@QWASZX` works from the Windows operator machine but
fails from the container environment. Possible causes:
1. SSH key requirements added that weren't present before
2. PAM or firewall rules limiting source IP ranges
3. Character encoding differences in password handling

### Workaround
Continue remaining phases from Windows operator machine (192.168.1.171)
which has verified working SSH access.

### Status
**ACTIVE** - Blocking container-based automation

### Timestamp
2025-12-31T18:45:00Z

---

## Progress Summary

| Defect | Status | Impact |
|--------|--------|--------|
| DEFECT-001 | RESOLVED | Phase 3 unblocked |
| DEFECT-002 | ACTIVE | Phases 6-7 blocked from container |
