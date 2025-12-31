<#
.SYNOPSIS
    Shared PowerShell module for Airgapped RPM Repository automation.

.DESCRIPTION
    Provides common functions used by operator.ps1 and individual automation scripts:
    - Read-SpecConfig: Parse spec.yaml configuration
    - Connect-VSphere: Connect to vCenter/ESXi
    - Resolve-IsoPath: Handle local vs datastore ISO paths
    - Write-Artifact: Standardized artifact output
    - Invoke-SubScript: Execute sub-scripts with normalized parameters

.NOTES
    Requires: PowerShell 7+, powershell-yaml module
    For VMware operations: VMware.PowerCLI module
#>

#Requires -Version 7.0

# Module-level variables
$script:ModuleRoot = $PSScriptRoot
$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$script:ArtifactsDir = Join-Path $script:ProjectRoot "automation/artifacts"
$script:DefaultSpecPath = Join-Path $script:ProjectRoot "config/spec.yaml"

# Export module members at the end

function Get-ProjectRoot {
    <#
    .SYNOPSIS
        Returns the project root directory path.
    #>
    return $script:ProjectRoot
}

function Get-ArtifactsDir {
    <#
    .SYNOPSIS
        Returns the artifacts directory path.
    #>
    return $script:ArtifactsDir
}

