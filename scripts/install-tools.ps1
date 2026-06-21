[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [Alias('c')]
    [string]$ConfigPath = '',

    [Alias('v')]
    [switch]$VerboseTrace,

    [Alias('d')]
    [switch]$DryRun,

    [Alias('r')]
    [switch]$Remove,

    [switch]$CheckPath,

    [Alias('p')]
    [string]$Prefix = '',

    [Alias('h')]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $ScriptRoot -ChildPath '..\config\tools.yaml'
}

Set-Variable -Name ToolVersion -Value 'v1.4.0' -Option Constant -Scope Script
$VerboseTraceEnabled = [bool]$VerboseTrace -or ($VerbosePreference -ne 'SilentlyContinue')
$DryRunEnabled = [bool]$DryRun
$RemoveEnabled = [bool]$Remove
$CheckPathEnabled = [bool]$CheckPath
$HelpEnabled = [bool]$Help

function Test-AdministratorIdentity {
    if ($env:CAT_TEST_FORCE_ADMINISTRATOR -eq '1') {
        return $true
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-PublicModeAllowed {
    if (Test-AdministratorIdentity) {
        throw 'Coding Agent Toolchain cannot run as Administrator.'
    }
}

function Show-Help {
    Write-Output "Coding Agent Toolchain $ToolVersion"
    Write-Output ''
    Write-Output (
        'Usage: install-tools.ps1 [-c|--config PATH] [-v|--verbose] [-d|--dry-run] ' +
        '[-r|--remove] [--check-path] [-p|--prefix PATH] [-h|--help]'
    )
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  -c, --config PATH  Use a custom YAML manifest path.'
    Write-Output '  -v, --verbose      Print detailed debug traces.'
    Write-Output '  -d, --dry-run      Simulate a successful run without modifications.'
    Write-Output '  -r, --remove       Remove tools previously installed by coding-agent-toolchain.'
    Write-Output '      --check-path   Verify resolved tool directories in PATH.'
    Write-Output '  -p, --prefix PATH  Install missing tools under PATH\coding-agent-toolchain.'
    Write-Output '  -h, --help         Show this help and version.'
}

$argumentIndex = 0
while ($argumentIndex -lt $RemainingArguments.Count) {
    $argument = $RemainingArguments[$argumentIndex]
    switch ($argument) {
        '--verbose' { $VerboseTraceEnabled = $true }
        '-v' { $VerboseTraceEnabled = $true }
        '--config' {
            if ($argumentIndex + 1 -ge $RemainingArguments.Count) {
                throw '--config requires a path.'
            }

            $argumentIndex++
            $ConfigPath = $RemainingArguments[$argumentIndex]
        }
        '--dry-run' { $DryRunEnabled = $true }
        '-d' { $DryRunEnabled = $true }
        '--remove' { $RemoveEnabled = $true }
        '-r' { $RemoveEnabled = $true }
        '--check-path' { $CheckPathEnabled = $true }
        '--help' { $HelpEnabled = $true }
        '-h' { $HelpEnabled = $true }
        '--prefix' {
            if ($argumentIndex + 1 -ge $RemainingArguments.Count) {
                throw '--prefix requires a path.'
            }

            $argumentIndex++
            $Prefix = $RemainingArguments[$argumentIndex]
        }
        '-p' {
            if ($argumentIndex + 1 -ge $RemainingArguments.Count) {
                throw '-p requires a path.'
            }

            $argumentIndex++
            $Prefix = $RemainingArguments[$argumentIndex]
        }
        default { throw "Unknown option: $argument" }
    }

    $argumentIndex++
}

Assert-PublicModeAllowed

if ($HelpEnabled) {
    Show-Help
    exit 0
}

$InstallPrefix = ''
if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
    $InstallPrefix = [IO.Path]::GetFullPath($Prefix)
    $userProfileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile'))
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedInstallPrefix = $InstallPrefix.TrimEnd($trimChars)
    $normalizedUserProfileRoot = $userProfileRoot.TrimEnd($trimChars)
    $isUserProfileRoot = [string]::Equals(
        $normalizedInstallPrefix,
        $normalizedUserProfileRoot,
        [StringComparison]::OrdinalIgnoreCase
    )
    $isUnderUserProfileRoot = $normalizedInstallPrefix.StartsWith(
        "$normalizedUserProfileRoot$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase
    )

    if (-not ($isUserProfileRoot -or $isUnderUserProfileRoot)) {
        throw '--prefix must point inside the current user profile to preserve user-scoped installation.'
    }

    if (-not (Test-Path -LiteralPath $normalizedInstallPrefix -PathType Container)) {
        throw '--prefix must point to an existing directory inside the current user profile.'
    }

    $InstallPrefix = $normalizedInstallPrefix
}

$PlatformName = 'windows'
$UserRoot = if ([string]::IsNullOrWhiteSpace($InstallPrefix)) {
    Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'CodingAgentToolchain'
} else {
    Join-Path -Path $InstallPrefix -ChildPath 'coding-agent-toolchain'
}
$BinDir = Join-Path -Path $UserRoot -ChildPath 'bin'
$NpmPrefix = Join-Path -Path $UserRoot -ChildPath 'npm'
$ChocolateyInstallDir = Join-Path -Path $UserRoot -ChildPath 'chocolatey'
$SupportedInstallerKeys = @(
    'kind',
    'package',
    'url',
    'owner',
    'repo',
    'asset_pattern',
    'file_name',
    'archive_kind',
    'archive_path',
    'executable',
    'install_dir_name',
    'bin_path',
    'source_dir',
    'install_args',
    'target_arg_prefix'
)

if ($VerboseTraceEnabled) {
    $VerbosePreference = 'Continue'
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Output "[INFO ] $Message"
}

function Write-TraceDetail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($script:VerboseTraceEnabled) {
        [Console]::Error.WriteLine("[DEBUG] $Message")
    }
}

function Write-WarningTrace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [Console]::Error.WriteLine("[WARN ] $Message")
}

function Invoke-DryRunTool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $executable = Get-ToolExecutable -Tool $Tool -Installer $Installer
    $verificationMethod = if ($Tool['VersionCheck'] -eq 'command_available') {
        'executable availability'
    } else {
        'its configured version command'
    }
    Write-Step "Dry-run: would check executable '$executable' for tool '$($Tool['Id'])'."
    Write-Step "Dry-run: would install '$($Tool['Id'])' if required using '$($Installer['kind'])'."
    Write-Step "Dry-run: would verify '$($Tool['Id'])' with $verificationMethod."
    Write-Step 'Dry-run: would write an installation marker after a successful install.'

    if ($Installer.Contains('package') -and -not [string]::IsNullOrWhiteSpace($Installer['package'])) {
        Write-TraceDetail "Dry-run package for '$($Tool['Id'])': $($Installer['package'])"
    }

    if ($Installer.Contains('url') -and -not [string]::IsNullOrWhiteSpace($Installer['url'])) {
        Write-TraceDetail "Dry-run download URL for '$($Tool['Id'])': $($Installer['url'])"
    }
}

function Test-ToolSupportedOnPlatform {
    param(
        [AllowNull()]
        [object]$Installer
    )

    if ($null -eq $Installer) {
        return $false
    }

    if (-not $Installer.Contains('kind') -or [string]::IsNullOrWhiteSpace($Installer['kind'])) {
        return $false
    }

    return $Installer['kind'] -notin @('unavailable', 'unsupported', 'none')
}

function Get-UnsupportedToolMessage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool
    )

    return "Tool '$($Tool['Id'])' is not available on Windows. Skipping installation."
}

function ConvertFrom-ManifestValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2) {
        $first = $trimmed.Substring(0, 1)
        $last = $trimmed.Substring($trimmed.Length - 1, 1)
        if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }

    return $trimmed
}

