# Blocking Condition Analysis

## Issue

**Blocking Condition:** PowerShell Core (pwsh) is not available in the execution environment.

## Classification

**Issue Type:** Missing environment dependency

This is NOT:
- A documentation error (docs correctly specify pwsh requirement)
- An automation bug (operator.ps1 script exists and is syntactically valid)

## Evidence

```
$ pwsh --version
/bin/bash: line 1: pwsh: command not found
Exit code: 127
```

## Impact

All three operator commands are BLOCKED:
1. `operator.ps1 validate-spec`
2. `operator.ps1 guide-validate`  
3. `operator.ps1 e2e`

No test evidence can be generated without PowerShell.

## Minimal Corrective Actions

### Option A: Install PowerShell in binhex-dev (Recommended)

Add to binhex-dev Dockerfile:
```dockerfile
# Install PowerShell Core
RUN apt-get update && apt-get install -y wget apt-transport-https software-properties-common && \
    wget -q "https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb" && \
    dpkg -i packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y powershell && \
    rm packages-microsoft-prod.deb
```

### Option B: Run tests on host with PowerShell

Execute operator.ps1 directly on a Windows host or WSL with pwsh installed.

### Option C: Create bash equivalent automation

Port operator.ps1 logic to bash scripts that can run in the current environment.

## Recommendation

**Option A** is recommended because:
1. binhex-tools already has PowerShell installed
2. Maintains single test automation toolchain
3. No code changes required to operator.ps1

## Verification Command

After installing pwsh:
```bash
pwsh --version
pwsh ./scripts/operator.ps1 validate-spec
```