function Read-SpecConfig {
    <#
    .SYNOPSIS
        Read and parse the spec.yaml configuration file.

    .PARAMETER SpecPath
        Path to the spec.yaml file. Defaults to config/spec.yaml.

    .PARAMETER Validate
        If set, validates required fields and throws on missing values.

    .OUTPUTS
        Hashtable containing the parsed configuration.

    .EXAMPLE
        $config = Read-SpecConfig
        $config.vcenter.server
    #>
    [CmdletBinding()]
    param(
        [string]$SpecPath = $script:DefaultSpecPath,
        [switch]$Validate
    )

    # Ensure powershell-yaml module is available
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "Required module 'powershell-yaml' not found. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    # Resolve and validate path
    if (-not (Test-Path $SpecPath)) {
        throw "Spec file not found: $SpecPath"
    }
    $SpecPath = (Resolve-Path $SpecPath).Path

    # Read and parse YAML
    $yamlContent = Get-Content -Path $SpecPath -Raw
    $config = ConvertFrom-Yaml $yamlContent

    if ($Validate) {
        # Validate required fields
        $requiredFields = @(
            @{ Path = "vcenter.server"; Description = "vCenter/ESXi server address" },
            @{ Path = "vcenter.datastore"; Description = "Datastore name" },
            @{ Path = "isos.rhel96_iso_path"; Description = "RHEL 9.6 ISO path" },
            @{ Path = "credentials.initial_root_password"; Description = "Initial root password" },
            @{ Path = "vm_names.rpm_external"; Description = "External VM name" },
            @{ Path = "vm_names.rpm_internal"; Description = "Internal VM name" }
        )

        $missingFields = @()
        foreach ($field in $requiredFields) {
            $value = Get-NestedValue -Object $config -Path $field.Path
            if ([string]::IsNullOrWhiteSpace($value)) {
                $missingFields += "$($field.Path): $($field.Description)"
            }
        }

        if ($missingFields.Count -gt 0) {
            throw "Missing required configuration fields:`n$($missingFields -join "`n")"
        }
    }

    # Apply defaults
    $config = Set-ConfigDefaults -Config $config

    return $config
}

function Get-NestedValue {
    <#
    .SYNOPSIS
        Get a nested value from a hashtable using dot notation.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Object,
        [string]$Path
    )

    $parts = $Path -split '\.'
    $value = $Object
    foreach ($part in $parts) {
        if ($null -eq $value -or -not ($value -is [hashtable]) -or -not $value.ContainsKey($part)) {
            return $null
        }
        $value = $value[$part]
    }
    return $value
}

function Set-ConfigDefaults {
    <#
    .SYNOPSIS
        Apply default values to configuration.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Config
    )

    # Network defaults
    if (-not $Config.network) { $Config.network = @{} }
    if (-not $Config.network.portgroup_name) { $Config.network.portgroup_name = "LAN" }
    if ($null -eq $Config.network.dhcp) { $Config.network.dhcp = $true }

    # VM sizing defaults
    if (-not $Config.vm_sizing) { $Config.vm_sizing = @{} }
    if (-not $Config.vm_sizing.external) { $Config.vm_sizing.external = @{} }
    if (-not $Config.vm_sizing.external.cpu) { $Config.vm_sizing.external.cpu = 2 }
    if (-not $Config.vm_sizing.external.memory_gb) { $Config.vm_sizing.external.memory_gb = 8 }
    if (-not $Config.vm_sizing.external.disk_gb) { $Config.vm_sizing.external.disk_gb = 200 }

    if (-not $Config.vm_sizing.internal) { $Config.vm_sizing.internal = @{} }
    if (-not $Config.vm_sizing.internal.cpu) { $Config.vm_sizing.internal.cpu = 2 }
    if (-not $Config.vm_sizing.internal.memory_gb) { $Config.vm_sizing.internal.memory_gb = 8 }
    if (-not $Config.vm_sizing.internal.disk_gb) { $Config.vm_sizing.internal.disk_gb = 200 }

    # Internal services defaults
    if (-not $Config.internal_services) { $Config.internal_services = @{} }
    if (-not $Config.internal_services.service_user) { $Config.internal_services.service_user = "rpmops" }
    if (-not $Config.internal_services.data_dir) { $Config.internal_services.data_dir = "/srv/airgap/data" }
    if (-not $Config.internal_services.certs_dir) { $Config.internal_services.certs_dir = "/srv/airgap/certs" }
    if (-not $Config.internal_services.ansible_dir) { $Config.internal_services.ansible_dir = "/srv/airgap/ansible" }

    # HTTPS defaults
    if (-not $Config.https_internal_repo) { $Config.https_internal_repo = @{} }
    if (-not $Config.https_internal_repo.https_port) { $Config.https_internal_repo.https_port = 8443 }
    if (-not $Config.https_internal_repo.http_port) { $Config.https_internal_repo.http_port = 8080 }

    # Credential defaults
    if (-not $Config.credentials) { $Config.credentials = @{} }
    if (-not $Config.credentials.initial_admin_user) { $Config.credentials.initial_admin_user = "admin" }

    # ISO defaults
    if (-not $Config.isos) { $Config.isos = @{} }
    if (-not $Config.isos.iso_datastore_folder) { $Config.isos.iso_datastore_folder = "isos" }

    return $Config
}

function Connect-VSphere {
    <#
    .SYNOPSIS
        Connect to vCenter or ESXi host.

    .PARAMETER Config
        Configuration hashtable from Read-SpecConfig.

    .PARAMETER Server
        Override server from config.

    .PARAMETER Credential
        PSCredential object. If not provided, uses VMWARE_USER/VMWARE_PASSWORD env vars or prompts.

    .OUTPUTS
        VIServer connection object.

    .EXAMPLE
        $conn = Connect-VSphere -Config $config
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$Server,
        [System.Management.Automation.PSCredential]$Credential
    )

    # Import PowerCLI if available
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        throw "VMware.PowerCLI module not found. Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
    }

    # Determine server
    if (-not $Server) {
        if ($Config -and $Config.vcenter -and $Config.vcenter.server) {
            $Server = $Config.vcenter.server
        } else {
            throw "No vCenter/ESXi server specified"
        }
    }

    # Configure PowerCLI session
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session 2>$null | Out-Null
    Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false 2>$null | Out-Null

    # Get credentials
    if (-not $Credential) {
        $vcUser = $env:VMWARE_USER
        $vcPassword = $env:VMWARE_PASSWORD

        if (-not $vcUser) {
            $vcUser = Read-Host "vCenter Username"
        }
        if (-not $vcPassword) {
            $secPassword = Read-Host "vCenter Password" -AsSecureString
            $vcPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPassword)
            )
        }
    } else {
        $vcUser = $Credential.UserName
        $vcPassword = $Credential.GetNetworkCredential().Password
    }

    # Connect
    try {
        $conn = Connect-VIServer -Server $Server -User $vcUser -Password $vcPassword -ErrorAction Stop
        Write-Host "[OK] Connected to $($conn.Name)" -ForegroundColor Green
        return $conn
    } catch {
        throw "Failed to connect to vCenter/ESXi: $_"
    }
}

function Resolve-IsoPath {
    <#
    .SYNOPSIS
        Resolve ISO path - determine if local or datastore path.

    .PARAMETER IsoPath
        The ISO path from configuration.

    .PARAMETER Datastore
        Target datastore for upload if local.

    .PARAMETER IsoFolder
        Folder on datastore for ISOs.

    .PARAMETER Upload
        If set and path is local, upload to datastore.

    .OUTPUTS
        Hashtable with resolved path info.

    .EXAMPLE
        $iso = Resolve-IsoPath -IsoPath "/local/rhel.iso" -Datastore "datastore1" -IsoFolder "isos"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath,
        [string]$Datastore,
        [string]$IsoFolder = "isos",
        [switch]$Upload
    )

    $result = @{
        OriginalPath = $IsoPath
        IsDatastore = $false
        IsLocal = $false
        DatastorePath = $null
        LocalPath = $null
        NeedsUpload = $false
    }

    if ($IsoPath -match '^\[(.+?)\]') {
        # Already a datastore path
        $result.IsDatastore = $true
        $result.DatastorePath = $IsoPath
    } else {
        # Local path
        $result.IsLocal = $true
        $result.LocalPath = $IsoPath

        if (Test-Path $IsoPath) {
            $isoName = Split-Path $IsoPath -Leaf
            $result.DatastorePath = "[$Datastore] $IsoFolder/$isoName"
            $result.NeedsUpload = $Upload
        } else {
            # Assume it might be on remote system or will be on datastore
            $isoName = Split-Path $IsoPath -Leaf
            $result.DatastorePath = "[$Datastore] $IsoFolder/$isoName"
        }
    }

    return $result
}

function Write-Artifact {
    <#
    .SYNOPSIS
        Write artifact file with standardized format.

    .PARAMETER Name
        Artifact name (used as subdirectory under artifacts/).

    .PARAMETER FileName
        Output filename.

    .PARAMETER Content
        Content to write (string or object for JSON).

    .PARAMETER Format
        Output format: text, json, or markdown.

    .OUTPUTS
        Path to the written artifact.

    .EXAMPLE
        Write-Artifact -Name "operator" -FileName "report.json" -Content $report -Format json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$FileName,
        [Parameter(Mandatory)]
        $Content,
        [ValidateSet("text", "json", "markdown")]
        [string]$Format = "text"
    )

    $artifactDir = Join-Path $script:ArtifactsDir $Name
    if (-not (Test-Path $artifactDir)) {
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }

    $outputPath = Join-Path $artifactDir $FileName

    switch ($Format) {
        "json" {
            if ($Content -is [string]) {
                $Content | Out-File -FilePath $outputPath -Encoding utf8
            } else {
                $Content | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding utf8
            }
        }
        "markdown" {
            $Content | Out-File -FilePath $outputPath -Encoding utf8
        }
        default {
            $Content | Out-File -FilePath $outputPath -Encoding utf8
        }
    }

    return $outputPath
}

function Write-OperatorLog {
    <#
    .SYNOPSIS
        Append to operator run log.

    .PARAMETER Message
        Log message.

    .PARAMETER Level
        Log level: INFO, WARN, ERROR, SUCCESS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $logDir = Join-Path $script:ArtifactsDir "operator"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $logPath = Join-Path $logDir "run.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    Add-Content -Path $logPath -Value $logLine

    # Also write to console with colors
    $color = switch ($Level) {
        "INFO" { "Cyan" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Invoke-SubScript {
    <#
    .SYNOPSIS
        Execute a PowerShell sub-script with normalized parameters.

    .PARAMETER ScriptPath
        Path to the script to execute.

    .PARAMETER Parameters
        Hashtable of parameters to pass.

    .PARAMETER WorkingDirectory
        Working directory for script execution.

    .OUTPUTS
        Script exit code.

    .EXAMPLE
        Invoke-SubScript -ScriptPath "./validate-spec.ps1" -Parameters @{ SpecPath = "config/spec.yaml" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [string]$WorkingDirectory
    )

    # Resolve script path
    if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) {
        $ScriptPath = Join-Path $script:ProjectRoot $ScriptPath
    }

    if (-not (Test-Path $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    # Build parameter string
    $paramString = ""
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) {
                $paramString += " -$key"
            }
        } else {
            $paramString += " -$key `"$value`""
        }
    }

    # Execute
    $originalLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }

        $command = "& `"$ScriptPath`"$paramString"
        Invoke-Expression $command

        return $LASTEXITCODE
    } finally {
        Set-Location $originalLocation
    }
}

function Test-RequiredTools {
    <#
    .SYNOPSIS
        Check that required tools are available.

    .PARAMETER Tools
        Array of tool names to check.

    .OUTPUTS
        Hashtable with tool availability status.

    .EXAMPLE
        $status = Test-RequiredTools -Tools @("pwsh", "python3", "make")
    #>
    [CmdletBinding()]
    param(
        [string[]]$Tools = @("pwsh")
    )

    $results = @{}

    foreach ($tool in $Tools) {
        $available = $null -ne (Get-Command $tool -ErrorAction SilentlyContinue)
        $results[$tool] = $available
    }

    return $results
}

function Get-VMwareObjects {
    <#
    .SYNOPSIS
        Get VMware objects (datacenter, cluster, host, datastore) from config.

    .PARAMETER Config
        Configuration hashtable.

    .OUTPUTS
        Hashtable with VMware objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $objects = @{
        Datacenter = $null
        Cluster = $null
        VMHost = $null
        Datastore = $null
        Network = $null
    }

    try {
        if ($Config.vcenter.datacenter) {
            $objects.Datacenter = Get-Datacenter -Name $Config.vcenter.datacenter -ErrorAction Stop
        }

        if ($Config.vcenter.cluster) {
            $objects.Cluster = Get-Cluster -Name $Config.vcenter.cluster -ErrorAction Stop
            $objects.VMHost = Get-VMHost -Location $objects.Cluster | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
        } elseif ($Config.vcenter.host) {
            $objects.VMHost = Get-VMHost -Name $Config.vcenter.host -ErrorAction Stop
        } else {
            $objects.VMHost = Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
        }

        $objects.Datastore = Get-Datastore -Name $Config.vcenter.datastore -ErrorAction Stop

        if ($Config.network.portgroup_name) {
            $objects.Network = Get-VirtualPortGroup -Name $Config.network.portgroup_name -ErrorAction SilentlyContinue
        }
    } catch {
        throw "Failed to resolve VMware objects: $_"
    }

    return $objects
}

# Export module members
Export-ModuleMember -Function @(
    'Get-ProjectRoot',
    'Get-ArtifactsDir',
    'Read-SpecConfig',
    'Get-NestedValue',
    'Set-ConfigDefaults',
    'Connect-VSphere',
    'Resolve-IsoPath',
    'Write-Artifact',
    'Write-OperatorLog',
    'Invoke-SubScript',
    'Test-RequiredTools',
    'Get-VMwareObjects'
)