function Initialize-ToolEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    return [ordered]@{
        Id = $Id
        Executable = $null
        VersionCheck = 'command'
        VersionArgs = [System.Collections.Generic.List[string]]::new()
        Installers = [ordered]@{}
    }
}

function Read-ToolManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    Write-TraceDetail "Opening configuration file: $Path"
    $schemaVersion = $null
    $tools = [System.Collections.Generic.List[object]]::new()
    $currentTool = $null
    $currentSection = $null
    $currentOs = $null
    $lineNumber = 0

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.TrimEnd()

        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^schema_version:\s*(.+)$') {
            $schemaVersion = ConvertFrom-ManifestValue -Value $matches[1]
            continue
        }

        if ($line -match '^tools:\s*$') {
            $currentSection = 'tools'
            continue
        }

        if ($line -match '^  - id:\s*(.+)$') {
            $toolId = ConvertFrom-ManifestValue -Value $matches[1]
            Write-TraceDetail "Reading manifest entry for tool '$toolId'."
            $currentTool = Initialize-ToolEntry -Id $toolId
            $tools.Add($currentTool)
            $currentSection = 'tool'
            $currentOs = $null
            continue
        }

        if ($null -eq $currentTool) {
            throw "Unsupported manifest line $lineNumber before the first tool: $line"
        }

        if ($line -match '^    executable:\s*(.+)$') {
            $currentTool['Executable'] = ConvertFrom-ManifestValue -Value $matches[1]
            continue
        }

        if ($line -match '^    version_check:\s*(.+)$') {
            $currentTool['VersionCheck'] = ConvertFrom-ManifestValue -Value $matches[1]
            continue
        }

        if ($line -match '^    version_args:\s*$') {
            $currentSection = 'version_args'
            continue
        }

        if ($line -match '^      -\s*(.+)$' -and $currentSection -eq 'version_args') {
            $currentTool['VersionArgs'].Add((ConvertFrom-ManifestValue -Value $matches[1]))
            continue
        }

        if ($line -match '^    installers:\s*$') {
            $currentSection = 'installers'
            $currentOs = $null
            continue
        }

        if ($line -match '^      ([a-z_]+):\s*(.+)$' -and $currentSection -eq 'installers') {
            throw "Installer property without platform at manifest line $lineNumber."
        }

        if ($line -match '^      (windows|linux):\s*$') {
            $currentOs = $matches[1]
            $currentTool['Installers'][$currentOs] = [ordered]@{}
            $currentSection = 'installer'
            continue
        }

        if ($line -match '^        ([a-z_]+):\s*(.+)$' -and $currentSection -eq 'installer') {
            if ([string]::IsNullOrWhiteSpace($currentOs)) {
                throw "Installer property without platform at manifest line $lineNumber."
            }

            $key = $matches[1]
            if ($key -notin $SupportedInstallerKeys) {
                throw "Unsupported installer key '$key' at manifest line $lineNumber."
            }

            $currentTool['Installers'][$currentOs][$key] = ConvertFrom-ManifestValue -Value $matches[2]
            continue
        }

        throw "Unsupported manifest line ${lineNumber}: $line"
    }

    if ($schemaVersion -ne '1') {
        throw "Unsupported schema_version '$schemaVersion'. Expected '1'."
    }

    if ($tools.Count -eq 0) {
        throw "The manifest does not define any tools."
    }

    Write-TraceDetail "Manifest schema version '$schemaVersion' contains $($tools.Count) tool entries."
    foreach ($tool in $tools) {
        if ([string]::IsNullOrWhiteSpace($tool['Id'])) {
            throw 'Every tool entry must define an id.'
        }

        if ([string]::IsNullOrWhiteSpace($tool['Executable'])) {
            throw "Tool '$($tool['Id'])' must define an executable."
        }

        if ($tool['VersionCheck'] -notin @('command', 'command_available')) {
            throw "Tool '$($tool['Id'])' defines unsupported version_check '$($tool['VersionCheck'])'."
        }

        if (-not $tool['Installers'].Contains($PlatformName)) {
            Write-TraceDetail "Tool '$($tool['Id'])' does not define a Windows installer and will be skipped."
        } elseif (-not $tool['Installers'][$PlatformName].Contains('kind')) {
            Write-TraceDetail "Tool '$($tool['Id'])' Windows installer does not define kind and will be skipped."
        }
    }

    return $tools
}

function Get-RequiredInstallerValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ToolId
    )

    if (-not $Installer.Contains($Name) -or [string]::IsNullOrWhiteSpace($Installer[$Name])) {
        throw "Installer for tool '$ToolId' must define '$Name'."
    }

    return $Installer[$Name]
}

function Add-CurrentPathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $separator = [IO.Path]::PathSeparator
    $currentPathEntries = @($env:Path -split [Regex]::Escape($separator))
    if (-not ($currentPathEntries -contains $Path)) {
        Write-TraceDetail "Adding '$Path' to the current process PATH."
        $env:Path = "$Path$separator$env:Path"
    } else {
        Write-TraceDetail "Current process PATH already contains '$Path'."
    }
}

function Add-UserPathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Add-CurrentPathEntry -Path $Path
    $separator = [IO.Path]::PathSeparator
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userPathEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $userPathEntries = @($userPath -split [Regex]::Escape($separator))
    }

    if ($userPathEntries -contains $Path) {
        Write-TraceDetail "Current user PATH already contains '$Path'."
        return
    }

    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $Path
    } else {
        "$Path$separator$userPath"
    }

    Write-TraceDetail "Persisting '$Path' in the current user PATH."
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
}

function Confirm-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-TraceDetail "Creating directory: $Path"
        New-Item -ItemType Directory -Path $Path | Out-Null
    } else {
        Write-TraceDetail "Directory already exists: $Path"
    }
}

function Get-InstallMarkerUserName {
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USER)) {
        return $env:USER
    }

    return [Environment]::UserName
}

function Get-InstallMarkerContent {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $userName = Get-InstallMarkerUserName
    return "Installed by coding-agent-toolchain $timestamp ($userName)"
}

function Write-InstallMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw 'Cannot write installation marker because the tool directory is empty.'
    }

    Confirm-Directory -Path $Directory
    $markerPath = Join-Path -Path $Directory -ChildPath '.coding-agent-toolchain'
    Write-TraceDetail "Writing installation marker '$markerPath'."
    Set-Content -LiteralPath $markerPath -Value (Get-InstallMarkerContent) -Encoding ASCII
    Write-Step "Wrote installation marker: $markerPath"
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @()
    )

    Write-TraceDetail "Running native command: $Command $($Arguments -join ' ')"
    $previousErrorActionPreference = $ErrorActionPreference
    $exitCode = 0
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Command failed: $Command $($Arguments -join ' ')`n$text"
    }

    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-TraceDetail "Native command output: $text"
    }

    return $text
}

function Get-ToolExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if ($Installer.Contains('executable') -and -not [string]::IsNullOrWhiteSpace($Installer['executable'])) {
        return $Installer['executable']
    }

    return $Tool['Executable']
}

function Get-AvailableCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-TraceDetail "Command '$Name' was not found in PATH."
        return $null
    }

    $windowsAppsPath = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) `
        -ChildPath 'Microsoft\WindowsApps'
    if ($command.Source -like "$windowsAppsPath\*") {
        Write-TraceDetail "Ignoring WindowsApps command alias for '$Name': $($command.Source)"
        return $null
    }

    Write-TraceDetail "Command '$Name' resolved to '$($command.Source)'."
    return $command
}

function Get-InstallDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $directoryName = if ($Installer.Contains('install_dir_name')) { $Installer['install_dir_name'] } else { $Tool['Id'] }
    return Join-Path -Path $UserRoot -ChildPath $directoryName
}

function Test-InstallPrefixEnabled {
    return -not [string]::IsNullOrWhiteSpace($script:InstallPrefix)
}

function Get-ToolBinaryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    return Join-Path -Path $installDirectory -ChildPath 'bin'
}

