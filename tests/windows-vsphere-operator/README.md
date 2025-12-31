# Windows vSphere Operator Test Harness

> **WARNING**: This is a TESTING-ONLY harness for CI-like validation.
> It is **NOT** part of the production operator workflow.
> The primary workflow uses a Windows 11 laptop directly.

## Purpose

This test harness allows running `operator.ps1` commands from a Windows 11 VM
deployed in vSphere. This is useful for:

- CI/CD pipeline integration
- Automated regression testing
- Isolated test environments

## Prerequisites

1. PowerShell 7+
2. VMware PowerCLI module (for VM-based testing)
3. SSH client configured for Windows VM access
4. `VMWARE_USER` and `VMWARE_PASSWORD` environment variables

## Usage

### Local Mode (Development)

Run tests locally without deploying a Windows VM:

```powershell
.\tests\windows-vsphere-operator\run.ps1 -SkipVMDeploy
```

### VM Mode

Use an existing Windows 11 VM:

```powershell
.\tests\windows-vsphere-operator\run.ps1 -VMName "win11-test-01"
```

Deploy a new VM from template:

```powershell
.\tests\windows-vsphere-operator\run.ps1 -DeployNew -TemplateVM "win11-operator-template"
```

## Tests Performed

1. `operator.ps1 -Help` - Verify help output
2. `operator.ps1 validate-spec` - Validate spec.yaml
3. `operator.ps1 guide-validate` - Validate operator guides

## Artifacts

Test results are written to:

```
automation/artifacts/windows-vsphere-test/
  test-run.log     # Detailed execution log
  report.json      # JSON test report
```

## Windows VM Requirements

If using VM-based testing, the Windows 11 VM must have:

1. PowerShell 7+ installed
2. SSH server enabled
3. Project cloned to `C:\airgapped-rpm-repo`
4. Required modules installed:
   - `powershell-yaml`
   - `VMware.PowerCLI` (optional)

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-VMName` | Specific VM to use | Auto-detect |
| `-TemplateVM` | Template for new VM | `win11-operator-template` |
| `-DeployNew` | Deploy new VM from template | `$false` |
| `-SkipVMDeploy` | Run locally without VM | `$false` |
| `-WaitSeconds` | Wait after new VM deployment | `180` |
| `-SSHUser` | SSH username | `operator` |
| `-SSHKeyPath` | SSH private key path | (password auth) |
