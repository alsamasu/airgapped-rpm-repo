# Airgapped-Deps Tests

Validation tests for the air-gapped dependencies workflow.

## Tests

| Test | Description |
|------|-------------|
| `test-structure.ps1` | Validates airgapped-deps/ directory structure and scripts |
| `test-build-script.ps1` | Validates scripts/build-airgapped-deps.ps1 |

## Running Tests

### On Windows (PowerShell 5.1+)

```powershell
# Run all tests
.\test-structure.ps1
.\test-build-script.ps1
```

### On Linux/macOS (PowerShell Core)

```bash
pwsh tests/airgapped-deps/test-structure.ps1
pwsh tests/airgapped-deps/test-build-script.ps1
```

## What These Tests Verify

### Structure Test
- Required files exist (install-deps.ps1, verify.ps1, etc.)
- Required directories exist (powershell/, powercli/, checksums/)
- PowerShell syntax is valid
- No forbidden tool references

### Build Script Test
- PowerShell syntax is valid
- Downloads PowerShell MSI
- Downloads VMware.PowerCLI
- Generates checksums
- Creates install script
- Does NOT download forbidden tools (Git, Python, etc.)

## Note

These tests validate structure and syntax only. They do NOT:
- Actually download packages (requires internet)
- Actually install software (requires Windows admin)
- Run on an air-gapped system