function Get-CommandDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if (Test-InstallPrefixEnabled) {
        return Get-ToolBinaryDirectory -Tool $Tool -Installer $Installer
    }

    return $BinDir
}

function Get-NpmPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    return Get-InstallDirectory -Tool $Tool -Installer $Installer
}

function Get-NpmCommandDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if (Test-InstallPrefixEnabled) {
        return Get-NpmPrefix -Tool $Tool -Installer $Installer
    }

    return $BinDir
}

function Test-PublishedCommandInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if (Test-InstallPrefixEnabled) {
        return $false
    }

    return $Installer['kind'] -in @(
        'pip',
        'python_user',
        'npm_global',
        'uv_tool',
        'direct_binary',
        'github_release_asset'
    )
}

function Get-InstallMarkerDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [AllowNull()]
        [string]$ExecutableDirectory
    )

    switch ($Installer['kind']) {
        { $_ -in @('portable_archive', 'direct_installer') } {
            return Get-InstallDirectory -Tool $Tool -Installer $Installer
        }
        'npm_global' {
            return Get-NpmPrefix -Tool $Tool -Installer $Installer
        }
        { $_ -in @('pip', 'python_user') } {
            if (-not (Test-InstallPrefixEnabled)) {
                return Get-InstallDirectory -Tool $Tool -Installer $Installer
            }

            $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
            if ([string]::IsNullOrWhiteSpace($ExecutableDirectory)) {
                return $installDirectory
            }

            $normalizedExecutableDirectory = Format-DirectoryPath -Directory $ExecutableDirectory
            $normalizedInstallDirectory = Format-DirectoryPath -Directory $installDirectory
            if ($normalizedExecutableDirectory.StartsWith($normalizedInstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                return $installDirectory
            }

            return $ExecutableDirectory
        }
        { $_ -in @('uv_tool', 'direct_binary', 'github_release_asset') } {
            return Get-InstallDirectory -Tool $Tool -Installer $Installer
        }
        default {
            return $ExecutableDirectory
        }
    }
}

function Write-InstallMarkerForTool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ExecutableDirectory
    )

    $markerDirectory = Get-InstallMarkerDirectory -Tool $Tool -Installer $Installer -ExecutableDirectory $ExecutableDirectory
    Write-InstallMarker -Directory $markerDirectory
}

function Get-PythonToolScriptsPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    return Join-Path -Path $installDirectory -ChildPath 'Scripts'
}

function Resolve-InstalledCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Executable
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path -Path $Directory -ChildPath $Executable))

    if ([IO.Path]::GetExtension($Executable).Length -eq 0) {
        foreach ($extension in @('.cmd', '.exe', '.bat', '.ps1')) {
            $candidates.Add((Join-Path -Path $Directory -ChildPath "$Executable$extension"))
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    throw "Installed command '$Executable' was not found in '$Directory'."
}

function ConvertTo-CmdLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace('%', '%%')
}

function Get-PublishedCommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $commandName = Get-ToolExecutable -Tool $Tool -Installer $Installer
    if ([IO.Path]::GetExtension($commandName).Length -ne 0) {
        throw "Cannot publish command '$commandName' as a cmd shim because it already has an extension."
    }

    $commandDirectory = Get-CommandDirectory -Tool $Tool -Installer $Installer
    return Join-Path -Path $commandDirectory -ChildPath "$commandName.cmd"
}

function Get-PublishedCommandTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShimPath
    )

    if (-not (Test-Path -LiteralPath $ShimPath -PathType Leaf)) {
        return ''
    }

    $targetLine = Get-Content -LiteralPath $ShimPath -TotalCount 2 |
        Where-Object { $_ -like 'rem coding-agent-toolchain target: *' } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($targetLine)) {
        return ''
    }

    $targetValue = $targetLine.Substring('rem coding-agent-toolchain target: '.Length).Trim()
    if ($targetValue.StartsWith('"') -and $targetValue.EndsWith('"') -and $targetValue.Length -ge 2) {
        $targetValue = $targetValue.Substring(1, $targetValue.Length - 2)
    }

    return $targetValue.Replace('%%', '%')
}

function Publish-ToolCommand {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not (Test-PublishedCommandInstaller -Installer $Installer)) {
        return
    }

    $shimPath = Get-PublishedCommandPath -Tool $Tool -Installer $Installer
    $commandDirectory = Split-Path -Path $shimPath -Parent
    Confirm-Directory -Path $commandDirectory

    if (Test-Path -LiteralPath $shimPath -PathType Leaf) {
        $existingTarget = Get-PublishedCommandTarget -ShimPath $shimPath
        if ([string]::IsNullOrWhiteSpace($existingTarget)) {
            throw "Cannot replace unmanaged command shim '$shimPath'."
        }

        $normalizedExistingTarget = ConvertTo-ComparablePathEntry -Path $existingTarget
        $normalizedUserRoot = ConvertTo-ComparablePathEntry -Path $UserRoot
        if (-not $normalizedExistingTarget.StartsWith(
                "$normalizedUserRoot$([IO.Path]::DirectorySeparatorChar)",
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Cannot replace command shim '$shimPath' because it points outside '$UserRoot'."
        }
    }

    $cmdTarget = ConvertTo-CmdLiteral -Value $TargetPath
    $content = @(
        '@echo off'
        "rem coding-agent-toolchain target: `"$cmdTarget`""
        "`"$cmdTarget`" %*"
    )

    Write-TraceDetail "Publishing command shim '$shimPath' for '$TargetPath'."
    Set-Content -LiteralPath $shimPath -Value $content -Encoding ASCII
    Add-UserPathEntry -Path $commandDirectory
}

function Remove-PublishedToolCommand {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Removal is gated by Invoke-RemoveMode ShouldProcess.'
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ManagedDirectory
    )

    if (-not (Test-PublishedCommandInstaller -Installer $Installer)) {
        return
    }

    $shimPath = Get-PublishedCommandPath -Tool $Tool -Installer $Installer
    if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
        return
    }

    $targetPath = Get-PublishedCommandTarget -ShimPath $shimPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        Write-TraceDetail "Leaving unmanaged command shim '$shimPath'."
        return
    }

    $normalizedTarget = ConvertTo-ComparablePathEntry -Path $targetPath
    $normalizedManagedDirectory = ConvertTo-ComparablePathEntry -Path $ManagedDirectory
    if ($normalizedTarget.StartsWith(
            "$normalizedManagedDirectory$([IO.Path]::DirectorySeparatorChar)",
            [StringComparison]::OrdinalIgnoreCase
        )) {
        Write-TraceDetail "Removing command shim '$shimPath'."
        Remove-Item -LiteralPath $shimPath -Force -ErrorAction Stop
    } else {
        Write-TraceDetail "Leaving command shim '$shimPath' because it points outside '$ManagedDirectory'."
    }
}

function Add-InstallerPathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [switch]$Persist
    )

    if (-not $Installer.Contains('bin_path')) {
        switch ($Installer['kind']) {
            { $_ -in @('pip', 'python_user') } {
                $binPath = if (Test-InstallPrefixEnabled) {
                    Get-PythonToolScriptsPath -Tool $Tool -Installer $Installer
                } else {
                    Get-CommandDirectory -Tool $Tool -Installer $Installer
                }
            }
            'npm_global' {
                $binPath = Get-NpmCommandDirectory -Tool $Tool -Installer $Installer
            }
            { $_ -in @('uv_tool', 'direct_binary', 'github_release_asset') } {
                $binPath = Get-CommandDirectory -Tool $Tool -Installer $Installer
            }
            default {
                Write-TraceDetail "Installer for '$($Tool['Id'])' does not declare an additional bin_path."
                return
            }
        }
    } else {
        $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
        $binPath = if ($Installer['bin_path'] -eq '.') {
            $installDirectory
        } else {
            Join-Path -Path $installDirectory -ChildPath $Installer['bin_path']
        }
    }

    if (Test-PublishedCommandInstaller -Installer $Installer) {
        $binPath = Get-CommandDirectory -Tool $Tool -Installer $Installer
    }

    if ($Persist) {
        Write-TraceDetail "Adding installer bin path persistently for '$($Tool['Id'])': $binPath"
        Add-UserPathEntry -Path $binPath
    } else {
        Write-TraceDetail "Adding installer bin path for current process for '$($Tool['Id'])': $binPath"
        Add-CurrentPathEntry -Path $binPath
    }
}

function Get-GitHubReleaseAssetUrl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ToolId
    )

    $owner = Get-RequiredInstallerValue -Installer $Installer -Name 'owner' -ToolId $ToolId
    $repo = Get-RequiredInstallerValue -Installer $Installer -Name 'repo' -ToolId $ToolId
    $assetPattern = Get-RequiredInstallerValue -Installer $Installer -Name 'asset_pattern' -ToolId $ToolId
    $releaseUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
    Write-TraceDetail "Fetching latest GitHub release metadata from '$releaseUrl'."
    $release = Invoke-RestMethod -Uri $releaseUrl -Headers @{ Accept = 'application/vnd.github+json' }
    $asset = @($release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1)

    if ($asset.Count -eq 0) {
        throw "Latest GitHub release for '$owner/$repo' has no asset matching '$assetPattern'."
    }

    Write-TraceDetail "Matched GitHub release asset for '$ToolId': $($asset[0].name)"
    return $asset[0].browser_download_url
}

function Get-InstallerDownloadUrl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ToolId
    )

    if ($Installer.Contains('url') -and -not [string]::IsNullOrWhiteSpace($Installer['url'])) {
        Write-TraceDetail "Using configured download URL for '$ToolId': $($Installer['url'])"
        return $Installer['url']
    }

    return Get-GitHubReleaseAssetUrl -Installer $Installer -ToolId $ToolId
}

function Get-ArchiveDownloadFileName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ToolId
    )

    $archiveKind = Get-RequiredInstallerValue -Installer $Installer -Name 'archive_kind' -ToolId $ToolId
    switch ($archiveKind) {
        'zip' { return 'download.zip' }
        'seven_zip' { return 'download.7z' }
        default { return 'download.archive' }
    }
}

function Expand-ToolArchive {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Installer,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$ToolId
    )

    $archiveKind = Get-RequiredInstallerValue -Installer $Installer -Name 'archive_kind' -ToolId $ToolId
    switch ($archiveKind) {
        'zip' {
            Write-TraceDetail "Extracting zip archive for '$ToolId' to '$DestinationPath'."
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
        }
        'seven_zip' {
            if (-not (Get-Command -Name tar -ErrorAction SilentlyContinue)) {
                throw "Tool '$ToolId' requires tar to extract 7z archives, but tar is not available."
            }

            Write-TraceDetail "Extracting 7z archive for '$ToolId' to '$DestinationPath'."
            Confirm-Directory -Path $DestinationPath
            Invoke-NativeCommand -Command 'tar' -Arguments @('-xf', $ArchivePath, '-C', $DestinationPath) | Out-Null
        }
        default {
            throw "Unsupported Windows archive_kind '$archiveKind' for tool '$ToolId'."
        }
    }
}

function Get-PythonCommand {
    $pythonCommand = Get-Command -Name python -ErrorAction SilentlyContinue
    if ($null -ne $pythonCommand) {
        Write-TraceDetail "Using Python command: $($pythonCommand.Source)"
        return $pythonCommand.Source
    }

    $pyLauncher = Get-Command -Name py -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        Write-TraceDetail "Using Python launcher: $($pyLauncher.Source)"
        return $pyLauncher.Source
    }

    throw 'Python is required for pip installers, but no python or py command is available.'
}

function Invoke-PythonCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonCommand,

        [string[]]$Arguments = @()
    )

    if ((Split-Path -Leaf $PythonCommand) -ieq 'py.exe') {
        return Invoke-NativeCommand -Command $PythonCommand -Arguments (@('-3') + $Arguments)
    }

    return Invoke-NativeCommand -Command $PythonCommand -Arguments $Arguments
}

function Get-PythonUserScriptsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonCommand
    )

    $pythonCode = @(
        'import os, site, sysconfig'
        'scheme_names = sysconfig.get_scheme_names()'
        'paths = sysconfig.get_paths(scheme=''nt_user'') if ''nt_user'' in scheme_names else {}'
        'print(paths.get(''scripts'') or os.path.join(site.getuserbase(), ''Scripts''))'
    ) -join '; '
    $scriptsPath = (Invoke-PythonCommand -PythonCommand $PythonCommand -Arguments @('-c', $pythonCode)).Trim()
    if ([string]::IsNullOrWhiteSpace($scriptsPath)) {
        throw 'Python user scripts path could not be resolved.'
    }

    Write-TraceDetail "Python user scripts path resolved to '$scriptsPath'."
    return $scriptsPath
}

function Install-NpmGlobalTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    $npmPrefix = Get-NpmPrefix -Tool $Tool -Installer $Installer
    if (-not $PSCmdlet.ShouldProcess($package, "Install npm package in user prefix $npmPrefix")) {
        return
    }

    if (-not (Get-Command -Name npm -ErrorAction SilentlyContinue)) {
        throw "Tool '$($Tool['Id'])' requires npm, but npm is not available."
    }

    Write-TraceDetail "Installing npm package '$package' in prefix '$npmPrefix'."
    Confirm-Directory -Path $npmPrefix
    Invoke-NativeCommand -Command 'npm' -Arguments @(
        'install',
        '--global',
        '--prefix',
        $npmPrefix,
        '--silent',
        '--no-audit',
        '--no-fund',
        $package
    ) | Out-Null

    $targetPath = Resolve-InstalledCommandPath `
        -Directory $npmPrefix `
        -Executable (Get-ToolExecutable -Tool $Tool -Installer $Installer)
    Publish-ToolCommand -Tool $Tool -Installer $Installer -TargetPath $targetPath
}

function Install-UvTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    $binDir = Get-ToolBinaryDirectory -Tool $Tool -Installer $Installer
    if (-not $PSCmdlet.ShouldProcess($package, "Install uv tool in user bin $binDir")) {
        return
    }

    if (-not (Get-Command -Name uv -ErrorAction SilentlyContinue)) {
        throw "Tool '$($Tool['Id'])' requires uv, but uv is not available."
    }

    Write-TraceDetail "Installing uv tool '$package' in '$binDir'."
    Confirm-Directory -Path $binDir
    $previousToolDir = $env:UV_TOOL_DIR
    $previousToolBinDir = $env:UV_TOOL_BIN_DIR
    try {
        $env:UV_TOOL_DIR = $installDirectory
        $env:UV_TOOL_BIN_DIR = $binDir
        Invoke-NativeCommand -Command 'uv' -Arguments @('tool', 'install', '--quiet', $package) | Out-Null
    } finally {
        Write-TraceDetail "Restoring previous UV_TOOL_DIR value."
        $env:UV_TOOL_DIR = $previousToolDir
        Write-TraceDetail "Restoring previous UV_TOOL_BIN_DIR value."
        $env:UV_TOOL_BIN_DIR = $previousToolBinDir
    }

    $targetPath = Resolve-InstalledCommandPath `
        -Directory $binDir `
        -Executable (Get-ToolExecutable -Tool $Tool -Installer $Installer)
    Publish-ToolCommand -Tool $Tool -Installer $Installer -TargetPath $targetPath
}

function Install-PowerShellGalleryTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    if (-not $PSCmdlet.ShouldProcess($package, 'Install PowerShell module for current user')) {
        return
    }

    Write-TraceDetail "Installing PowerShell module '$package' from PSGallery for CurrentUser."
    Install-Module -Name $package -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
}

function Install-PythonUserTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    $target = "Install Python package in user virtual environment for $($Tool['Id'])"
    if (-not $PSCmdlet.ShouldProcess($package, $target)) {
        return
    }

    $pythonCommand = Get-PythonCommand
    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    $scriptsPath = Get-PythonToolScriptsPath -Tool $Tool -Installer $Installer
    $venvPython = Join-Path -Path $scriptsPath -ChildPath 'python.exe'
    Write-TraceDetail "Installing Python package '$package' in virtual environment '$installDirectory'."
    Confirm-Directory -Path (Split-Path -Path $installDirectory -Parent)
    Invoke-PythonCommand -PythonCommand $pythonCommand -Arguments @('-m', 'venv', $installDirectory) | Out-Null
    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Python virtual environment for '$($Tool['Id'])' did not create '$venvPython'."
    }

    Invoke-PythonCommand -PythonCommand $venvPython -Arguments @(
        '-m',
        'pip',
        'install',
        '--quiet',
        $package
    ) | Out-Null

    if (Test-InstallPrefixEnabled) {
        Add-UserPathEntry -Path $scriptsPath
        return
    }

    $targetPath = Resolve-InstalledCommandPath `
        -Directory $scriptsPath `
        -Executable (Get-ToolExecutable -Tool $Tool -Installer $Installer)
    Publish-ToolCommand -Tool $Tool -Installer $Installer -TargetPath $targetPath
}

function Install-PipTool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    Install-PythonUserTool -Tool $Tool -Installer $Installer
}

function Install-BrewTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    if (-not $PSCmdlet.ShouldProcess($package, 'Install Homebrew package for current user')) {
        return
    }

    if (-not (Get-Command -Name brew -ErrorAction SilentlyContinue)) {
        throw "Tool '$($Tool['Id'])' requires brew, but brew is not available."
    }

    Write-TraceDetail "Installing Homebrew package '$package'."
    Invoke-NativeCommand -Command 'brew' -Arguments @('install', $package) | Out-Null
}

function Install-WingetTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    if (-not $PSCmdlet.ShouldProcess($package, 'Install winget package in user scope')) {
        return
    }

    if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
        throw "Tool '$($Tool['Id'])' requires winget, but winget is not available."
    }

    Write-TraceDetail "Installing winget package '$package' with user scope and silent flags."
    Invoke-NativeCommand -Command 'winget' -Arguments @(
        'install',
        '--id',
        $package,
        '--exact',
        '--source',
        'winget',
        '--scope',
        'user',
        '--silent',
        '--disable-interactivity',
        '--accept-package-agreements',
        '--accept-source-agreements'
    ) | Out-Null
}

function Install-ChocolateyTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
    if (-not $PSCmdlet.ShouldProcess($package, "Install Chocolatey package under $ChocolateyInstallDir")) {
        return
    }

    if (-not (Get-Command -Name choco -ErrorAction SilentlyContinue)) {
        throw "Tool '$($Tool['Id'])' requires chocolatey, but choco is not available."
    }

    Write-TraceDetail "Installing Chocolatey package '$package' under '$ChocolateyInstallDir'."
    Confirm-Directory -Path $ChocolateyInstallDir
    Invoke-NativeCommand -Command 'choco' -Arguments @(
        'install',
        $package,
        '--yes',
        '--no-progress',
        '--limit-output',
        "--install-directory=$ChocolateyInstallDir"
    ) | Out-Null
}

function Install-DirectBinaryTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $fileName = if ($Installer.Contains('file_name')) { $Installer['file_name'] } else { $Tool['Executable'] }
    $binDir = Get-ToolBinaryDirectory -Tool $Tool -Installer $Installer
    $targetPath = Join-Path -Path $binDir -ChildPath $fileName

    if (-not $PSCmdlet.ShouldProcess($targetPath, 'Download direct binary')) {
        return
    }

    $url = Get-InstallerDownloadUrl -Installer $Installer -ToolId $Tool['Id']
    Write-TraceDetail "Downloading direct binary for '$($Tool['Id'])' from '$url' to '$targetPath'."
    Confirm-Directory -Path $binDir

    if (-not $Installer.Contains('archive_kind')) {
        Write-TraceDetail "Downloading plain binary file for '$($Tool['Id'])'."
        Invoke-WebRequest -Uri $url -OutFile $targetPath -UseBasicParsing
        Publish-ToolCommand -Tool $Tool -Installer $Installer -TargetPath $targetPath
        return
    }

    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ([IO.Path]::GetRandomFileName())
    $archiveFileName = Get-ArchiveDownloadFileName -Installer $Installer -ToolId $Tool['Id']
    $archivePath = Join-Path -Path $tempRoot -ChildPath $archiveFileName
    $extractPath = Join-Path -Path $tempRoot -ChildPath 'extract'

    try {
        Confirm-Directory -Path $tempRoot
        Write-TraceDetail "Downloading archive for '$($Tool['Id'])' to '$archivePath'."
        Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
        $expandArguments = @{
            Installer = $Installer
            ArchivePath = $archivePath
            DestinationPath = $extractPath
            ToolId = $Tool['Id']
        }
        Expand-ToolArchive @expandArguments

        $configuredArchivePath = if ($Installer.Contains('archive_path')) { $Installer['archive_path'] } else { $fileName }
        $candidatePath = Join-Path -Path $extractPath -ChildPath $configuredArchivePath
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            Write-TraceDetail "Configured archive path was not found. Searching extracted files for '$fileName'."
            $candidate = Get-ChildItem -LiteralPath $extractPath -Recurse -File |
                Where-Object { $_.Name -eq $fileName } |
                Select-Object -First 1
            if ($null -eq $candidate) {
                throw "Archive for tool '$($Tool['Id'])' does not contain '$fileName'."
            }

            $candidatePath = $candidate.FullName
        }

        Write-TraceDetail "Copying extracted binary from '$candidatePath' to '$targetPath'."
        Copy-Item -LiteralPath $candidatePath -Destination $targetPath -Force
        Publish-ToolCommand -Tool $Tool -Installer $Installer -TargetPath $targetPath
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Write-TraceDetail "Removing temporary directory '$tempRoot'."
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Install-PortableArchiveTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    if (-not $PSCmdlet.ShouldProcess($installDirectory, 'Install portable archive in user scope')) {
        return
    }

    $url = Get-InstallerDownloadUrl -Installer $Installer -ToolId $Tool['Id']
    $executable = Get-ToolExecutable -Tool $Tool -Installer $Installer
    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ([IO.Path]::GetRandomFileName())
    $archiveFileName = Get-ArchiveDownloadFileName -Installer $Installer -ToolId $Tool['Id']
    $archivePath = Join-Path -Path $tempRoot -ChildPath $archiveFileName
    $extractPath = Join-Path -Path $tempRoot -ChildPath 'extract'

    try {
        Confirm-Directory -Path $tempRoot
        Write-TraceDetail "Downloading portable archive for '$($Tool['Id'])' from '$url' to '$archivePath'."
        Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
        $expandArguments = @{
            Installer = $Installer
            ArchivePath = $archivePath
            DestinationPath = $extractPath
            ToolId = $Tool['Id']
        }
        Expand-ToolArchive @expandArguments

        $sourceRoot = $extractPath
        $hasArchivePath = $Installer.Contains('archive_path') -and
            -not [string]::IsNullOrWhiteSpace($Installer['archive_path'])
        $configuredArchivePath = if ($hasArchivePath) { $Installer['archive_path'] } else { $executable }
        $candidatePath = Join-Path -Path $sourceRoot -ChildPath $configuredArchivePath
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            Write-TraceDetail "Searching extracted archive for executable '$executable'."
            $candidate = Get-ChildItem -LiteralPath $extractPath -Recurse -File |
                Where-Object { $_.Name -eq $executable } |
                Select-Object -First 1
            if ($null -eq $candidate) {
                throw "Portable archive for tool '$($Tool['Id'])' does not contain '$executable'."
            }

            if (-not $hasArchivePath) {
                $sourceRoot = $candidate.DirectoryName
            }
        }

        Confirm-Directory -Path $installDirectory
        Write-TraceDetail "Copying portable archive contents from '$sourceRoot' to '$installDirectory'."
        Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $installDirectory -Recurse -Force
        }

        Add-InstallerPathEntry -Tool $Tool -Installer $Installer -Persist
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Write-TraceDetail "Removing temporary directory '$tempRoot'."
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Install-GitHubReleaseAssetTool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    Install-DirectBinaryTool -Tool $Tool -Installer $Installer
}

function Install-DirectInstallerTool {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    $installDirectory = Get-InstallDirectory -Tool $Tool -Installer $Installer
    if (-not $PSCmdlet.ShouldProcess($installDirectory, 'Download and run direct installer in user scope')) {
        return
    }

    $url = Get-InstallerDownloadUrl -Installer $Installer -ToolId $Tool['Id']
    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ([IO.Path]::GetRandomFileName())
    $installerPath = Join-Path -Path $tempRoot -ChildPath 'installer.exe'

    try {
        Confirm-Directory -Path $tempRoot
        Confirm-Directory -Path $installDirectory
        Write-TraceDetail "Downloading installer for '$($Tool['Id'])' from '$url' to '$installerPath'."
        Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing

        $arguments = [System.Collections.Generic.List[string]]::new()
        if ($Installer.Contains('install_args') -and -not [string]::IsNullOrWhiteSpace($Installer['install_args'])) {
            $arguments.Add($Installer['install_args'])
        }

        if ($Installer.Contains('target_arg_prefix')) {
            $arguments.Add("$($Installer['target_arg_prefix'])$installDirectory")
        }

        Write-TraceDetail "Running installer '$installerPath' with arguments: $($arguments -join ' ')"
        $process = Start-Process -FilePath $installerPath -ArgumentList $arguments.ToArray() -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installer exited with code $($process.ExitCode)."
        }

        Write-TraceDetail "Installer exited successfully with code $($process.ExitCode)."
        Add-InstallerPathEntry -Tool $Tool -Installer $Installer -Persist
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Write-TraceDetail "Removing temporary directory '$tempRoot'."
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Install-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    Write-TraceDetail "Dispatching installer kind '$($Installer['kind'])' for tool '$($Tool['Id'])'."
    switch ($Installer['kind']) {
        'npm_global' { Install-NpmGlobalTool -Tool $Tool -Installer $Installer }
        'uv_tool' { Install-UvTool -Tool $Tool -Installer $Installer }
        'pip' { Install-PipTool -Tool $Tool -Installer $Installer }
        'python_user' { Install-PythonUserTool -Tool $Tool -Installer $Installer }
        'brew' { Install-BrewTool -Tool $Tool -Installer $Installer }
        'winget' { Install-WingetTool -Tool $Tool -Installer $Installer }
        'chocolatey' { Install-ChocolateyTool -Tool $Tool -Installer $Installer }
        'powershell_gallery' { Install-PowerShellGalleryTool -Tool $Tool -Installer $Installer }
        'direct_binary' { Install-DirectBinaryTool -Tool $Tool -Installer $Installer }
        'github_release_asset' { Install-GitHubReleaseAssetTool -Tool $Tool -Installer $Installer }
        'portable_archive' { Install-PortableArchiveTool -Tool $Tool -Installer $Installer }
        'direct_installer' { Install-DirectInstallerTool -Tool $Tool -Installer $Installer }
        default { throw "Unsupported installer kind '$($Installer['kind'])' for tool '$($Tool['Id'])'." }
    }
}

function Get-PowerShellModuleVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $module = Get-Module -ListAvailable -Name $Name |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if ($null -eq $module) {
        throw "PowerShell module '$Name' is not installed."
    }

    return $module.Version.ToString()
}

function Test-ToolAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if ($Installer['kind'] -eq 'powershell_gallery') {
        $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
        Write-TraceDetail "Checking PowerShell module availability for '$package'."
        return [bool](Get-Module -ListAvailable -Name $package)
    }

    Add-InstallerPathEntry -Tool $Tool -Installer $Installer
    $executable = Get-ToolExecutable -Tool $Tool -Installer $Installer
    Write-TraceDetail "Checking executable availability for '$($Tool['Id'])': $executable"
    return [bool](Get-AvailableCommand -Name $executable)
}

function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if ($Installer['kind'] -eq 'powershell_gallery') {
        $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
        return Get-PowerShellModuleVersion -Name $package
    }

    if ($Tool['VersionCheck'] -eq 'command_available') {
        return 'available'
    }

    Add-InstallerPathEntry -Tool $Tool -Installer $Installer
    $executable = Get-ToolExecutable -Tool $Tool -Installer $Installer
    $command = Get-AvailableCommand -Name $executable
    if ($null -eq $command) {
        throw "Executable '$executable' is not available in PATH."
    }

    $versionArgs = [string[]]$Tool['VersionArgs'].ToArray()
    Write-TraceDetail "Running version command for '$($Tool['Id'])': $($command.Source) $($versionArgs -join ' ')"
    $output = Invoke-NativeCommand -Command $command.Source -Arguments $versionArgs
    return ($output -replace '\r?\n', ' ').Trim()
}

function Format-DirectoryPath {
    param(
        [AllowNull()]
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return ''
    }

    if ($Directory.EndsWith([IO.Path]::DirectorySeparatorChar) -or
        $Directory.EndsWith([IO.Path]::AltDirectorySeparatorChar)) {
        return $Directory
    }

    return "$Directory$([IO.Path]::DirectorySeparatorChar)"
}

function Get-ToolDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    if ($Installer['kind'] -eq 'powershell_gallery') {
        $package = Get-RequiredInstallerValue -Installer $Installer -Name 'package' -ToolId $Tool['Id']
        $module = Get-Module -ListAvailable -Name $package |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
        if ($null -eq $module) {
            throw "PowerShell module '$package' is not available."
        }

        return Format-DirectoryPath -Directory $module.ModuleBase
    }

    Add-InstallerPathEntry -Tool $Tool -Installer $Installer
    $executable = Get-ToolExecutable -Tool $Tool -Installer $Installer
    $command = Get-AvailableCommand -Name $executable
    if ($null -eq $command) {
        throw "Executable '$executable' is not available in PATH."
    }

    $source = $command.Source
    if ([string]::IsNullOrWhiteSpace($source)) {
        $source = $command.Definition
    }

    return Format-DirectoryPath -Directory (Split-Path -Path $source -Parent)
}

function Format-SummaryVersion {
    param(
        [AllowNull()]
        [string]$Version
    )

    if ([string]::IsNullOrEmpty($Version) -or $Version.Length -le 64) {
        $Version
    } else {
        "$($Version.Substring(0, 61))..."
    }
}

function Format-SummaryDirectory {
    param(
        [AllowNull()]
        [string]$Directory
    )

    if ([string]::IsNullOrEmpty($Directory) -or $Directory.Length -le 64) {
        $Directory
    } else {
        "$($Directory.Substring(0, 61))..."
    }
}

function ConvertTo-ComparablePathEntry {
    param(
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    try {
        $normalizedPath = [IO.Path]::GetFullPath($expandedPath)
    } catch {
        $normalizedPath = $expandedPath
    }

    $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $normalizedPath.TrimEnd($trimCharacters)
}

function Test-DirectoryInPath {
    param(
        [AllowNull()]
        [string]$Directory
    )

    $targetDirectory = ConvertTo-ComparablePathEntry -Path $Directory
    if ([string]::IsNullOrWhiteSpace($targetDirectory)) {
        return $false
    }

    $pathEntries = @($env:Path -split [Regex]::Escape([IO.Path]::PathSeparator))
    foreach ($pathEntry in $pathEntries) {
        $normalizedEntry = ConvertTo-ComparablePathEntry -Path $pathEntry
        if ([string]::Equals($normalizedEntry, $targetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-UserPathEntry {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        return @()
    }

    $separator = [Regex]::Escape([IO.Path]::PathSeparator)
    return @($userPath -split $separator | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-PathEntryUnderDirectory {
    param(
        [AllowNull()]
        [string]$PathEntry,

        [AllowNull()]
        [string]$Directory
    )

    $normalizedEntry = ConvertTo-ComparablePathEntry -Path $PathEntry
    $normalizedDirectory = ConvertTo-ComparablePathEntry -Path $Directory
    if ([string]::IsNullOrWhiteSpace($normalizedEntry) -or
        [string]::IsNullOrWhiteSpace($normalizedDirectory)) {
        return $false
    }

    if ([string]::Equals($normalizedEntry, $normalizedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $normalizedEntry.StartsWith(
        "$normalizedDirectory$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ObsoleteUserPathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    $pathEntries = @(Get-UserPathEntry)
    $obsoleteEntries = [System.Collections.Generic.List[string]]::new()
    $seenEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($result in $Results) {
        if ([string]::IsNullOrWhiteSpace($result.RemovedDirectory)) {
            continue
        }

        foreach ($pathEntry in $pathEntries) {
            if ((Test-PathEntryUnderDirectory -PathEntry $pathEntry -Directory $result.RemovedDirectory) -and
                $seenEntries.Add($pathEntry)) {
                $obsoleteEntries.Add($pathEntry)
            }
        }
    }

    return $obsoleteEntries.ToArray()
}

function Get-PathVerificationStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    if ($Result.Status -eq 'DryRun') {
        return 'Simulated'
    }

    if ($Result.Status -eq 'Skipped') {
        return 'Skipped'
    }

    if ([string]::IsNullOrWhiteSpace($Result.Directory)) {
        return 'NotResolved'
    }

    if (Test-DirectoryInPath -Directory $Result.Directory) {
        return 'InPath'
    }

    return 'Missing'
}

function Assert-RemoveModeAllowed {
    $profileRoot = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($profileRoot) -or -not (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        throw '--remove requires a valid current user profile directory.'
    }
}

function Resolve-ExistingDirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw 'Managed installation directory does not exist.'
    }

    return (Resolve-Path -LiteralPath $Directory).ProviderPath
}

function Test-SameExistingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    if (-not (Test-Path -LiteralPath $Left -PathType Container) -or
        -not (Test-Path -LiteralPath $Right -PathType Container)) {
        return $false
    }

    $leftPath = Resolve-ExistingDirectoryPath -Directory $Left
    $rightPath = Resolve-ExistingDirectoryPath -Directory $Right
    return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SharedRemovalDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $sharedDirectories = @(
        $UserRoot,
        $BinDir
    )

    foreach ($sharedDirectory in $sharedDirectories) {
        if (Test-SameExistingDirectory -Left $Directory -Right $sharedDirectory) {
            return $true
        }
    }

    return $false
}

function Resolve-SafeRemovalDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw 'No managed installation directory could be resolved.'
    }

    $target = Resolve-ExistingDirectoryPath -Directory $Directory
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $profileRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd($trimChars)
    $normalizedTarget = [IO.Path]::GetFullPath($target).TrimEnd($trimChars)

    $isProfileRoot = [string]::Equals($normalizedTarget, $profileRoot, [StringComparison]::OrdinalIgnoreCase)
    $isUnderProfileRoot = $normalizedTarget.StartsWith(
        "$profileRoot$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase
    )

    if (-not ($isProfileRoot -or $isUnderProfileRoot)) {
        throw 'Managed installation directory is outside the current user profile.'
    }

    if ($isProfileRoot) {
        throw 'Refusing to remove the current user profile directory.'
    }

    if (Test-SharedRemovalDirectory -Directory $normalizedTarget) {
        throw 'Managed installation directory is shared; removal is unsafe.'
    }

    $markerPath = Join-Path -Path $normalizedTarget -ChildPath '.coding-agent-toolchain'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'Installation marker is missing; removal skipped.'
    }

    return $normalizedTarget
}

function Get-RemovalDisplayDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    try {
        return Get-ToolDirectory -Tool $Tool -Installer $Installer
    } catch {
        $markerDirectory = Get-InstallMarkerDirectory -Tool $Tool -Installer $Installer -ExecutableDirectory ''
        return Format-DirectoryPath -Directory $markerDirectory
    }
}

function Get-RemovalVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tool,

        [Parameter(Mandatory = $true)]
        [object]$Installer
    )

    try {
        if (Test-ToolAvailable -Tool $Tool -Installer $Installer) {
            return Get-ToolVersion -Tool $Tool -Installer $Installer
        }
    } catch {
        Write-TraceDetail "Version before removal is unavailable for '$($Tool['Id'])': $($_.Exception.Message)"
    }

    return ''
}

function Invoke-RemoveMode {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Tools
    )

    Assert-RemoveModeAllowed
    if ($DryRunEnabled) {
        Write-Step 'Dry-run remove mode enabled. No files or directories will be removed.'
    } else {
        Write-Step 'Remove mode enabled. Only marked user-scoped tool directories can be removed.'
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $toolIndex = 0

    foreach ($tool in $Tools) {
        $toolIndex++
        $installer = $null
        if ($tool['Installers'].Contains($PlatformName)) {
            $installer = $tool['Installers'][$PlatformName]
        }

        Write-Step "[$toolIndex/$($Tools.Count)] Checking removal for tool '$($tool['Id'])'."

        if (-not (Test-ToolSupportedOnPlatform -Installer $installer)) {
            $detail = Get-UnsupportedToolMessage -Tool $tool
            Write-WarningTrace $detail
            $results.Add([pscustomobject]@{
                Tool = $tool['Id']
                Status = 'Skipped'
                Directory = ''
                RemovedDirectory = ''
                Version = ''
                Detail = $detail
            })
            continue
        }

        if ($DryRunEnabled) {
            $results.Add([pscustomobject]@{
                Tool = $tool['Id']
                Status = 'DryRun'
                Directory = 'simulated'
                RemovedDirectory = ''
                Version = 'simulated'
                Detail = 'Dry-run: simulated successful removal without modifications.'
            })
            continue
        }

        $status = 'Skipped'
        $version = ''
        $detail = ''
        $directory = ''
        $removedDirectory = ''

        try {
            $directory = Get-RemovalDisplayDirectory -Tool $tool -Installer $installer
            $version = Get-RemovalVersion -Tool $tool -Installer $installer
            $markerDirectory = Get-InstallMarkerDirectory -Tool $tool -Installer $installer -ExecutableDirectory $directory
            $safeDirectory = Resolve-SafeRemovalDirectory -Directory $markerDirectory
            if ([string]::IsNullOrWhiteSpace($directory)) {
                $directory = Format-DirectoryPath -Directory $safeDirectory
            }

            Write-Step "Removing tool '$($tool['Id'])' directory: $safeDirectory"
            $status = 'Failed'
            if ($PSCmdlet.ShouldProcess($safeDirectory, "Remove marked tool directory for $($tool['Id'])")) {
                Remove-Item -LiteralPath $safeDirectory -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $safeDirectory) {
                    throw 'Managed installation directory still exists after removal.'
                }
                $removedDirectory = $safeDirectory
                Remove-PublishedToolCommand -Tool $tool -Installer $installer -ManagedDirectory $safeDirectory
                $status = 'Removed'
            } else {
                $status = 'Skipped'
                $detail = 'Removal was not confirmed by ShouldProcess.'
            }
        } catch {
            $errorRecord = $_
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = $errorRecord.Exception.Message
            }
            Write-WarningTrace "Tool '$($tool['Id'])' was not removed: $detail"
        }

        $results.Add([pscustomobject]@{
            Tool = $tool['Id']
            Status = $status
            Directory = $directory
            RemovedDirectory = $removedDirectory
            Version = $version
            Detail = $detail
        })
    }

    Write-Output ''
    Write-Output 'Tool removal summary:'
    Write-Output (
        '{0,-22} {1,-10} {2,-64} {3}' -f 'Tool', 'Status', 'Directory', 'Version'
    )
    Write-Output (
        '{0,-22} {1,-10} {2,-64} {3}' -f '----', '------', '---------', '-------'
    )

    foreach ($result in $results) {
        $summaryText = $result.Version
        if ($result.Status -in @('Failed', 'Skipped') -and -not [string]::IsNullOrWhiteSpace($result.Detail)) {
            $summaryText = $result.Detail
        }

        Write-Output (
            '{0,-22} {1,-10} {2,-64} {3}' -f
            $result.Tool,
            $result.Status,
            (Format-SummaryDirectory -Directory $result.Directory),
            (Format-SummaryVersion -Version $summaryText)
        )
    }

    $obsoletePathEntries = @(Get-ObsoleteUserPathEntry -Results $results)
    if ($obsoletePathEntries.Count -gt 0) {
        Write-Output ''
        Write-Output 'Obsolete PATH entries still present in the current user PATH:'
        foreach ($obsoletePathEntry in $obsoletePathEntries) {
            Write-Output "  $obsoletePathEntry"
        }
    }

    $failedResults = @($results | Where-Object { $_.Status -eq 'Failed' })
    if ($failedResults.Count -gt 0 -or $obsoletePathEntries.Count -gt 0) {
        exit 1
    }
}

Write-Step 'Starting Coding Agent Toolchain for Windows.'
$resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
Write-Step "Using configuration: $resolvedConfigPath"
if (-not [string]::IsNullOrWhiteSpace($InstallPrefix)) {
    Write-Step "Using installation root: $UserRoot"
}
Write-TraceDetail "User root: $UserRoot"
Write-TraceDetail "Tool binary directory: $BinDir"
Write-TraceDetail "npm prefix: $NpmPrefix"
Write-TraceDetail "Chocolatey install directory: $ChocolateyInstallDir"
$tools = @(Read-ToolManifest -Path $resolvedConfigPath)
Write-Step "Loaded $($tools.Count) tool entries from the manifest."
if ($RemoveEnabled) {
    Invoke-RemoveMode -Tools $tools
    exit 0
}

if ($DryRunEnabled) {
    Write-Step 'Dry-run mode enabled. No commands, downloads, PATH changes, or installations will be executed.'
}
$results = [System.Collections.Generic.List[object]]::new()
$toolIndex = 0

foreach ($tool in $tools) {
    $toolIndex++
    $installer = $null
    if ($tool['Installers'].Contains($PlatformName)) {
        $installer = $tool['Installers'][$PlatformName]
    }

    $status = 'Present'
    $version = ''
    $directory = ''
    $detail = ''
    $installerKind = ''
    if ($null -ne $installer -and $installer.Contains('kind')) {
        $installerKind = $installer['kind']
    }
    if ([string]::IsNullOrWhiteSpace($installerKind)) {
        $installerKind = '<not available>'
    }

    Write-Step "[$toolIndex/$($tools.Count)] Checking tool '$($tool['Id'])'."
    Write-TraceDetail "Installer kind for '$($tool['Id'])': $installerKind"

    if (-not (Test-ToolSupportedOnPlatform -Installer $installer)) {
        $detail = Get-UnsupportedToolMessage -Tool $tool
        Write-WarningTrace $detail
        $results.Add([pscustomobject]@{
            Tool = $tool['Id']
            Status = 'Skipped'
            Directory = ''
            Version = ''
            Detail = $detail
        })
        continue
    }

    if ($DryRunEnabled) {
        Invoke-DryRunTool -Tool $tool -Installer $installer
        $results.Add([pscustomobject]@{
            Tool = $tool['Id']
            Status = 'DryRun'
            Directory = 'simulated'
            Version = 'simulated'
            Detail = 'Dry-run: simulated successful execution without modifications.'
        })
        continue
    }

    try {
        $needsInstall = -not (Test-ToolAvailable -Tool $tool -Installer $installer)
        if (-not $needsInstall) {
            $directory = Get-ToolDirectory -Tool $tool -Installer $installer
            Write-Step "Tool '$($tool['Id'])' is available. Checking version."
            try {
                $version = Get-ToolVersion -Tool $tool -Installer $installer
                Write-Step "Tool '$($tool['Id'])' version detected: $version"
            } catch {
                $needsInstall = $true
                $detail = "Existing version check failed: $($_.Exception.Message)"
                Write-WarningTrace $detail
            }
        }

        if ($needsInstall) {
            Write-WarningTrace "Tool '$($tool['Id'])' is not installed. Installing it now."
            $status = 'Installed'
            Write-Step "Installing tool '$($tool['Id'])'."
            Install-Tool -Tool $tool -Installer $installer

            Write-Step "Verifying tool '$($tool['Id'])' after installation."
            if (-not (Test-ToolAvailable -Tool $tool -Installer $installer)) {
                $status = 'Missing'
                if ([string]::IsNullOrWhiteSpace($detail)) {
                    $detail = 'Tool is still unavailable after installation.'
                }
            } else {
                $directory = Get-ToolDirectory -Tool $tool -Installer $installer
                $version = Get-ToolVersion -Tool $tool -Installer $installer
                Write-InstallMarkerForTool -Tool $tool -Installer $installer -ExecutableDirectory $directory
                Write-Step "Tool '$($tool['Id'])' version detected after installation: $version"
            }
        }
    } catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
        Write-WarningTrace "Tool '$($tool['Id'])' failed: $detail"
    }

    $results.Add([pscustomobject]@{
        Tool = $tool['Id']
        Status = $status
        Directory = $directory
        Version = $version
        Detail = $detail
    })
}

if ($CheckPathEnabled) {
    Write-Output ''
    Write-Output 'PATH verification:'
    Write-Output (
        '{0,-22} {1,-10} {2}' -f 'Tool', 'Status', 'Directory'
    )
    Write-Output (
        '{0,-22} {1,-10} {2}' -f '----', '------', '---------'
    )

    foreach ($result in $results) {
        $pathStatus = Get-PathVerificationStatus -Result $result
        Write-Output (
            '{0,-22} {1,-10} {2}' -f $result.Tool, $pathStatus, $result.Directory
        )
    }
}

Write-Output ''
Write-Output 'Tool installation summary:'
Write-Output (
    '{0,-22} {1,-10} {2,-64} {3}' -f 'Tool', 'Status', 'Directory', 'Version'
)
Write-Output (
    '{0,-22} {1,-10} {2,-64} {3}' -f '----', '------', '---------', '-------'
)

foreach ($result in $results) {
    $summaryText = $result.Version
    $detailReplacesVersion = $result.Status -in @('Failed', 'Missing', 'Skipped') -and
        -not [string]::IsNullOrWhiteSpace($result.Detail)
    if ($detailReplacesVersion) {
        $summaryText = $result.Detail
    }

    $summaryVersion = Format-SummaryVersion -Version $summaryText
    $summaryDirectory = Format-SummaryDirectory -Directory $result.Directory
    Write-Output (
        '{0,-22} {1,-10} {2,-64} {3}' -f $result.Tool, $result.Status, $summaryDirectory, $summaryVersion
    )
    if (-not $detailReplacesVersion -and -not [string]::IsNullOrWhiteSpace($result.Detail)) {
        Write-Output "  $($result.Detail)"
    }
}

$failedResults = @($results | Where-Object { $_.Status -in @('Failed', 'Missing') })
if ($failedResults.Count -gt 0) {
    exit 1
}
