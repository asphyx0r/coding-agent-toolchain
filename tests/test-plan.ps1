<#
.SYNOPSIS
Runs the offline repository checks that are mapped to TEST_PLAN.md.

.DESCRIPTION
This script keeps routine validation isolated from real tool installation. It
checks static quality gates, validates the structural matrix contract, and
cross-checks the canonical manifest against the documented coverage table.
#>
[CmdletBinding()]
param(
    [switch]$SkipExternalChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Script:SkipExternalChecksEnabled = [bool]$SkipExternalChecks
$Script:CheckCount = 0
$Script:Failures = [System.Collections.Generic.List[string]]::new()
$Script:Warnings = [System.Collections.Generic.List[string]]::new()
$Script:RuntimeRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath (
    'cat-test-runtime-' + [guid]::NewGuid().ToString('N')
)
$Script:RuntimeDirectories = [System.Collections.Generic.List[string]]::new()
$Script:ExitCode = 0

function Get-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return Join-Path -Path $RepoRoot -ChildPath $RelativePath
}

function Get-RepositoryText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return [IO.File]::ReadAllText((Get-RepositoryPath -RelativePath $RelativePath))
}

function Get-LinuxFileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        throw 'bash is required to hash Linux fixture files.'
    }

    $hashCommand = 'sha256sum -- ' + (ConvertTo-BashSingleQuotedLiteral -Value $Path)
    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', $hashCommand)
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        throw "Could not hash Linux fixture file '$Path'. Output: $($result.Output)"
    }

    return (($result.Output.Trim() -split '\s+')[0]).ToLowerInvariant()
}

function ConvertFrom-ManifestScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmedValue = $Value.Trim()
    if ($trimmedValue.Length -ge 2) {
        $firstCharacter = $trimmedValue.Substring(0, 1)
        $lastCharacter = $trimmedValue.Substring($trimmedValue.Length - 1, 1)
        if (($firstCharacter -eq "'" -and $lastCharacter -eq "'") -or
            ($firstCharacter -eq '"' -and $lastCharacter -eq '"')) {
            return $trimmedValue.Substring(1, $trimmedValue.Length - 2)
        }
    }

    return $trimmedValue
}

function Register-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [string]$Detail = ''
    )

    $Script:CheckCount++
    if ($Passed) {
        Write-Output "[PASS] $Name"
        return
    }

    $message = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name - $Detail" }
    $Script:Failures.Add($message)
    Write-Output "[FAIL] $message"
}

function Register-CheckWarning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Script:Warnings.Add($Message)
    Write-Output "[WARN ] $Message"
}

function Initialize-RuntimeDirectory {
    if (-not (Test-Path -LiteralPath $Script:RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:RuntimeRoot | Out-Null
    }

    $directory = Join-Path -Path $Script:RuntimeRoot -ChildPath ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    $Script:RuntimeDirectories.Add($directory)
    return $directory
}

function Initialize-TemporaryPrefixDirectory {
    $directory = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('cat-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    $Script:RuntimeDirectories.Add($directory)
    return $directory
}

function Clear-RuntimeDirectory {
    if (-not (Test-Path -LiteralPath $Script:RuntimeRoot -PathType Container)) {
        return
    }

    $runtimeRootPath = [IO.Path]::GetFullPath($Script:RuntimeRoot)
    $tempRootPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    foreach ($directory in $Script:RuntimeDirectories) {
        $fullDirectory = [IO.Path]::GetFullPath($directory)
        $isRuntimeDirectory = $fullDirectory.StartsWith($runtimeRootPath, [StringComparison]::OrdinalIgnoreCase)
        $isTempDirectory = $fullDirectory.StartsWith($tempRootPath, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $fullDirectory).StartsWith('cat-test-', [StringComparison]::Ordinal)
        if (-not ($isRuntimeDirectory -or $isTempDirectory)) {
            continue
        }

        if (Test-Path -LiteralPath $fullDirectory) {
            try {
                Remove-Item -LiteralPath $fullDirectory -Recurse -Force -ErrorAction Stop
            } catch {
                Start-Sleep -Milliseconds 200
                try {
                    [IO.Directory]::Delete($fullDirectory, $true)
                } catch {
                    Register-CheckWarning "Could not remove runtime directory '$fullDirectory': $($_.Exception.Message)"
                }
            }
        }
    }

    if ((Get-ChildItem -LiteralPath $Script:RuntimeRoot -Force | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $Script:RuntimeRoot -Force -ErrorAction SilentlyContinue
    }
}

function Test-CheckCondition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$FailureDetail
    )

    Register-CheckResult -Name $Name -Passed $Condition -Detail $FailureDetail
}

function Get-RegexMatchValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    $match = [regex]::Match($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return ''
    }

    return $match.Groups[$GroupName].Value
}

function Invoke-ExternalCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [scriptblock]$Fallback
    )

    if ($Script:SkipExternalChecksEnabled) {
        Register-CheckWarning "$Name skipped because -SkipExternalChecks was supplied."
        if ($null -ne $Fallback) {
            & $Fallback
        }
        return
    }

    $resolvedCommand = Get-Command -Name $Command -ErrorAction SilentlyContinue
    if ($null -eq $resolvedCommand) {
        Register-CheckWarning "$Name skipped because '$Command' is unavailable."
        if ($null -ne $Fallback) {
            & $Fallback
        }
        return
    }

    $output = & $Command @Arguments 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Register-CheckResult -Name $Name -Passed ($exitCode -eq 0) -Detail $detail
}

function ConvertTo-BashHostPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $cygpathOutput = & bash -lc 'if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else exit 127; fi' `
        'cat-test' `
        $Path 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $cygpathOutput) {
        $convertedPath = (($cygpathOutput | Select-Object -First 1).ToString()).Trim()
        if (-not [string]::IsNullOrWhiteSpace($convertedPath)) {
            return $convertedPath
        }
    }

    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $pathWithoutDrive = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$pathWithoutDrive"
    }

    throw "Path '$Path' cannot be converted safely for bash."
}

function ConvertTo-BashPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $output = & bash -lc 'pwd -P' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bash could not resolve the repository path: $($output -join [Environment]::NewLine)"
    }

    $repoBashPath = (($output | Select-Object -First 1).ToString()).Trim()
    $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $repoFullPath = [IO.Path]::GetFullPath($RepoRoot).TrimEnd($trimCharacters)
    $isRepositoryPath = [string]::Equals($resolvedPath, $repoFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.StartsWith("$repoFullPath$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
    if ($isRepositoryPath) {
        $relativePath = $resolvedPath.Substring($repoFullPath.Length).TrimStart($trimCharacters)
        return ($repoBashPath.TrimEnd('/') + '/' + ($relativePath -replace '\\', '/'))
    }

    $tempRootPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($trimCharacters)
    $isTempPath = $resolvedPath.StartsWith(
        "$tempRootPath$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase
    )
    if ($isTempPath) {
        $tempRelativePath = $resolvedPath.Substring($tempRootPath.Length).TrimStart($trimCharacters)
        $tempTopDirectory = ($tempRelativePath -split '[\\/]', 2)[0]
        if ($tempTopDirectory.StartsWith('cat-test-', [StringComparison]::Ordinal)) {
            return ConvertTo-BashHostPath -Path $resolvedPath
        }
    }

    throw "Path '$Path' is outside the repository or managed test runtime and cannot be converted safely for bash."
}

function ConvertTo-BashSingleQuotedLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $quote = [string][char]39
    return $quote + $Value.Replace($quote, "$quote\$quote$quote") + $quote
}

function Invoke-CommandCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @(),

        [hashtable]$Environment = @{},

        [string]$WorkingDirectory = ''
    )

    $previousValues = @{}
    foreach ($key in $Environment.Keys) {
        $previousValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $locationPushed = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $locationPushed = $true
        }

        $ErrorActionPreference = 'Continue'
        $output = & $Command @Arguments 2>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($locationPushed) {
            Pop-Location
        }

        foreach ($key in $previousValues.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previousValues[$key], 'Process')
        }
    }
}

function Initialize-IsolatedScriptLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestContent
    )

    $root = Initialize-RuntimeDirectory
    $scriptDirectory = Join-Path -Path $root -ChildPath 'scripts'
    $configDirectory = Join-Path -Path $root -ChildPath 'config'
    $homeDirectory = Join-Path -Path $root -ChildPath 'home'
    New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
    New-Item -ItemType Directory -Path $configDirectory | Out-Null
    New-Item -ItemType Directory -Path $homeDirectory | Out-Null

    $windowsScript = Join-Path -Path $scriptDirectory -ChildPath 'install-tools.ps1'
    $linuxScript = Join-Path -Path $scriptDirectory -ChildPath 'install-tools.sh'
    $manifestPath = Join-Path -Path $configDirectory -ChildPath 'tools.yaml'
    Copy-Item -LiteralPath (Get-RepositoryPath -RelativePath 'scripts/install-tools.ps1') -Destination $windowsScript
    Copy-Item -LiteralPath (Get-RepositoryPath -RelativePath 'scripts/install-tools.sh') -Destination $linuxScript
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
            }

            Set-Content -LiteralPath $manifestPath -Value $ManifestContent -Encoding ASCII -ErrorAction Stop
            break
        } catch {
            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Milliseconds 200
        }
    }

    return [pscustomobject]@{
        Root = $root
        Home = $homeDirectory
        ManifestPath = $manifestPath
        WindowsScript = $windowsScript
        LinuxScript = $linuxScript
    }
}

function Get-PowerShellCommandName {
    $currentProcess = Get-Process -Id $PID
    if (-not [string]::IsNullOrWhiteSpace($currentProcess.Path)) {
        return $currentProcess.Path
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return 'pwsh'
    }

    return 'powershell'
}

function Invoke-IsolatedToolScript {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [string[]]$Arguments = @(),

        [hashtable]$Environment = @{},

        [string]$WorkingDirectory = ''
    )

    if ($Platform -eq 'windows') {
        $scriptEnvironment = @{}
        foreach ($key in $Environment.Keys) {
            $scriptEnvironment[$key] = $Environment[$key]
        }

        if (-not $scriptEnvironment.ContainsKey('CAT_TEST_FORCE_ADMINISTRATOR')) {
            $scriptEnvironment['CAT_TEST_ASSUME_STANDARD_USER'] = '1'
        }

        $powerShellArguments = @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $Layout.WindowsScript
        ) + $Arguments
        return Invoke-CommandCapture `
            -Command (Get-PowerShellCommandName) `
            -Arguments $powerShellArguments `
            -Environment $scriptEnvironment `
            -WorkingDirectory $WorkingDirectory
    }

    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        Register-CheckWarning 'Linux direct tests skipped because bash is unavailable.'
        return $null
    }

    $bashScript = ConvertTo-BashPath -Path $Layout.LinuxScript
    if ($Environment.Count -gt 0) {
        $wrapperScript = Join-Path -Path $Layout.Root -ChildPath 'run-linux-env.sh'
        $wrapperLines = @(
            '#!/usr/bin/env bash',
            'set -e'
        )
        foreach ($key in ($Environment.Keys | Sort-Object)) {
            $wrapperLines += "export $key=$(ConvertTo-BashSingleQuotedLiteral -Value ([string]$Environment[$key]))"
        }

        $wrapperLines += 'exec "$BASH" ' + (ConvertTo-BashSingleQuotedLiteral -Value $bashScript) + ' "$@"'
        [IO.File]::WriteAllText($wrapperScript, ($wrapperLines -join "`n") + "`n", [Text.Encoding]::ASCII)
        $wrapperBashScript = ConvertTo-BashPath -Path $wrapperScript
        return Invoke-CommandCapture `
            -Command $bashCommand.Source `
            -Arguments (@($wrapperBashScript) + $Arguments) `
            -WorkingDirectory $WorkingDirectory
    }

    return Invoke-CommandCapture `
        -Command $bashCommand.Source `
        -Arguments (@($bashScript) + $Arguments) `
        -WorkingDirectory $WorkingDirectory
}

function Write-LinuxExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Line
    )

    [IO.File]::WriteAllText($Path, ($Line -join "`n") + "`n", [Text.Encoding]::ASCII)
    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        Register-CheckWarning 'Linux executable setup skipped because bash is unavailable.'
        return
    }

    $bashPath = ConvertTo-BashPath -Path $Path
    $chmodCommand = 'chmod 755 ' + (ConvertTo-BashSingleQuotedLiteral -Value $bashPath)
    $chmodResult = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', $chmodCommand)
    if ($chmodResult.ExitCode -ne 0) {
        throw "Could not make '$Path' executable for Linux tests. Output: $($chmodResult.Output)"
    }
}

function Test-ResultText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedText
    )

    Test-CheckCondition `
        -Name $Name `
        -Condition ($null -ne $Result -and $Result.Output.Contains($ExpectedText)) `
        -FailureDetail "Expected output to contain '$ExpectedText'."
}

function Test-ResultTextAbsent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$UnexpectedText
    )

    Test-CheckCondition `
        -Name $Name `
        -Condition ($null -ne $Result -and -not $Result.Output.Contains($UnexpectedText)) `
        -FailureDetail "Expected output not to contain '$UnexpectedText'."
}

function Test-ExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedExitCode
    )

    Test-CheckCondition `
        -Name $Name `
        -Condition ($null -ne $Result -and $Result.ExitCode -eq $ExpectedExitCode) `
        -FailureDetail "Expected exit $ExpectedExitCode but got $($Result.ExitCode). Output: $($Result.Output)"
}

function Test-NonzeroExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    Test-CheckCondition `
        -Name $Name `
        -Condition ($null -ne $Result -and $Result.ExitCode -ne 0) `
        -FailureDetail "Expected nonzero exit. Output: $($Result.Output)"
}

function Get-PlatformPathArgument {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Platform -eq 'linux') {
        return ConvertTo-BashPath -Path $Path
    }

    return $Path
}

function Get-BashHomePath {
    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        return ''
    }

    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', 'printf "%s" "$HOME"')
    if ($result.ExitCode -ne 0) {
        return ''
    }

    return $result.Output.TrimEnd()
}

function Get-BashMachineName {
    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        return 'unknown'
    }

    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', 'uname -m')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return 'unknown'
    }

    return $result.Output.Trim()
}

function Test-BashHasCygpath {
    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        return $false
    }

    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @(
        '-lc',
        'command -v cygpath >/dev/null 2>&1'
    )
    return $result.ExitCode -eq 0
}

function Initialize-LinuxRuntimeDirectory {
    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        throw 'bash is required for Linux runtime fixtures.'
    }

    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', 'mktemp -d /tmp/cat-test.XXXXXXXXXX')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        throw "Could not create Linux runtime directory. Output: $($result.Output)"
    }

    return $result.Output.Trim()
}

function Clear-LinuxRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch '^/tmp/cat-test\.[A-Za-z0-9]+$') {
        throw "Refusing to clear unexpected Linux runtime directory '$Path'."
    }

    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        Register-CheckWarning "Could not clear Linux runtime directory '$Path' because bash is unavailable."
        return
    }

    $clearCommand = 'rm -rf -- ' + (ConvertTo-BashSingleQuotedLiteral -Value $Path)
    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', $clearCommand)
    if ($result.ExitCode -ne 0) {
        Register-CheckWarning "Could not clear Linux runtime directory '$Path': $($result.Output)"
    }
}

function Test-LinuxPathPresence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$SymbolicLink
    )

    $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
    if ($null -eq $bashCommand) {
        return $false
    }

    $operator = if ($SymbolicLink) { '-L' } else { '-e' }
    $testCommand = 'test ' + $operator + ' ' + (ConvertTo-BashSingleQuotedLiteral -Value $Path)
    $result = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', $testCommand)
    return $result.ExitCode -eq 0
}

function Test-LinuxCommandLinkPresence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-LinuxPathPresence -Path $Path -SymbolicLink) {
        return $true
    }

    if (Test-BashHasCygpath) {
        return Test-LinuxPathPresence -Path $Path
    }

    return $false
}

function Initialize-PlatformPrefixArgument {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [object]$Layout
    )

    if ($Platform -eq 'linux') {
        $prefixDirectory = Join-Path -Path $Layout.Home -ChildPath ('prefix-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $prefixDirectory | Out-Null
        return ConvertTo-BashPath -Path $prefixDirectory
    }

    return Initialize-TemporaryPrefixDirectory
}

function Get-UnavailableManifestContent {
    @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      windows:
        kind: unavailable
      linux:
        kind: unavailable
'@
}

function Get-DryRunManifestContent {
    @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: pip
        package: sample-tool
      linux:
        kind: pip
        package: sample-tool
'@
}

function Invoke-DirectCliCase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [string]$ManifestContent,

        [string[]]$Arguments = @()
    )

    $layout = Initialize-IsolatedScriptLayout -ManifestContent $ManifestContent
    return Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments $Arguments
}

function Test-CliHelp {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    foreach ($helpOption in @('-h', '--help')) {
        $result = Invoke-DirectCliCase `
            -Platform $Platform `
            -ManifestContent (Get-UnavailableManifestContent) `
            -Arguments @($helpOption)
        Test-ExitCode -Name "CLI-001 ${Platform}: $helpOption exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText -Name "CLI-001 ${Platform}: $helpOption shows version" -Result $result -ExpectedText 'Coding Agent Toolchain'
        foreach ($option in @('--config', '--verbose', '--dry-run', '--remove', '--check-path', '--prefix', '--help')) {
            Test-ResultText -Name "CLI-001 ${Platform}: $helpOption lists $option" -Result $result -ExpectedText $option
        }
        Test-CheckCondition `
            -Name "CLI-001 ${Platform}: $helpOption does not read manifest" `
            -Condition (-not $result.Output.Contains('Using configuration:')) `
            -FailureDetail 'Help output should return before manifest processing.'
    }
}

function Test-CliConfigOption {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    foreach ($configOption in @('-c', '--config')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments @('-d', $configOption, $configPath)
        Test-ExitCode -Name "CLI-003 ${Platform}: $configOption exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText -Name "CLI-003 ${Platform}: $configOption uses supplied config" -Result $result -ExpectedText 'Using configuration:'
        Test-ResultText -Name "CLI-003 ${Platform}: $configOption dry-runs tool" -Result $result -ExpectedText 'DryRun'

        $missingValueResult = Invoke-DirectCliCase `
            -Platform $Platform `
            -ManifestContent (Get-DryRunManifestContent) `
            -Arguments @($configOption)
        Test-NonzeroExitCode -Name "CLI-004 ${Platform}: $configOption requires value" -Result $missingValueResult
        Test-CheckCondition `
            -Name "CLI-004 ${Platform}: $configOption missing value diagnostic" `
            -Condition ($missingValueResult.Output -match 'requires|argument|Missing') `
            -FailureDetail "Missing value output was: $($missingValueResult.Output)"
    }
}

function Test-CliPrefixOption {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    foreach ($prefixOption in @('-p', '--prefix')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
        $prefixPath = Initialize-PlatformPrefixArgument -Platform $Platform -Layout $layout
        $environment = @{}
        if ($Platform -eq 'linux') {
            $environment = @{
                HOME = ConvertTo-BashPath -Path $layout.Home
            }
        }
        $result = Invoke-IsolatedToolScript `
            -Platform $Platform `
            -Layout $layout `
            -Arguments @('-d', '-c', $configPath, $prefixOption, $prefixPath) `
            -Environment $environment
        Test-ExitCode -Name "CLI-005 ${Platform}: $prefixOption exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText -Name "CLI-005 ${Platform}: $prefixOption reports install root" -Result $result -ExpectedText 'Using installation root:'

        $missingValueResult = Invoke-DirectCliCase `
            -Platform $Platform `
            -ManifestContent (Get-DryRunManifestContent) `
            -Arguments @($prefixOption)
        Test-NonzeroExitCode -Name "CLI-006 ${Platform}: $prefixOption requires value" -Result $missingValueResult
        Test-CheckCondition `
            -Name "CLI-006 ${Platform}: $prefixOption missing value diagnostic" `
            -Condition ($missingValueResult.Output -match 'requires|argument|Missing') `
            -FailureDetail "Missing value output was: $($missingValueResult.Output)"
    }
}

function Test-CliModeOption {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $defaultResult = Invoke-DirectCliCase -Platform $Platform -ManifestContent (Get-UnavailableManifestContent)
    Test-ExitCode -Name "CLI-002 ${Platform}: default mode exits zero" -Result $defaultResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-002 ${Platform}: default config is used" -Result $defaultResult -ExpectedText 'Using configuration:'
    Test-ResultText -Name "CLI-002 ${Platform}: tools are processed" -Result $defaultResult -ExpectedText 'Loaded 1 tool entries'
    Test-ResultText -Name "CLI-002 ${Platform}: info loglevel is padded" -Result $defaultResult -ExpectedText '[INFO ]'
    Test-ResultText -Name "CLI-002 ${Platform}: warn loglevel is padded" -Result $defaultResult -ExpectedText '[WARN ]'
    Test-ResultTextAbsent `
        -Name "CLI-002 ${Platform}: old info loglevel is absent" `
        -Result $defaultResult `
        -UnexpectedText '[INFO]'
    Test-ResultTextAbsent `
        -Name "CLI-002 ${Platform}: old warn loglevel is absent" `
        -Result $defaultResult `
        -UnexpectedText '[WARN]'
    Test-ResultTextAbsent `
        -Name "CLI-002 ${Platform}: English warning prefix is absent" `
        -Result $defaultResult `
        -UnexpectedText 'Warning:'
    Test-ResultTextAbsent `
        -Name "CLI-002 ${Platform}: localized warning prefix is absent" `
        -Result $defaultResult `
        -UnexpectedText 'AVERTISSEMENT'

    foreach ($verboseOption in @('-v', '--verbose')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments @('-d', $verboseOption, '-c', $configPath)
        Test-ExitCode -Name "CLI-007 ${Platform}: $verboseOption exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText -Name "CLI-007 ${Platform}: $verboseOption emits debug" -Result $result -ExpectedText '[DEBUG]'
    }

    if ($Platform -eq 'windows') {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments @('-d', '-Verbose', '-c', $configPath)
        Test-ExitCode -Name 'CLI-008 windows: native -Verbose exits zero' -Result $result -ExpectedExitCode 0
        Test-ResultText -Name 'CLI-008 windows: native -Verbose emits debug' -Result $result -ExpectedText '[DEBUG]'
    }

    $dryRunResult = Invoke-DirectCliCase -Platform $Platform -ManifestContent (Get-DryRunManifestContent) -Arguments @('-d')
    Test-ExitCode -Name "CLI-009 ${Platform}: dry-run exits zero" -Result $dryRunResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-009 ${Platform}: dry-run enabled" -Result $dryRunResult -ExpectedText 'Dry-run mode enabled'
    Test-ResultText -Name "CLI-009 ${Platform}: dry-run status" -Result $dryRunResult -ExpectedText 'DryRun'
    Test-ResultText -Name "CLI-009 ${Platform}: dry-run info loglevel is padded" -Result $dryRunResult -ExpectedText '[INFO ]'

    foreach ($removeOption in @('-r', '--remove')) {
        $result = Invoke-DirectCliCase -Platform $Platform -ManifestContent (Get-UnavailableManifestContent) -Arguments @($removeOption)
        Test-ExitCode -Name "CLI-010 ${Platform}: $removeOption exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText -Name "CLI-010 ${Platform}: $removeOption uses removal flow" -Result $result -ExpectedText 'Tool removal summary:'
        Test-CheckCondition `
            -Name "CLI-010 ${Platform}: $removeOption skips install summary" `
            -Condition (-not $result.Output.Contains('Tool installation summary:')) `
            -FailureDetail 'Remove mode should not print install summary.'
    }
}

function Test-CliCheckPathAndInvalidOption {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $checkPathResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-UnavailableManifestContent) `
        -Arguments @('--check-path')
    Test-ExitCode -Name "CLI-011 ${Platform}: check-path exits zero" -Result $checkPathResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-011 ${Platform}: check-path prints table" -Result $checkPathResult -ExpectedText 'PATH verification:'

    $removeCheckPathResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-UnavailableManifestContent) `
        -Arguments @('--check-path', '--remove')
    Test-ExitCode -Name "CLI-012 ${Platform}: remove check-path exits zero" -Result $removeCheckPathResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-012 ${Platform}: remove flow runs" -Result $removeCheckPathResult -ExpectedText 'Tool removal summary:'
    Test-CheckCondition `
        -Name "CLI-012 ${Platform}: install path verification not printed" `
        -Condition (-not $removeCheckPathResult.Output.Contains('PATH verification:')) `
        -FailureDetail '--check-path must not print install path verification in remove mode.'

    $dryRunCheckPathResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-DryRunManifestContent) `
        -Arguments @('--dry-run', '--check-path')
    Test-ExitCode -Name "CLI-013 ${Platform}: dry-run check-path exits zero" -Result $dryRunCheckPathResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-013 ${Platform}: dry-run status" -Result $dryRunCheckPathResult -ExpectedText 'DryRun'
    Test-ResultText -Name "CLI-013 ${Platform}: simulated path status" -Result $dryRunCheckPathResult -ExpectedText 'Simulated'

    $unknownResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-UnavailableManifestContent) `
        -Arguments @('--unknown-option')
    Test-NonzeroExitCode -Name "CLI-014 ${Platform}: unknown option fails" -Result $unknownResult
    Test-ResultText -Name "CLI-014 ${Platform}: unknown option diagnostic" -Result $unknownResult -ExpectedText 'Unknown option'
    if ($Platform -eq 'linux') {
        Test-ResultText -Name 'CLI-014 linux: error loglevel is normalized' -Result $unknownResult -ExpectedText '[ERROR]'
        Test-ResultTextAbsent `
            -Name 'CLI-014 linux: English error prefix is absent' `
            -Result $unknownResult `
            -UnexpectedText 'Error:'
    }

    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
    $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
    $mixedResult = Invoke-IsolatedToolScript `
        -Platform $Platform `
        -Layout $layout `
        -Arguments @('--check-path', '-d', '--config', $configPath)
    Test-ExitCode -Name "CLI-015 ${Platform}: mixed options exit zero" -Result $mixedResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-015 ${Platform}: mixed options dry-run" -Result $mixedResult -ExpectedText 'DryRun'
    Test-ResultText -Name "CLI-015 ${Platform}: mixed options check-path" -Result $mixedResult -ExpectedText 'PATH verification:'

    $helpWithFlagsResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-DryRunManifestContent) `
        -Arguments @('-d', '--help')
    Test-ExitCode -Name "CLI-016 ${Platform}: help with valid flags exits zero" -Result $helpWithFlagsResult -ExpectedExitCode 0
    Test-ResultText -Name "CLI-016 ${Platform}: help output shown" -Result $helpWithFlagsResult -ExpectedText 'Usage:'
    Test-CheckCondition `
        -Name "CLI-016 ${Platform}: help avoids state-changing flow" `
        -Condition (-not $helpWithFlagsResult.Output.Contains('Starting Coding Agent Toolchain')) `
        -FailureDetail 'Help should return before normal execution.'

    $invalidBeforeHelpResult = Invoke-DirectCliCase `
        -Platform $Platform `
        -ManifestContent (Get-DryRunManifestContent) `
        -Arguments @('--unknown-option', '--help')
    Test-NonzeroExitCode -Name "CLI-017 ${Platform}: invalid before help fails" -Result $invalidBeforeHelpResult
    Test-ResultText -Name "CLI-017 ${Platform}: invalid before help diagnostic" -Result $invalidBeforeHelpResult -ExpectedText 'Unknown option'
}

function Test-ElevatedPublicModeRejection {
    $modeCases = @(
        [pscustomobject]@{ Name = 'short help'; Arguments = @('-h') },
        [pscustomobject]@{ Name = 'long help'; Arguments = @('--help') },
        [pscustomobject]@{ Name = 'default install'; Arguments = @() },
        [pscustomobject]@{ Name = 'dry-run'; Arguments = @('--dry-run') },
        [pscustomobject]@{ Name = 'check-path'; Arguments = @('--check-path') },
        [pscustomobject]@{ Name = 'remove'; Arguments = @('--remove') }
    )

    foreach ($platform in @('windows', 'linux')) {
        $testId = if ($platform -eq 'windows') { 'SAFETY-002' } else { 'SAFETY-001' }
        $identityText = if ($platform -eq 'windows') { 'Administrator' } else { 'root' }

        foreach ($modeCase in $modeCases) {
            $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
            $environment = if ($platform -eq 'windows') {
                @{ CAT_TEST_FORCE_ADMINISTRATOR = '1' }
            } else {
                @{ CAT_TEST_FORCE_ROOT = '1' }
            }

            $result = Invoke-IsolatedToolScript `
                -Platform $platform `
                -Layout $layout `
                -Arguments $modeCase.Arguments `
                -Environment $environment

            Test-NonzeroExitCode -Name "$testId ${platform}: $($modeCase.Name) rejects elevated identity" -Result $result
            Test-ResultText `
                -Name "$testId ${platform}: $($modeCase.Name) reports elevated identity" `
                -Result $result `
                -ExpectedText $identityText
            Test-ResultTextAbsent `
                -Name "$testId ${platform}: $($modeCase.Name) does not start normal flow" `
                -Result $result `
                -UnexpectedText 'Starting Coding Agent Toolchain'
            Test-ResultTextAbsent `
                -Name "$testId ${platform}: $($modeCase.Name) does not read manifest" `
                -Result $result `
                -UnexpectedText 'Loaded '
        }
    }
}

function Test-CliConfigAndPrefixFailure {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    foreach ($configOption in @('-c', '--config')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
        $missingPath = Get-PlatformPathArgument -Platform $Platform -Path (Join-Path -Path $layout.Root -ChildPath 'missing.yaml')
        $result = Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments @($configOption, $missingPath)
        $testId = if ($configOption -eq '-c') { 'CLI-018' } else { 'CLI-019' }
        Test-NonzeroExitCode -Name "$testId ${Platform}: missing config fails" -Result $result
        Test-ResultText -Name "$testId ${Platform}: missing config diagnostic" -Result $result -ExpectedText 'Configuration file not found'
        if ($configOption -eq '-c') {
            Test-NonzeroExitCode -Name "MANIFEST-002 ${Platform}: missing manifest path fails" -Result $result
            Test-ResultText `
                -Name "MANIFEST-002 ${Platform}: missing manifest path diagnostic" `
                -Result $result `
                -ExpectedText 'Configuration file not found'
        }

        $plainTextLayout = Initialize-IsolatedScriptLayout -ManifestContent 'not yaml'
        $plainTextConfig = Get-PlatformPathArgument -Platform $Platform -Path $plainTextLayout.ManifestPath
        $plainTextResult = Invoke-IsolatedToolScript -Platform $Platform -Layout $plainTextLayout -Arguments @($configOption, $plainTextConfig)
        $plainTextTestId = if ($configOption -eq '-c') { 'CLI-022' } else { 'CLI-023' }
        Test-NonzeroExitCode -Name "$plainTextTestId ${Platform}: non-YAML config fails" -Result $plainTextResult
        Test-CheckCondition `
            -Name "$plainTextTestId ${Platform}: non-YAML diagnostic" `
            -Condition ($plainTextResult.Output -match 'Unsupported manifest line|Unsupported schema_version') `
            -FailureDetail "Unexpected non-YAML output: $($plainTextResult.Output)"
        if ($configOption -eq '-c') {
            Test-NonzeroExitCode -Name "MANIFEST-014 ${Platform}: non-YAML config fails" -Result $plainTextResult
            Test-CheckCondition `
                -Name "MANIFEST-014 ${Platform}: non-YAML diagnostic" `
                -Condition ($plainTextResult.Output -match 'Unsupported manifest line|Unsupported schema_version') `
                -FailureDetail "Unexpected non-YAML output: $($plainTextResult.Output)"
        }
    }

    foreach ($prefixOption in @('-p', '--prefix')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
        $invalidPrefix = if ($Platform -eq 'windows') { 'C:\Windows' } else { '/usr' }
        $result = Invoke-IsolatedToolScript `
            -Platform $Platform `
            -Layout $layout `
            -Arguments @('-d', '-c', $configPath, $prefixOption, $invalidPrefix)
        $testId = if ($prefixOption -eq '-p') { 'CLI-024' } else { 'CLI-025' }
        Test-NonzeroExitCode -Name "$testId ${Platform}: outside-root prefix fails" -Result $result
        Test-ResultText -Name "$testId ${Platform}: outside-root prefix diagnostic" -Result $result -ExpectedText '--prefix must point inside'
    }
}

function Test-DirectCliParsing {
    foreach ($platform in @('windows', 'linux')) {
        Test-CliHelp -Platform $platform
        Test-CliConfigOption -Platform $platform
        Test-CliPrefixOption -Platform $platform
        Test-CliModeOption -Platform $platform
        Test-CliCheckPathAndInvalidOption -Platform $platform
        Test-CliConfigAndPrefixFailure -Platform $platform
    }

    Test-ElevatedPublicModeRejection
}

function Invoke-ManifestCase {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [Parameter(Mandatory = $true)]
        [string]$ManifestContent,

        [switch]$DryRun
    )

    $layout = Initialize-IsolatedScriptLayout -ManifestContent $ManifestContent
    $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
    $arguments = if ($DryRun) { @('-d', '-c', $configPath) } else { @('-c', $configPath) }
    return Invoke-IsolatedToolScript -Platform $Platform -Layout $layout -Arguments $arguments
}

function Get-ManifestWithPlatformInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform,

        [string]$InstallerBlock = '        kind: unavailable'
    )

    $otherPlatform = if ($Platform -eq 'windows') { 'linux' } else { 'windows' }
    @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
$InstallerBlock
      ${otherPlatform}:
        kind: unavailable
"@
}

function Test-ManifestLoadAndSchema {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $canonicalManifest = Get-RepositoryText -RelativePath 'config/tools.yaml'
    $canonicalResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $canonicalManifest -DryRun
    Test-ExitCode -Name "MANIFEST-001 ${Platform}: canonical manifest exits zero" -Result $canonicalResult -ExpectedExitCode 0
    Test-ResultText -Name "MANIFEST-001 ${Platform}: canonical tool count" -Result $canonicalResult -ExpectedText 'Loaded 24 tool entries'
    Test-ResultText -Name "MANIFEST-001 ${Platform}: first tool appears" -Result $canonicalResult -ExpectedText "Checking tool 'yamllint'"
    Test-ResultText -Name "MANIFEST-001 ${Platform}: last tool appears" -Result $canonicalResult -ExpectedText "Checking tool 'codespell'"

    $otherPlatform = if ($Platform -eq 'windows') { 'linux' } else { 'windows' }
    $validSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $schemaTwoManifest = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: direct_binary
        url: https://example.invalid/releases/v1.0.0/sample-tool
        sha256: $validSha256
      ${otherPlatform}:
        kind: unavailable
"@
    $schemaTwoResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoManifest -DryRun
    Test-ExitCode -Name "MANIFEST-003 ${Platform}: schema 2 direct artifact exits zero" -Result $schemaTwoResult -ExpectedExitCode 0

    $unsupportedSchema = @'
schema_version: 3
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      windows:
        kind: unavailable
      linux:
        kind: unavailable
'@
    $schemaResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $unsupportedSchema
    Test-NonzeroExitCode -Name "MANIFEST-003 ${Platform}: unsupported schema fails" -Result $schemaResult
    Test-ResultText -Name "MANIFEST-003 ${Platform}: unsupported schema diagnostic" -Result $schemaResult -ExpectedText 'Unsupported schema_version'

    $emptyManifest = @'
schema_version: 1
tools:
'@
    $emptyResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $emptyManifest
    Test-NonzeroExitCode -Name "MANIFEST-004 ${Platform}: no tools fails" -Result $emptyResult
    Test-ResultText -Name "MANIFEST-004 ${Platform}: no tools diagnostic" -Result $emptyResult -ExpectedText 'manifest does not define any tools'
}

function Test-ManifestInvalidShape {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $missingExecutable = @'
schema_version: 1
tools:
  - id: sample-tool
    installers:
      windows:
        kind: unavailable
      linux:
        kind: unavailable
'@
    $missingExecutableResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $missingExecutable
    Test-NonzeroExitCode -Name "MANIFEST-005 ${Platform}: missing executable fails" -Result $missingExecutableResult
    Test-ResultText -Name "MANIFEST-005 ${Platform}: missing executable names tool" -Result $missingExecutableResult -ExpectedText "Tool 'sample-tool' must define an executable"

    $installerOutsidePlatform = @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      kind: unavailable
'@
    $outsidePlatformResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $installerOutsidePlatform
    Test-NonzeroExitCode -Name "MANIFEST-006 ${Platform}: installer property outside platform fails" -Result $outsidePlatformResult
    Test-ResultText -Name "MANIFEST-006 ${Platform}: installer property diagnostic" -Result $outsidePlatformResult -ExpectedText 'Installer property without platform'

    $unsupportedKey = Get-ManifestWithPlatformInstaller `
        -Platform $Platform `
        -InstallerBlock @'
        kind: unavailable
        unsupported_key: value
'@
    $unsupportedKeyResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $unsupportedKey
    Test-NonzeroExitCode -Name "MANIFEST-007 ${Platform}: unsupported key fails" -Result $unsupportedKeyResult
    Test-ResultText -Name "MANIFEST-007 ${Platform}: unsupported key diagnostic" -Result $unsupportedKeyResult -ExpectedText 'Unsupported installer key'

    $otherPlatform = if ($Platform -eq 'windows') { 'linux' } else { 'windows' }
    $unsupportedOtherPlatformKey = @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: unavailable
      ${otherPlatform}:
        kind: unavailable
        unsupported_key: value
"@
    $unsupportedOtherPlatformKeyResult = Invoke-ManifestCase `
        -Platform $Platform `
        -ManifestContent $unsupportedOtherPlatformKey
    Test-NonzeroExitCode `
        -Name "MANIFEST-007 ${Platform}: unsupported other-platform key fails" `
        -Result $unsupportedOtherPlatformKeyResult
    Test-ResultText `
        -Name "MANIFEST-007 ${Platform}: unsupported other-platform key diagnostic" `
        -Result $unsupportedOtherPlatformKeyResult `
        -ExpectedText 'Unsupported installer key'

    $unsupportedLine = @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    unexpected:
'@
    $unsupportedLineResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $unsupportedLine
    Test-NonzeroExitCode -Name "MANIFEST-008 ${Platform}: unsupported line fails" -Result $unsupportedLineResult
    Test-ResultText -Name "MANIFEST-008 ${Platform}: unsupported line diagnostic" -Result $unsupportedLineResult -ExpectedText 'Unsupported manifest line'

    $invalidYamlShape = @'
schema_version: 1
tools:
    - id: sample-tool
'@
    $invalidYamlResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $invalidYamlShape
    Test-NonzeroExitCode -Name "MANIFEST-015 ${Platform}: invalid YAML shape fails" -Result $invalidYamlResult
    Test-ResultText -Name "MANIFEST-015 ${Platform}: invalid YAML shape diagnostic" -Result $invalidYamlResult -ExpectedText 'Unsupported manifest line'

    $validSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $schemaTwoMissingHash = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: direct_binary
        url: https://example.invalid/releases/v1.0.0/sample-tool
      ${otherPlatform}:
        kind: unavailable
"@
    $missingHashResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoMissingHash
    Test-NonzeroExitCode -Name "SUPPLY-002 ${Platform}: schema 2 missing sha256 fails" -Result $missingHashResult
    Test-ResultText -Name "SUPPLY-002 ${Platform}: schema 2 missing sha256 diagnostic" -Result $missingHashResult -ExpectedText 'must define sha256'

    $schemaTwoInvalidHash = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: direct_binary
        url: https://example.invalid/releases/v1.0.0/sample-tool
        sha256: not-a-sha
      ${otherPlatform}:
        kind: unavailable
"@
    $invalidHashResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoInvalidHash
    Test-NonzeroExitCode -Name "SUPPLY-002 ${Platform}: schema 2 invalid sha256 fails" -Result $invalidHashResult
    Test-ResultText -Name "SUPPLY-002 ${Platform}: schema 2 invalid sha256 diagnostic" -Result $invalidHashResult -ExpectedText 'invalid sha256'

    $schemaTwoMovingUrl = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: direct_binary
        url: https://example.invalid/latest/sample-tool
        sha256: $validSha256
      ${otherPlatform}:
        kind: unavailable
"@
    $movingUrlResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoMovingUrl
    Test-NonzeroExitCode -Name "SUPPLY-003 ${Platform}: schema 2 moving URL fails" -Result $movingUrlResult
    Test-ResultText -Name "SUPPLY-003 ${Platform}: schema 2 moving URL diagnostic" -Result $movingUrlResult -ExpectedText 'must not use latest'

    $schemaTwoMissingReleaseTag = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: github_release_asset
        owner: example
        repo: sample
        asset_pattern: sample-tool
        sha256: $validSha256
      ${otherPlatform}:
        kind: unavailable
"@
    $missingReleaseTagResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoMissingReleaseTag
    Test-NonzeroExitCode -Name "SUPPLY-003 ${Platform}: schema 2 missing release_tag fails" -Result $missingReleaseTagResult
    Test-ResultText -Name "SUPPLY-003 ${Platform}: schema 2 missing release_tag diagnostic" -Result $missingReleaseTagResult -ExpectedText 'must define release_tag'

    $schemaTwoMovingReleaseTag = @"
schema_version: 2
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
        kind: github_release_asset
        owner: example
        repo: sample
        asset_pattern: sample-tool
        release_tag: latest
        sha256: $validSha256
      ${otherPlatform}:
        kind: unavailable
"@
    $movingReleaseTagResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $schemaTwoMovingReleaseTag
    Test-NonzeroExitCode -Name "SUPPLY-003 ${Platform}: schema 2 moving release_tag fails" -Result $movingReleaseTagResult
    Test-ResultText -Name "SUPPLY-003 ${Platform}: schema 2 moving release_tag diagnostic" -Result $movingReleaseTagResult -ExpectedText 'release_tag must not be'
}

function Test-ManifestPlatformAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $otherPlatform = if ($Platform -eq 'windows') { 'linux' } else { 'windows' }
    $missingPlatform = @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${otherPlatform}:
        kind: unavailable
"@
    $missingPlatformResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $missingPlatform -DryRun
    Test-ExitCode -Name "MANIFEST-009 ${Platform}: missing platform installer exits zero" -Result $missingPlatformResult -ExpectedExitCode 0
    Test-ResultText -Name "MANIFEST-009 ${Platform}: missing platform skipped" -Result $missingPlatformResult -ExpectedText 'Skipped'

    $missingKind = @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      ${Platform}:
      ${otherPlatform}:
        kind: unavailable
"@
    $missingKindResult = Invoke-ManifestCase -Platform $Platform -ManifestContent $missingKind -DryRun
    Test-ExitCode -Name "MANIFEST-010 ${Platform}: missing kind exits zero" -Result $missingKindResult -ExpectedExitCode 0
    Test-ResultText -Name "MANIFEST-010 ${Platform}: missing kind skipped" -Result $missingKindResult -ExpectedText 'Skipped'
}

function Get-QuotedManifestContent {
    @'
schema_version: "1"
tools:
  - id: "quoted-tool"
    executable: "unused-tool"
    version_args:
      - "-c"
      - "echo manifest-args:--alpha --beta"
    installers:
      windows:
        kind: "pip"
        package: "quoted-package"
        executable: "bash"
      linux:
        kind: "pip"
        package: "quoted-package"
        executable: "bash"
'@
}

function Get-CommandAvailableManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $otherPlatform = if ($Platform -eq 'windows') { 'linux' } else { 'windows' }
    $executable = if ($Platform -eq 'linux') { 'false' } else { 'sample-tool' }
    @"
schema_version: 1
tools:
  - id: sample-tool
    executable: $executable
    version_check: command_available
    installers:
      ${Platform}:
        kind: direct_binary
      ${otherPlatform}:
        kind: unavailable
"@
}

function Test-ManifestQuotedValue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-QuotedManifestContent)
    $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
    $result = Invoke-IsolatedToolScript `
        -Platform $Platform `
        -Layout $layout `
        -Arguments @('--check-path', '-c', $configPath)
    Test-ExitCode -Name "MANIFEST-011 ${Platform}: quoted values exit zero" -Result $result -ExpectedExitCode 0
    Test-ResultText `
        -Name "MANIFEST-011 ${Platform}: quoted tool id is unquoted" `
        -Result $result `
        -ExpectedText "Checking tool 'quoted-tool'"
    Test-ResultText `
        -Name "MANIFEST-011 ${Platform}: version args preserve order" `
        -Result $result `
        -ExpectedText 'manifest-args:--alpha --beta'
    Test-ResultText -Name "INSTALL-001 ${Platform}: existing command is present" -Result $result -ExpectedText 'Present'
    Test-CheckCondition `
        -Name "INSTALL-001 ${Platform}: install branch is skipped" `
        -Condition (-not $result.Output.Contains("Installing 'quoted-tool'")) `
        -FailureDetail 'Install branch ran even though the command was already available.'
    Test-ResultText -Name "PATH-012 ${Platform}: present command directory is in PATH" -Result $result -ExpectedText 'InPath'
}

function Test-ManifestCommandAvailableVersionCheck {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows', 'linux')]
        [string]$Platform
    )

    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-CommandAvailableManifestContent -Platform $Platform)
    $configPath = Get-PlatformPathArgument -Platform $Platform -Path $layout.ManifestPath
    $environment = @{}

    if ($Platform -eq 'windows') {
        $commandDirectory = Join-Path -Path $layout.Root -ChildPath 'fake-bin'
        New-Item -ItemType Directory -Path $commandDirectory | Out-Null
        $commandPath = Join-Path -Path $commandDirectory -ChildPath 'sample-tool.cmd'
        Set-Content `
            -LiteralPath $commandPath `
            -Value @('@echo off', 'echo unexpected-execution', 'exit /b 23') `
            -Encoding ASCII
        $environment = @{
            PATH = "$commandDirectory$([IO.Path]::PathSeparator)$env:PATH"
        }
    }

    $result = Invoke-IsolatedToolScript `
        -Platform $Platform `
        -Layout $layout `
        -Arguments @('--check-path', '-c', $configPath) `
        -Environment $environment
    Test-ExitCode -Name "MANIFEST-016 ${Platform}: command_available exits zero" -Result $result -ExpectedExitCode 0
    Test-ResultText -Name "MANIFEST-016 ${Platform}: command is present" -Result $result -ExpectedText 'Present'
    Test-ResultText -Name "MANIFEST-016 ${Platform}: availability version reported" -Result $result -ExpectedText 'available'
    Test-ResultTextAbsent `
        -Name "MANIFEST-016 ${Platform}: command is not executed" `
        -Result $result `
        -UnexpectedText 'unexpected-execution'
    Test-CheckCondition `
        -Name "MANIFEST-016 ${Platform}: install branch is skipped" `
        -Condition (-not $result.Output.Contains("Installing 'sample-tool'")) `
        -FailureDetail 'Install branch ran even though the command was already available.'
}

function Test-ManifestLinuxCompatibility {
    $ghostscriptCondaForge = @'
schema_version: 1
tools:
  - id: ghostscript
    executable: gs
    installers:
      linux:
        kind: conda_forge
        package: ghostscript
'@
    $result = Invoke-ManifestCase -Platform 'linux' -ManifestContent $ghostscriptCondaForge -DryRun
    Test-ExitCode -Name 'MANIFEST-012 linux: conda_forge compatibility exits zero' -Result $result -ExpectedExitCode 0
    Test-ResultText -Name 'MANIFEST-012 linux: conda_forge compatibility message' -Result $result -ExpectedText 'prefer'
    Test-ResultText -Name 'MANIFEST-012 linux: normalized source_make dry-run' -Result $result -ExpectedText 'source_make'
}

function Test-DirectManifestParsing {
    foreach ($platform in @('windows', 'linux')) {
        Test-ManifestLoadAndSchema -Platform $platform
        Test-ManifestInvalidShape -Platform $platform
        Test-ManifestPlatformAvailability -Platform $platform
        Test-ManifestQuotedValue -Platform $platform
        Test-ManifestCommandAvailableVersionCheck -Platform $platform
    }

    Test-ManifestLinuxCompatibility
}

function Get-UnsupportedKindManifestContent {
    @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unsupported_kind
      linux:
        kind: unsupported_kind
'@
}

function Get-LinuxInteropPathManifestContent {
    @'
schema_version: 1
tools:
  - id: interop-tool
    executable: interop-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: direct_binary
'@
}

function Get-LinuxDirectBinaryManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$FileName = 'sample-tool',

        [string]$Kind = 'direct_binary',

        [string]$ArchiveKind = '',

        [string]$ArchivePath = '',

        [string]$SchemaVersion = '1',

        [string]$Sha256 = ''
    )

    $manifest = @"
schema_version: $SchemaVersion
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: $Kind
        url: $Url
        file_name: $FileName
"@
    $manifest += "`n"
    if (-not [string]::IsNullOrWhiteSpace($ArchiveKind)) {
        $manifest += "        archive_kind: $ArchiveKind`n"
    }

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $manifest += "        archive_path: $ArchivePath`n"
    }

    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $manifest += "        sha256: $Sha256`n"
    }

    return $manifest
}

function Get-LinuxGitHubReleaseManifestContent {
    param(
        [string]$Owner = 'example',

        [string]$Repo = 'sample',

        [string]$AssetPattern = 'sample-tool-linux',

        [string]$FileName = 'sample-tool'
    )

    @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: github_release_asset
        owner: $Owner
        repo: $Repo
        asset_pattern: $AssetPattern
        file_name: $FileName
"@
}

function Get-LinuxPortableArchiveManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: portable_archive
        url: $Url
        archive_kind: tar_gz
        archive_path: bin/sample-tool
        bin_path: bin
"@
}

function Get-LinuxPackageInstallerManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [string]$Package = 'sample-tool'
    )

    @"
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: $Kind
        package: $Package
"@
}

function Get-LinuxSourceMakeManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$ToolId = 'sample-tool',

        [string]$Package = ''
    )

    $manifest = @"
schema_version: 1
tools:
  - id: $ToolId
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: unavailable
      linux:
        kind: source_make
        url: $Url
        source_dir: sample-source
        bin_path: bin
"@
    $manifest += "`n"

    if (-not [string]::IsNullOrWhiteSpace($Package)) {
        $manifest += "        package: $Package`n"
    }

    return $manifest
}

function ConvertTo-FileUriString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ([uri](Resolve-Path -LiteralPath $Path).ProviderPath).AbsoluteUri
}

function Get-WindowsPackageInstallerManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [string]$Package = 'cat-test-tool'
    )

    @"
schema_version: 1
tools:
  - id: cat-test-tool
    executable: cat-test-tool
    version_args:
      - --version
    installers:
      windows:
        kind: $Kind
        package: $Package
      linux:
        kind: unavailable
"@
}

function Get-WindowsPortableArchiveManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    @"
schema_version: 1
tools:
  - id: cat-test-tool
    executable: cat-test-tool.cmd
    version_args:
      - --version
    installers:
      windows:
        kind: portable_archive
        url: $Url
        archive_kind: seven_zip
        archive_path: bin/cat-test-tool.cmd
        bin_path: bin
      linux:
        kind: unavailable
"@
}

function Get-WindowsDirectBinaryManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$ArchiveKind = '',

        [string]$ArchivePath = ''
    )

    $manifest = @"
schema_version: 1
tools:
  - id: cat-test-tool
    executable: cat-test-tool.cmd
    version_args:
      - --version
    installers:
      windows:
        kind: direct_binary
        url: $Url
        file_name: cat-test-tool.cmd
"@
    $manifest += "`n"
    if (-not [string]::IsNullOrWhiteSpace($ArchiveKind)) {
        $manifest += "        archive_kind: $ArchiveKind`n"
    }

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $manifest += "        archive_path: $ArchivePath`n"
    }

    $manifest += @"
      linux:
        kind: unavailable
"@

    return $manifest
}

function Get-WindowsDirectInstallerManifestContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    @"
schema_version: 1
tools:
  - id: cat-test-tool
    executable: cat-test-tool.cmd
    version_args:
      - --version
    installers:
      windows:
        kind: direct_installer
        url: $Url
        target_arg_prefix: --target=
      linux:
        kind: unavailable
"@
}

function Write-WindowsCommandFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$VersionText
    )

    Set-Content -LiteralPath $Path -Value @(
        '@echo off'
        "echo $VersionText"
    ) -Encoding ASCII
}

function Initialize-ZipArchiveFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry($EntryName)
        $entryStream = $entry.Open()
        $sourceStream = [IO.File]::OpenRead($SourcePath)
        try {
            $sourceStream.CopyTo($entryStream)
        } finally {
            $sourceStream.Dispose()
            $entryStream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Initialize-WindowsDispatchFixture {
    param(
        [switch]$IncludeDirectInstaller
    )

    $prefixPath = Initialize-TemporaryPrefixDirectory
    $fakeBinDirectory = Join-Path -Path $prefixPath -ChildPath 'fake-bin'
    $sourceDirectory = Join-Path -Path $prefixPath -ChildPath 'source'
    $installDirectory = Join-Path -Path $prefixPath -ChildPath 'coding-agent-toolchain\cat-test-tool'
    New-Item -ItemType Directory -Path $fakeBinDirectory, $sourceDirectory | Out-Null

    $toolCommandName = 'cat-test-tool.cmd'
    $installedBinDirectory = Join-Path -Path $installDirectory -ChildPath 'bin'
    $fakeBinToolPath = Join-Path -Path $fakeBinDirectory -ChildPath $toolCommandName
    $installedToolPath = Join-Path -Path $installDirectory -ChildPath $toolCommandName
    $portableInstalledToolPath = Join-Path -Path $installedBinDirectory -ChildPath $toolCommandName
    $portableRootPath = Join-Path -Path $installDirectory -ChildPath 'portable-root.txt'
    $portableSourcePath = Join-Path -Path $sourceDirectory -ChildPath $toolCommandName
    Write-WindowsCommandFile -Path $portableSourcePath -VersionText 'portable-version'

    $zipSourcePath = Join-Path -Path $sourceDirectory -ChildPath 'zip-tool.cmd'
    Write-WindowsCommandFile -Path $zipSourcePath -VersionText 'zip-version'
    $zipArchivePath = Join-Path -Path $sourceDirectory -ChildPath 'direct.zip'
    Initialize-ZipArchiveFile -Path $zipArchivePath -EntryName $toolCommandName -SourcePath $zipSourcePath
    $unsafeZipArchivePath = Join-Path -Path $sourceDirectory -ChildPath 'unsafe.zip'
    Initialize-ZipArchiveFile -Path $unsafeZipArchivePath -EntryName "../$toolCommandName" -SourcePath $zipSourcePath
    $missingDirectBinaryPath = Join-Path -Path $sourceDirectory -ChildPath 'missing-direct.cmd'

    $portableArchivePath = Join-Path -Path $sourceDirectory -ChildPath 'portable.7z'
    Set-Content -LiteralPath $portableArchivePath -Value 'synthetic portable archive' -Encoding ASCII

    Set-Content -LiteralPath (Join-Path -Path $fakeBinDirectory -ChildPath 'winget.cmd') -Value @(
        '@echo off'
        'if /I not "%~1"=="install" exit /b 2'
        '('
        '  echo @echo off'
        '  echo echo winget-version'
        ') > "%CAT_TEST_WINDOWS_FAKE_BIN%\cat-test-tool.cmd"'
        'exit /b 0'
    ) -Encoding ASCII

    Set-Content -LiteralPath (Join-Path -Path $fakeBinDirectory -ChildPath 'choco.cmd') -Value @(
        '@echo off'
        'if /I not "%~1"=="install" exit /b 2'
        '('
        '  echo @echo off'
        '  echo echo choco-version'
        ') > "%CAT_TEST_WINDOWS_FAKE_BIN%\cat-test-tool.cmd"'
        'exit /b 0'
    ) -Encoding ASCII

    Set-Content -LiteralPath (Join-Path -Path $fakeBinDirectory -ChildPath 'tar.cmd') -Value @(
        '@echo off'
        'if /I "%~1"=="-tf" ('
        '  echo bin/cat-test-tool.cmd'
        '  echo portable-root.txt'
        '  exit /b 0'
        ')'
        'if /I "%~1"=="-tvf" ('
        '  echo -rw-r--r--  0 0      0           0 Jan 01 00:00 bin/cat-test-tool.cmd'
        '  echo -rw-r--r--  0 0      0           0 Jan 01 00:00 portable-root.txt'
        '  exit /b 0'
        ')'
        'set "destination="'
        ':next'
        'if "%~1"=="" goto done'
        'if /I "%~1"=="-C" ('
        '  set "destination=%~2"'
        '  shift'
        '  shift'
        '  goto next'
        ')'
        'shift'
        'goto next'
        ':done'
        'if "%destination%"=="" exit /b 2'
        'if not exist "%destination%" mkdir "%destination%"'
        'if not exist "%destination%\bin" mkdir "%destination%\bin"'
        'copy /Y "%CAT_TEST_WINDOWS_PORTABLE_SOURCE%" "%destination%\bin\cat-test-tool.cmd" >nul'
        'echo portable root>"%destination%\portable-root.txt"'
        'exit /b %ERRORLEVEL%'
    ) -Encoding ASCII

    $directInstallerUrl = ''
    $directInstallerWarning = ''
    if ($IncludeDirectInstaller) {
        $installerSourcePath = Join-Path -Path $sourceDirectory -ChildPath 'installer-source.exe'
        $className = 'CatTestInstaller' + [guid]::NewGuid().ToString('N')
        $installerSource = @"
using System;
using System.IO;
using System.Text;

public static class $className
{
    public static int Main(string[] args)
    {
        string target = string.Empty;
        foreach (string argument in args)
        {
            if (argument.StartsWith("--target=", StringComparison.OrdinalIgnoreCase))
            {
                target = argument.Substring("--target=".Length);
            }
        }

        if (string.IsNullOrWhiteSpace(target))
        {
            return 2;
        }

        Directory.CreateDirectory(target);
        File.WriteAllText(
            Path.Combine(target, "cat-test-tool.cmd"),
            "@echo off\r\necho installer-version\r\n",
            Encoding.ASCII);
        return 0;
    }
}
"@
        try {
            Add-Type `
                -TypeDefinition $installerSource `
                -OutputAssembly $installerSourcePath `
                -OutputType ConsoleApplication
            $directInstallerUrl = ConvertTo-FileUriString -Path $installerSourcePath
        } catch {
            $directInstallerWarning = 'DISPATCH-012 windows skipped because the direct installer fixture could not be compiled: ' +
                $_.Exception.Message
        }
    }

    $windowsPathEntries = @($fakeBinDirectory, $installDirectory)
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $windowsPathEntries += Join-Path -Path $env:SystemRoot -ChildPath 'System32'
        $windowsPathEntries += $env:SystemRoot
    }

    return [pscustomobject]@{
        PrefixPath = $prefixPath
        FakeBinDirectory = $fakeBinDirectory
        FakeBinToolPath = $fakeBinToolPath
        FakeBinMarkerPath = Join-Path -Path $fakeBinDirectory -ChildPath '.coding-agent-toolchain'
        InstallDirectory = $installDirectory
        InstalledToolPath = $installedToolPath
        PortableInstalledToolPath = $portableInstalledToolPath
        PortableRootPath = $portableRootPath
        InstallMarkerPath = Join-Path -Path $installDirectory -ChildPath '.coding-agent-toolchain'
        PortableArchiveUrl = ConvertTo-FileUriString -Path $portableArchivePath
        ZipArchiveUrl = ConvertTo-FileUriString -Path $zipArchivePath
        UnsafeZipArchiveUrl = ConvertTo-FileUriString -Path $unsafeZipArchivePath
        MissingDirectBinaryUrl = ([uri]$missingDirectBinaryPath).AbsoluteUri
        DirectInstallerUrl = $directInstallerUrl
        DirectInstallerWarning = $directInstallerWarning
        Environment = @{
            PATH = ($windowsPathEntries -join [IO.Path]::PathSeparator)
            CAT_TEST_WINDOWS_FAKE_BIN = $fakeBinDirectory
            CAT_TEST_WINDOWS_PORTABLE_SOURCE = $portableSourcePath
            CAT_TEST_SKIP_USER_PATH_PERSISTENCE = '1'
        }
    }
}

function Invoke-WindowsDispatchFixture {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [Parameter(Mandatory = $true)]
        [object]$Fixture,

        [Parameter(Mandatory = $true)]
        [string]$ManifestContent
    )

    Set-Content -LiteralPath $Layout.ManifestPath -Value $ManifestContent -Encoding ASCII
    Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $Layout `
        -Arguments @('-v', '--check-path', '-c', $Layout.ManifestPath, '-p', $Fixture.PrefixPath) `
        -Environment $Fixture.Environment
}

function Test-InstallNoopFlow {
    foreach ($platform in @('windows', 'linux')) {
        $skippedResult = Invoke-ManifestCase -Platform $platform -ManifestContent (Get-UnavailableManifestContent)
        Test-ExitCode -Name "INSTALL-007 ${platform}: unavailable installer exits zero" -Result $skippedResult -ExpectedExitCode 0
        Test-ResultText -Name "INSTALL-007 ${platform}: unavailable installer skipped" -Result $skippedResult -ExpectedText 'Skipped'

        $dryRunResult = Invoke-ManifestCase -Platform $platform -ManifestContent (Get-DryRunManifestContent) -DryRun
        Test-ExitCode -Name "INSTALL-008 ${platform}: supported dry-run exits zero" -Result $dryRunResult -ExpectedExitCode 0
        Test-ResultText -Name "INSTALL-008 ${platform}: supported dry-run status" -Result $dryRunResult -ExpectedText 'DryRun'
        Test-ResultText -Name "INSTALL-008 ${platform}: supported dry-run install trace" -Result $dryRunResult -ExpectedText 'would install'

        $dryRunSkippedResult = Invoke-ManifestCase `
            -Platform $platform `
            -ManifestContent (Get-UnavailableManifestContent) `
            -DryRun
        Test-ExitCode `
            -Name "INSTALL-009 ${platform}: unavailable dry-run exits zero" `
            -Result $dryRunSkippedResult `
            -ExpectedExitCode 0
        Test-ResultText `
            -Name "INSTALL-009 ${platform}: unavailable dry-run skipped" `
            -Result $dryRunSkippedResult `
            -ExpectedText 'Skipped'

        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $platform -Path $layout.ManifestPath
        $verboseResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $layout `
            -Arguments @('-d', '-v', '-c', $configPath)
        Test-ExitCode -Name "INSTALL-010 ${platform}: verbose dry-run exits zero" -Result $verboseResult -ExpectedExitCode 0
        Test-ResultText -Name "INSTALL-010 ${platform}: verbose dry-run debug" -Result $verboseResult -ExpectedText '[DEBUG]'
        Test-ResultText `
            -Name "INSTALL-010 ${platform}: verbose dry-run installer kind" `
            -Result $verboseResult `
            -ExpectedText 'Installer kind'
    }
}

function Test-DispatchUnsupportedKind {
    foreach ($platform in @('windows', 'linux')) {
        $result = Invoke-ManifestCase -Platform $platform -ManifestContent (Get-UnsupportedKindManifestContent)
        Test-NonzeroExitCode -Name "DISPATCH-017 ${platform}: unsupported kind fails" -Result $result
        Test-ResultText `
            -Name "DISPATCH-017 ${platform}: unsupported kind diagnostic" `
            -Result $result `
            -ExpectedText 'Unsupported installer kind'
        Test-ResultText -Name "DISPATCH-017 ${platform}: unsupported kind failed status" -Result $result -ExpectedText 'Failed'
    }
}

function Test-PathNoopStatus {
    foreach ($platform in @('windows', 'linux')) {
        $dryRunResult = Invoke-DirectCliCase `
            -Platform $platform `
            -ManifestContent (Get-DryRunManifestContent) `
            -Arguments @('--dry-run', '--check-path')
        Test-ExitCode -Name "PATH-014 ${platform}: dry-run path exits zero" -Result $dryRunResult -ExpectedExitCode 0
        Test-ResultText -Name "PATH-014 ${platform}: dry-run path simulated" -Result $dryRunResult -ExpectedText 'Simulated'

        $skippedResult = Invoke-DirectCliCase `
            -Platform $platform `
            -ManifestContent (Get-UnavailableManifestContent) `
            -Arguments @('--check-path')
        Test-ExitCode -Name "PATH-014 ${platform}: skipped path exits zero" -Result $skippedResult -ExpectedExitCode 0
        Test-ResultText -Name "PATH-014 ${platform}: skipped path status" -Result $skippedResult -ExpectedText 'Skipped'

        $failedResult = Invoke-DirectCliCase `
            -Platform $platform `
            -ManifestContent (Get-UnsupportedKindManifestContent) `
            -Arguments @('--check-path')
        Test-NonzeroExitCode -Name "PATH-014 ${platform}: unresolved failed path exits nonzero" -Result $failedResult
        Test-ResultText `
            -Name "PATH-014 ${platform}: unresolved failed path status" `
            -Result $failedResult `
            -ExpectedText 'NotResolved'
    }
}

function Test-LinuxInteropCommandPath {
    if (Test-BashHasCygpath) {
        Register-CheckWarning 'PATH-009 linux skipped because Git Bash exposes Windows paths as native /c paths.'
        return
    }

    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-LinuxInteropPathManifestContent)
    $commandDirectory = Join-Path -Path $layout.Root -ChildPath 'interop-bin'
    New-Item -ItemType Directory -Path $commandDirectory | Out-Null
    $commandPath = Join-Path -Path $commandDirectory -ChildPath 'interop-tool'
    Write-LinuxExecutable -Path $commandPath -Line @(
        '#!/usr/bin/env bash',
        'printf ''interop-version\n'''
    )

    $commandDirectoryPath = ConvertTo-BashPath -Path $commandDirectory
    $configPath = Get-PlatformPathArgument -Platform 'linux' -Path $layout.ManifestPath
    $result = Invoke-IsolatedToolScript `
        -Platform 'linux' `
        -Layout $layout `
        -Arguments @('-v', '-c', $configPath) `
        -Environment @{ PATH = "${commandDirectoryPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" }

    Test-NonzeroExitCode -Name 'PATH-009 linux: Windows interop command path fails availability' -Result $result
    Test-ResultText `
        -Name 'PATH-009 linux: Windows interop command is ignored' `
        -Result $result `
        -ExpectedText 'Ignoring Windows interop command'
    Test-CheckCondition `
        -Name 'PATH-009 linux: interop command does not satisfy availability' `
        -Condition ($null -ne $result -and -not $result.Output.Contains('Present')) `
        -FailureDetail 'Interop command satisfied availability.'
    Test-ResultText -Name 'PATH-009 linux: ignored command reaches failed install branch' -Result $result -ExpectedText 'Failed'
}

function Initialize-LinuxDirectBinaryFixture {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [ValidateSet(
            'Success',
            'VersionFailure',
            'AppImage',
            'ArchiveZipRoot',
            'ArchiveZipPath',
            'ArchiveTarGz',
            'ArchiveTarXz',
            'ArchiveZipUnsafe',
            'ArchiveTarGzUnsafe',
            'ArchiveTarXzUnsafe',
            'ArchiveMissing',
            'PortableArchive',
            'GitHubRelease',
            'GitHubNoAsset',
            'SourceMake',
            'NoCompilerFallback'
        )]
        [string]$SourceMode = 'Success',

        [string]$TargetFileName = 'sample-tool',

        [switch]$CreateExistingFailureCommand
    )

    $runtimePath = Initialize-LinuxRuntimeDirectory
    $existingFailureValue = if ($CreateExistingFailureCommand) { '1' } else { '0' }
    $setupScript = Join-Path -Path $Layout.Root -ChildPath 'setup-linux-direct-binary.sh'
    $setupLines = @(
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'runtime_path="$1"',
        'source_mode="$2"',
        'existing_failure="$3"',
        'home_path="${runtime_path}/home"',
        'xdg_data_home="${home_path}/xdg-data"',
        'prefix_path="${home_path}/prefix"',
        'source_directory="${runtime_path}/source"',
        'fake_bin_directory="${runtime_path}/fake-bin"',
        'mkdir -p -- "${home_path}" "${xdg_data_home}" "${prefix_path}" "${source_directory}" "${fake_bin_directory}"',
        'source_file="${source_directory}/sample-tool"',
        'micromamba_path="${prefix_path}/coding-agent-toolchain/micromamba/bin/micromamba"',
        'mkdir -p -- "$(dirname -- "${micromamba_path}")"',
        'cat >"${micromamba_path}" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "micromamba 1.0.0"',
        '  exit 0',
        'fi',
        'action="${1:-}"',
        'if [[ "${action}" == "create" || "${action}" == "install" ]]; then',
        '  prefix=""',
        '  while (($# > 0)); do',
        '    case "$1" in',
        '    --prefix)',
        '      prefix="$2"',
        '      shift 2',
        '      ;;',
        '    *)',
        '      shift',
        '      ;;',
        '    esac',
        '  done',
        '  if [[ -z "${prefix}" ]]; then',
        '    exit 2',
        '  fi',
        '  mkdir -p -- "${prefix}/bin" "${prefix}/conda-meta"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''conda-version\n''" >"${prefix}/bin/sample-tool"',
        '  chmod 755 "${prefix}/bin/sample-tool"',
        '  exit 0',
        'fi',
        'exit 2',
        'EOF',
        'chmod 755 "${micromamba_path}"',
        'write_archive_payload() {',
        '  local payload_path="$1"',
        '  mkdir -p -- "$(dirname -- "${payload_path}")"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''archive-version\n''" >"${payload_path}"',
        '}',
        'create_zip_archive() {',
        '  local archive_path="$1"',
        '  local payload_path="$2"',
        '  local entry_name="$3"',
        '  local python_command',
        '  python_command="$(command -v python3 || command -v python)"',
        '  ARCHIVE_PATH="${archive_path}" PAYLOAD_PATH="${payload_path}" ENTRY_NAME="${entry_name}" "${python_command}" - <<''PY''',
        'import os',
        'import zipfile',
        'with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as archive:',
        '    archive.write(os.environ["PAYLOAD_PATH"], os.environ["ENTRY_NAME"])',
        'PY',
        '}',
        'create_tar_archive() {',
        '  local archive_path="$1"',
        '  local payload_path="$2"',
        '  local entry_name="$3"',
        '  local mode="$4"',
        '  local python_command',
        '  python_command="$(command -v python3 || command -v python)"',
        '  ARCHIVE_PATH="${archive_path}" PAYLOAD_PATH="${payload_path}" ENTRY_NAME="${entry_name}" TAR_MODE="${mode}" "${python_command}" - <<''PY''',
        'import os',
        'import tarfile',
        'with tarfile.open(os.environ["ARCHIVE_PATH"], os.environ["TAR_MODE"]) as archive:',
        '    archive.add(os.environ["PAYLOAD_PATH"], arcname=os.environ["ENTRY_NAME"])',
        'PY',
        '}',
        'create_archive_source() {',
        '  local archive_path="$1"',
        '  local selected_source_mode="$2"',
        '  local payload_path="${runtime_path}/archive-work/payload/sample-tool"',
        '  local entry_name="sample-tool"',
        '  if [[ "${selected_source_mode}" == "ArchiveZipPath" ]]; then',
        '    entry_name="nested/sample-tool"',
        '  elif [[ "${selected_source_mode}" == "ArchiveMissing" ]]; then',
        '    entry_name="nested/other-tool"',
        '  elif [[ "${selected_source_mode}" == *Unsafe ]]; then',
        '    entry_name="../sample-tool"',
        '  fi',
        '  write_archive_payload "${payload_path}"',
        '  case "${selected_source_mode}" in',
        '  ArchiveZipRoot|ArchiveZipPath|ArchiveMissing|ArchiveZipUnsafe) create_zip_archive "${archive_path}" "${payload_path}" "${entry_name}" ;;',
        '  ArchiveTarGz|ArchiveTarGzUnsafe) create_tar_archive "${archive_path}" "${payload_path}" "${entry_name}" "w:gz" ;;',
        '  ArchiveTarXz|ArchiveTarXzUnsafe) create_tar_archive "${archive_path}" "${payload_path}" "${entry_name}" "w:xz" ;;',
        '  esac',
        '}',
        'create_portable_archive_source() {',
        '  local archive_path="$1"',
        '  local source_root="${runtime_path}/portable-work/root"',
        '  local python_command',
        '  mkdir -p -- "${source_root}/bin"',
        '  write_archive_payload "${source_root}/bin/sample-tool"',
        '  chmod 755 "${source_root}/bin/sample-tool"',
        '  printf "%s\n" "portable root" >"${source_root}/portable-root.txt"',
        '  python_command="$(command -v python3 || command -v python)"',
        '  ARCHIVE_PATH="${archive_path}" SOURCE_ROOT="${source_root}" "${python_command}" - <<''PY''',
        'import os',
        'import tarfile',
        'archive_path = os.environ["ARCHIVE_PATH"]',
        'source_root = os.environ["SOURCE_ROOT"]',
        'with tarfile.open(archive_path, "w:gz") as archive:',
        '    for name in ("bin/sample-tool", "portable-root.txt"):',
        '        archive.add(os.path.join(source_root, name), arcname=name)',
        'PY',
        '}',
        'create_source_make_source() {',
        '  local archive_path="$1"',
        '  local source_root="${runtime_path}/source-work/sample-source"',
        '  mkdir -p -- "${source_root}"',
        '  cat >"${source_root}/configure" <<''CONFIGURE''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'prefix=""',
        'for argument in "$@"; do',
        '  case "${argument}" in',
        '  --prefix=*) prefix="${argument#--prefix=}" ;;',
        '  esac',
        'done',
        'if [[ -z "${prefix}" ]]; then',
        '  exit 2',
        'fi',
        'printf "%s\n" "${prefix}" >.prefix',
        'CONFIGURE',
        '  chmod 755 "${source_root}/configure"',
        '  create_tar_archive "${archive_path}" "${source_root}" "sample-source" "w:xz"',
        '}',
        'if [[ "${source_mode}" == "PortableArchive" ]]; then',
        '  create_portable_archive_source "${source_file}"',
        'elif [[ "${source_mode}" == "VersionFailure" ]]; then',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''bad-version\n'' >&2" "exit 7" >"${source_file}"',
        'elif [[ "${source_mode}" == "AppImage" ]]; then',
        '  cat >"${source_file}" <<''APPIMAGE''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--appimage-extract" ]]; then',
        '  mkdir -p squashfs-root',
        '  cat >squashfs-root/AppRun <<''APP_RUN''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "appimage-version"',
        'else',
        '  printf "%s\n" "appimage-run"',
        'fi',
        'APP_RUN',
        '  chmod 755 squashfs-root/AppRun',
        '  exit 0',
        'fi',
        'printf "%s\n" "unexpected appimage invocation" >&2',
        'exit 2',
        'APPIMAGE',
        'elif [[ "${source_mode}" == Archive* ]]; then',
        '  create_archive_source "${source_file}" "${source_mode}"',
        'elif [[ "${source_mode}" == "SourceMake" ]]; then',
        '  create_source_make_source "${source_file}"',
        'else',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''direct-binary-version\n''" >"${source_file}"',
        'fi',
        'chmod 755 "${source_file}"',
        'cat >"${fake_bin_directory}/curl" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'url=""',
        'output_path=""',
        'while (($# > 0)); do',
        '  case "$1" in',
        '  -o)',
        '    output_path="$2"',
        '    shift 2',
        '    ;;',
        '  -*)',
        '    shift',
        '    ;;',
        '  *)',
        '    url="$1"',
        '    shift',
        '    ;;',
        '  esac',
        'done',
        'if [[ -z "${url}" || -z "${output_path}" ]]; then',
        '  exit 2',
        'fi',
        'case "${url}" in',
        'file://*) cp -- "${url#file://}" "${output_path}" ;;',
        'https://api.github.com/repos/example/sample/releases/latest)',
        '  if [[ "${CAT_TEST_SOURCE_MODE:-}" == "GitHubNoAsset" ]]; then',
        '    printf "%s\n" "{" "  \"assets\": [" "    {" "      \"name\": \"other-tool-linux\"," "      \"browser_download_url\": \"https://example.invalid/sample-tool\"" "    }" "  ]" "}" >"${output_path}"',
        '  else',
        '    printf "%s\n" "{" "  \"assets\": [" "    {" "      \"name\": \"sample-tool-linux\"," "      \"browser_download_url\": \"https://example.invalid/sample-tool\"" "    }" "  ]" "}" >"${output_path}"',
        '  fi',
        '  ;;',
        'https://example.invalid/sample-tool) cp -- "${CAT_TEST_SOURCE_FILE:?}" "${output_path}" ;;',
        '*) exit 23 ;;',
        'esac',
        'EOF',
        'chmod 755 "${fake_bin_directory}/curl"',
        'cat >"${fake_bin_directory}/node" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "v22.0.0"',
        '  exit 0',
        'fi',
        'exit 0',
        'EOF',
        'chmod 755 "${fake_bin_directory}/node"',
        'cat >"${fake_bin_directory}/npm" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "10.0.0"',
        '  exit 0',
        'fi',
        'prefix=""',
        'while (($# > 0)); do',
        '  case "$1" in',
        '  --prefix)',
        '    prefix="$2"',
        '    shift 2',
        '    ;;',
        '  *)',
        '    shift',
        '    ;;',
        '  esac',
        'done',
        'if [[ -z "${prefix}" ]]; then',
        '  exit 2',
        'fi',
        'mkdir -p -- "${prefix}/bin"',
        'printf "%s\n" "#!/usr/bin/env bash" "printf ''npm-version\n''" >"${prefix}/bin/sample-tool"',
        'chmod 755 "${prefix}/bin/sample-tool"',
        'EOF',
        'chmod 755 "${fake_bin_directory}/npm"',
        'cat >"${fake_bin_directory}/uv" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "uv 0.1.0"',
        '  exit 0',
        'fi',
        'if [[ "${1:-}" == "tool" && "${2:-}" == "install" ]]; then',
        '  : "${UV_TOOL_BIN_DIR:?}"',
        '  mkdir -p -- "${UV_TOOL_BIN_DIR}"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''uv-version\n''" >"${UV_TOOL_BIN_DIR}/sample-tool"',
        '  chmod 755 "${UV_TOOL_BIN_DIR}/sample-tool"',
        '  exit 0',
        'fi',
        'exit 2',
        'EOF',
        'chmod 755 "${fake_bin_directory}/uv"',
        'cat >"${fake_bin_directory}/brew" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "install" ]]; then',
        '  : "${CAT_TEST_FAKE_BIN:?}"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''brew-version\n''" >"${CAT_TEST_FAKE_BIN}/sample-tool"',
        '  chmod 755 "${CAT_TEST_FAKE_BIN}/sample-tool"',
        '  exit 0',
        'fi',
        'exit 2',
        'EOF',
        'chmod 755 "${fake_bin_directory}/brew"',
        'cat >"${fake_bin_directory}/pwsh" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'command_text="$*"',
        'if [[ "${command_text}" == *Install-Module* ]]; then',
        '  : "${CAT_TEST_PWSH_MODULE_DIR:?}"',
        '  : "${CAT_TEST_PWSH_STATE:?}"',
        '  mkdir -p -- "${CAT_TEST_PWSH_MODULE_DIR}" "$(dirname -- "${CAT_TEST_PWSH_STATE}")"',
        '  printf "%s\n" "installed" >"${CAT_TEST_PWSH_STATE}"',
        '  exit 0',
        'fi',
        'if [[ "${command_text}" == *PSVersionTable.PSVersion* ]]; then',
        '  printf "%s\n" "7.4.0"',
        '  exit 0',
        'fi',
        'if [[ ! -f "${CAT_TEST_PWSH_STATE:?}" ]]; then',
        '  exit 1',
        'fi',
        'if [[ "${command_text}" == *Version.ToString* ]]; then',
        '  printf "%s\n" "psgallery-version"',
        '  exit 0',
        'fi',
        'if [[ "${command_text}" == *ModuleBase* ]]; then',
        '  printf "%s\n" "${CAT_TEST_PWSH_MODULE_DIR:?}"',
        '  exit 0',
        'fi',
        'exit 0',
        'EOF',
        'chmod 755 "${fake_bin_directory}/pwsh"',
        'cat >"${fake_bin_directory}/python3" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "--version" ]]; then',
        '  printf "%s\n" "Python 3.12.0"',
        '  exit 0',
        'fi',
        'if [[ "${1:-}" == "-m" && "${2:-}" == "site" && "${3:-}" == "--user-base" ]]; then',
        '  printf "%s\n" "${HOME}/.local"',
        '  exit 0',
        'fi',
        'if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then',
        '  venv_path="$3"',
        '  mkdir -p -- "${venv_path}/bin"',
        '  cat >"${venv_path}/bin/python" <<''VENV_PYTHON''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "--version" ]]; then',
        '  printf "%s\n" "pip 24.0"',
        '  exit 0',
        'fi',
        'if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]]; then',
        '  bin_dir="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''python-version\n''" >"${bin_dir}/sample-tool"',
        '  chmod 755 "${bin_dir}/sample-tool"',
        '  exit 0',
        'fi',
        'exit 2',
        'VENV_PYTHON',
        '  chmod 755 "${venv_path}/bin/python"',
        '  exit 0',
        'fi',
        'convert_python_path_env() {',
        '  local convert_paths="${1:-0}"',
        '  local variable_name',
        '  local variable_value',
        '  for variable_name in CAT_ARCHIVE_KIND CAT_ARCHIVE_PATH CAT_TARGET_DIR ARCHIVE_PATH PAYLOAD_PATH ENTRY_NAME TAR_MODE SOURCE_ROOT; do',
        '    variable_value="${!variable_name:-}"',
        '    if [[ "${convert_paths}" == "1" && "${variable_value}" == /* && "${variable_value}" != //* ]] && command -v cygpath >/dev/null 2>&1; then',
        '      variable_value="$(cygpath -w -- "${variable_value}")"',
        '    fi',
        '    export "${variable_name}=${variable_value}"',
        '  done',
        '}',
        'host_python="${CAT_TEST_HOST_PYTHON:-}"',
        'if [[ -n "${host_python}" && -x "${host_python}" ]]; then',
        '  if [[ "${host_python}" != /usr/bin/* && "${host_python}" != /usr/local/bin/* ]]; then',
        '    convert_python_path_env 1',
        '  else',
        '    convert_python_path_env 0',
        '  fi',
        '  exec "${host_python}" "$@"',
        'fi',
        'fake_bin="${CAT_TEST_FAKE_BIN:-}"',
        'fake_bin="${fake_bin%/}"',
        'for command_name in python3 python3.exe python python.exe; do',
        '  while IFS= read -r python_candidate; do',
        '    python_dir="$(cd "$(dirname -- "${python_candidate}")" && pwd)"',
        '    if [[ "${python_dir%/}" == "${fake_bin}" ]]; then',
        '      continue',
        '    fi',
        '    if [[ -x "${python_candidate}" ]]; then',
        '      if [[ "${python_candidate}" != /usr/bin/* && "${python_candidate}" != /usr/local/bin/* ]]; then',
        '        convert_python_path_env 1',
        '      else',
        '        convert_python_path_env 0',
        '      fi',
        '      exec "${python_candidate}" "$@"',
        '    fi',
        '  done < <(type -P -a "${command_name}" 2>/dev/null || true)',
        'done',
        'for python_candidate in /usr/bin/python3 /usr/local/bin/python3 /usr/bin/python /usr/local/bin/python; do',
        '  if [[ -x "${python_candidate}" ]]; then',
        '    convert_python_path_env 0',
        '    exec "${python_candidate}" "$@"',
        '  fi',
        'done',
        'exit 2',
        'EOF',
        'chmod 755 "${fake_bin_directory}/python3"',
        'cp -- "${fake_bin_directory}/python3" "${fake_bin_directory}/python"',
        'if [[ "${source_mode}" != "NoCompilerFallback" ]]; then',
        'cat >"${fake_bin_directory}/cc" <<''EOF''',
        '#!/usr/bin/env bash',
        'exit 0',
        'EOF',
        'chmod 755 "${fake_bin_directory}/cc"',
        'cp -- "${fake_bin_directory}/cc" "${fake_bin_directory}/gcc"',
        'cp -- "${fake_bin_directory}/cc" "${fake_bin_directory}/clang"',
        'fi',
        'cat >"${fake_bin_directory}/make" <<''EOF''',
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'if [[ " $* " == *" install "* ]]; then',
        '  prefix="$(cat .prefix)"',
        '  mkdir -p -- "${prefix}/bin"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''source-version\n''" >"${prefix}/bin/sample-tool"',
        '  chmod 755 "${prefix}/bin/sample-tool"',
        'fi',
        'exit 0',
        'EOF',
        'chmod 755 "${fake_bin_directory}/make"',
        'if [[ "${existing_failure}" == "1" ]]; then',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''existing-version-failed\n'' >&2" "exit 9" >"${fake_bin_directory}/sample-tool"',
        '  chmod 755 "${fake_bin_directory}/sample-tool"',
        'fi'
    )
    [IO.File]::WriteAllText($setupScript, ($setupLines -join "`n") + "`n", [Text.Encoding]::ASCII)

    try {
        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            throw 'bash is required for Linux direct-binary fixtures.'
        }

        $setupResult = Invoke-CommandCapture `
            -Command $bashCommand.Source `
            -Arguments @((ConvertTo-BashPath -Path $setupScript), $runtimePath, $SourceMode, $existingFailureValue)
        if ($setupResult.ExitCode -ne 0) {
            throw "Could not initialize Linux direct-binary fixture. Output: $($setupResult.Output)"
        }

        $homePath = "$runtimePath/home"
        $prefixPath = "$homePath/prefix"
        $toolDirectoryPath = "$prefixPath/coding-agent-toolchain/sample-tool"
        $machineName = Get-BashMachineName
        $defaultToolDirectoryPath = "$homePath/xdg-data/coding-agent-toolchain/tools/" +
            "linux-$machineName/sample-tool"
        $fakeBinDirectoryPath = "$runtimePath/fake-bin"
        $hostPythonPath = '/__cat_no_host_python__'
        $hostPythonCandidates = @()
        if (-not [string]::IsNullOrWhiteSpace($env:Python_ROOT_DIR)) {
            $hostPythonCandidates += Join-Path -Path $env:Python_ROOT_DIR -ChildPath 'python.exe'
        }
        foreach ($commandName in @('python3', 'python')) {
            $hostPythonCommand = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $hostPythonCommand) {
                $hostPythonCandidates += $hostPythonCommand.Source
            }
        }
        & bash -lc 'command -v cygpath >/dev/null 2>&1'
        if ($LASTEXITCODE -ne 0) {
            $hostPythonCandidates = @()
        }
        foreach ($hostPythonCandidate in $hostPythonCandidates) {
            if ($hostPythonCandidate -match '[\\/]Microsoft[\\/]WindowsApps[\\/]python3?\.exe$') {
                continue
            }
            if (-not (Test-Path -LiteralPath $hostPythonCandidate -PathType Leaf)) {
                continue
            }
            if ($hostPythonCandidate -match '^[A-Za-z]:[\\/]') {
                $hostPythonPath = ConvertTo-BashHostPath -Path $hostPythonCandidate
            } else {
                $hostPythonPath = $hostPythonCandidate
            }
            break
        }

        return [pscustomobject]@{
            RuntimePath = $runtimePath
            SourceUrl = "file://$runtimePath/source/sample-tool"
            MissingSourceUrl = "file://$runtimePath/source/missing-tool"
            PrefixPath = $prefixPath
            ToolPath = "$toolDirectoryPath/bin/$TargetFileName"
            PortableRootPath = "$toolDirectoryPath/portable-root.txt"
            MarkerPath = "$toolDirectoryPath/.coding-agent-toolchain"
            DefaultToolPath = "$defaultToolDirectoryPath/bin/$TargetFileName"
            DefaultMarkerPath = "$defaultToolDirectoryPath/.coding-agent-toolchain"
            CommandPath = "$homePath/.local/bin/sample-tool"
            FakeBinToolPath = "$fakeBinDirectoryPath/sample-tool"
            FakeBinMarkerPath = "$fakeBinDirectoryPath/.coding-agent-toolchain"
            PowerShellModuleDirectory = "$runtimePath/pwsh-module/sample-tool"
            PowerShellMarkerPath = "$runtimePath/pwsh-module/sample-tool/.coding-agent-toolchain"
            Environment = @{
                HOME = $homePath
                XDG_DATA_HOME = "$homePath/xdg-data"
                PATH = "${fakeBinDirectoryPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                CAT_TEST_SOURCE_FILE = "$runtimePath/source/sample-tool"
                CAT_TEST_SOURCE_MODE = $SourceMode
                CAT_TEST_FAKE_BIN = $fakeBinDirectoryPath
                CAT_TEST_HOST_PYTHON = $hostPythonPath
                CAT_TEST_PWSH_STATE = "$runtimePath/pwsh-state/installed"
                CAT_TEST_PWSH_MODULE_DIR = "$runtimePath/pwsh-module/sample-tool"
            }
        }
    } catch {
        Clear-LinuxRuntimeDirectory -Path $runtimePath
        throw
    }
}

function Invoke-LinuxDirectBinaryFixture {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [Parameter(Mandatory = $true)]
        [object]$Fixture,

        [Parameter(Mandatory = $true)]
        [string]$ManifestContent,

        [switch]$UseDefaultRoot
    )

    $configPath = Get-PlatformPathArgument -Platform 'linux' -Path $Layout.ManifestPath
    Set-Content -LiteralPath $Layout.ManifestPath -Value $ManifestContent -Encoding ASCII
    $arguments = @('-v', '--check-path', '-c', $configPath)
    if (-not $UseDefaultRoot) {
        $arguments += @('-p', $Fixture.PrefixPath)
    }

    Invoke-IsolatedToolScript `
        -Platform 'linux' `
        -Layout $Layout `
        -Arguments $arguments `
        -Environment $Fixture.Environment
}

function Test-LinuxDirectBinaryInstallFlow {
    $successLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $successFixture = $null
    try {
        $successFixture = Initialize-LinuxDirectBinaryFixture -Layout $successLayout
        $successResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $successLayout `
            -Fixture $successFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent -Url $successFixture.SourceUrl)
        Test-ExitCode -Name 'DISPATCH-009 linux: direct_binary local file exits zero' -Result $successResult -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-009 linux: direct_binary dispatches downloader' `
            -Result $successResult `
            -ExpectedText 'direct binary download'
        Test-ResultText -Name 'INSTALL-003 linux: absent direct binary is installed' -Result $successResult -ExpectedText 'Installed'
        Test-ResultText -Name 'INSTALL-003 linux: installed direct binary reports version' -Result $successResult -ExpectedText 'direct-binary-version'
        Test-CheckCondition `
            -Name 'INSTALL-003 linux: installed binary exists' `
            -Condition (Test-LinuxPathPresence -Path $successFixture.ToolPath) `
            -FailureDetail 'Installed direct binary was not created.'
        Test-CheckCondition `
            -Name 'INSTALL-003 linux: install marker exists' `
            -Condition (Test-LinuxPathPresence -Path $successFixture.MarkerPath) `
            -FailureDetail 'Installation marker was not written.'
    } finally {
        if ($null -ne $successFixture) {
            Clear-LinuxRuntimeDirectory -Path $successFixture.RuntimePath
        }
    }

    $hashSuccessLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $hashSuccessFixture = $null
    try {
        $hashSuccessFixture = Initialize-LinuxDirectBinaryFixture -Layout $hashSuccessLayout
        $sourceHash = Get-LinuxFileSha256 -Path "$($hashSuccessFixture.RuntimePath)/source/sample-tool"
        $hashSuccessResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $hashSuccessLayout `
            -Fixture $hashSuccessFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent `
                -Url $hashSuccessFixture.SourceUrl `
                -SchemaVersion '2' `
                -Sha256 $sourceHash)
        Test-ExitCode -Name 'SUPPLY-002 linux: matching direct_binary sha256 exits zero' -Result $hashSuccessResult -ExpectedExitCode 0
        Test-ResultText -Name 'SUPPLY-002 linux: matching direct_binary sha256 is verified' -Result $hashSuccessResult -ExpectedText 'Verified SHA256'
        Test-CheckCondition `
            -Name 'SUPPLY-002 linux: hash-verified direct binary marker exists' `
            -Condition (Test-LinuxPathPresence -Path $hashSuccessFixture.MarkerPath) `
            -FailureDetail 'Installation marker was not written after a verified hash.'
    } finally {
        if ($null -ne $hashSuccessFixture) {
            Clear-LinuxRuntimeDirectory -Path $hashSuccessFixture.RuntimePath
        }
    }

    $hashFailureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $hashFailureFixture = $null
    try {
        $hashFailureFixture = Initialize-LinuxDirectBinaryFixture -Layout $hashFailureLayout
        $badHash = '0' * 64
        $hashFailureResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $hashFailureLayout `
            -Fixture $hashFailureFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent `
                -Url $hashFailureFixture.SourceUrl `
                -SchemaVersion '2' `
                -Sha256 $badHash)
        Test-NonzeroExitCode -Name 'SUPPLY-002 linux: mismatched direct_binary sha256 exits nonzero' -Result $hashFailureResult
        Test-ResultText -Name 'SUPPLY-002 linux: mismatched direct_binary sha256 diagnostic' -Result $hashFailureResult -ExpectedText 'SHA256 mismatch'
        Test-CheckCondition `
            -Name 'SUPPLY-002 linux: hash mismatch writes no marker' `
            -Condition (-not (Test-LinuxPathPresence -Path $hashFailureFixture.MarkerPath)) `
            -FailureDetail 'Marker was written after a checksum mismatch.'
    } finally {
        if ($null -ne $hashFailureFixture) {
            Clear-LinuxRuntimeDirectory -Path $hashFailureFixture.RuntimePath
        }
    }

    $existingFailureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $existingFailureFixture = $null
    try {
        $existingFailureFixture = Initialize-LinuxDirectBinaryFixture `
            -Layout $existingFailureLayout `
            -CreateExistingFailureCommand
        $existingFailureResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $existingFailureLayout `
            -Fixture $existingFailureFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent -Url $existingFailureFixture.SourceUrl)
        Test-ExitCode `
            -Name 'INSTALL-002 linux: existing bad version triggers reinstall' `
            -Result $existingFailureResult `
            -ExpectedExitCode 0
        Test-ResultText `
            -Name 'INSTALL-002 linux: existing version failure is logged' `
            -Result $existingFailureResult `
            -ExpectedText 'Existing version check failed'
        Test-ResultText `
            -Name 'INSTALL-002 linux: reinstall finishes installed' `
            -Result $existingFailureResult `
            -ExpectedText 'Installed'
    } finally {
        if ($null -ne $existingFailureFixture) {
            Clear-LinuxRuntimeDirectory -Path $existingFailureFixture.RuntimePath
        }
    }

    $downloadFailureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $downloadFailureFixture = $null
    try {
        $downloadFailureFixture = Initialize-LinuxDirectBinaryFixture -Layout $downloadFailureLayout
        $downloadFailureResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $downloadFailureLayout `
            -Fixture $downloadFailureFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent -Url $downloadFailureFixture.MissingSourceUrl)
        Test-NonzeroExitCode -Name 'INSTALL-004 linux: failed direct_binary download exits nonzero' -Result $downloadFailureResult
        Test-ResultText -Name 'INSTALL-004 linux: failed installer status' -Result $downloadFailureResult -ExpectedText 'Failed'
        Test-ResultText -Name 'ARCHIVE-009 linux: download failure reports install failure' -Result $downloadFailureResult -ExpectedText 'Installation failed'
        Test-CheckCondition `
            -Name 'ARCHIVE-009 linux: failed download writes no marker' `
            -Condition (-not (Test-LinuxPathPresence -Path $downloadFailureFixture.MarkerPath)) `
            -FailureDetail 'Marker was written after a failed download.'
    } finally {
        if ($null -ne $downloadFailureFixture) {
            Clear-LinuxRuntimeDirectory -Path $downloadFailureFixture.RuntimePath
        }
    }

    $missingCommandLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $missingCommandFixture = $null
    try {
        $missingCommandFixture = Initialize-LinuxDirectBinaryFixture -Layout $missingCommandLayout -TargetFileName 'other-tool'
        $missingCommandResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $missingCommandLayout `
            -Fixture $missingCommandFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent -Url $missingCommandFixture.SourceUrl -FileName 'other-tool')
        Test-NonzeroExitCode -Name 'INSTALL-005 linux: installed wrong command exits nonzero' -Result $missingCommandResult
        Test-ResultText -Name 'INSTALL-005 linux: installed wrong command is missing' -Result $missingCommandResult -ExpectedText 'Missing'
        Test-CheckCondition `
            -Name 'INSTALL-005 linux: downloaded file exists under wrong name' `
            -Condition (Test-LinuxPathPresence -Path $missingCommandFixture.ToolPath) `
            -FailureDetail 'Wrong-name direct binary was not installed.'
        Test-CheckCondition `
            -Name 'INSTALL-005 linux: missing command writes no marker' `
            -Condition (-not (Test-LinuxPathPresence -Path $missingCommandFixture.MarkerPath)) `
            -FailureDetail 'Marker was written when expected command stayed unavailable.'
    } finally {
        if ($null -ne $missingCommandFixture) {
            Clear-LinuxRuntimeDirectory -Path $missingCommandFixture.RuntimePath
        }
    }

    $versionFailureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $versionFailureFixture = $null
    try {
        $versionFailureFixture = Initialize-LinuxDirectBinaryFixture -Layout $versionFailureLayout -SourceMode 'VersionFailure'
        $versionFailureResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $versionFailureLayout `
            -Fixture $versionFailureFixture `
            -ManifestContent (Get-LinuxDirectBinaryManifestContent -Url $versionFailureFixture.SourceUrl)
        Test-NonzeroExitCode -Name 'INSTALL-006 linux: installed bad version exits nonzero' -Result $versionFailureResult
        Test-ResultText -Name 'INSTALL-006 linux: installed bad version status' -Result $versionFailureResult -ExpectedText 'Failed'
        Test-ResultText -Name 'INSTALL-006 linux: version failure detail' -Result $versionFailureResult -ExpectedText 'Version command failed'
        Test-CheckCondition `
            -Name 'INSTALL-006 linux: version-failing binary exists' `
            -Condition (Test-LinuxPathPresence -Path $versionFailureFixture.ToolPath) `
            -FailureDetail 'Version-failing direct binary was not installed.'
        Test-CheckCondition `
            -Name 'INSTALL-006 linux: failed version writes no marker' `
            -Condition (-not (Test-LinuxPathPresence -Path $versionFailureFixture.MarkerPath)) `
            -FailureDetail 'Marker was written after version verification failed.'
    } finally {
        if ($null -ne $versionFailureFixture) {
            Clear-LinuxRuntimeDirectory -Path $versionFailureFixture.RuntimePath
        }
    }
}

function Test-LinuxArchiveInstallFlow {
    $archiveCases = @(
        [pscustomobject]@{
            Name = 'ARCHIVE-001 linux: zip root archive'
            SourceMode = 'ArchiveZipRoot'
            ArchiveKind = 'zip'
            ArchivePath = ''
            ExpectedText = 'Installing extracted binary'
            ShouldSucceed = $true
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-002 linux: zip archive_path'
            SourceMode = 'ArchiveZipPath'
            ArchiveKind = 'zip'
            ArchivePath = 'nested/sample-tool'
            ExpectedText = 'nested/sample-tool'
            ShouldSucceed = $true
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-003 linux: tar.gz archive'
            SourceMode = 'ArchiveTarGz'
            ArchiveKind = 'tar_gz'
            ArchivePath = ''
            ExpectedText = 'Installing extracted binary'
            ShouldSucceed = $true
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-004 linux: tar.xz archive'
            SourceMode = 'ArchiveTarXz'
            ArchiveKind = 'tar_xz'
            ArchivePath = ''
            ExpectedText = 'Installing extracted binary'
            ShouldSucceed = $true
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-010 linux: unsafe zip archive'
            SourceMode = 'ArchiveZipUnsafe'
            ArchiveKind = 'zip'
            ArchivePath = ''
            ExpectedText = 'Unsafe archive member'
            ShouldSucceed = $false
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-011 linux: unsafe tar.gz archive'
            SourceMode = 'ArchiveTarGzUnsafe'
            ArchiveKind = 'tar_gz'
            ArchivePath = ''
            ExpectedText = 'Unsafe archive member'
            ShouldSucceed = $false
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-012 linux: unsafe tar.xz archive'
            SourceMode = 'ArchiveTarXzUnsafe'
            ArchiveKind = 'tar_xz'
            ArchivePath = ''
            ExpectedText = 'Unsafe archive member'
            ShouldSucceed = $false
        }
        [pscustomobject]@{
            Name = 'ARCHIVE-007 linux: missing archive executable'
            SourceMode = 'ArchiveMissing'
            ArchiveKind = 'zip'
            ArchivePath = ''
            ExpectedText = "Archive does not contain 'sample-tool'"
            ShouldSucceed = $false
        }
    )

    foreach ($archiveCase in $archiveCases) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
        $fixture = $null
        try {
            $fixture = Initialize-LinuxDirectBinaryFixture -Layout $layout -SourceMode $archiveCase.SourceMode
            $manifestArguments = @{
                Url = $fixture.SourceUrl
                ArchiveKind = $archiveCase.ArchiveKind
            }
            if (-not [string]::IsNullOrWhiteSpace($archiveCase.ArchivePath)) {
                $manifestArguments.ArchivePath = $archiveCase.ArchivePath
            }

            $result = Invoke-LinuxDirectBinaryFixture `
                -Layout $layout `
                -Fixture $fixture `
                -ManifestContent (Get-LinuxDirectBinaryManifestContent @manifestArguments)

            if ($archiveCase.ShouldSucceed) {
                Test-ExitCode -Name "$($archiveCase.Name) exits zero" -Result $result -ExpectedExitCode 0
                Test-ResultText `
                    -Name "$($archiveCase.Name) uses configured archive" `
                    -Result $result `
                    -ExpectedText $archiveCase.ExpectedText
                Test-ResultText -Name "$($archiveCase.Name) reports version" -Result $result -ExpectedText 'archive-version'
                Test-CheckCondition `
                    -Name "$($archiveCase.Name) installed binary exists" `
                    -Condition (Test-LinuxPathPresence -Path $fixture.ToolPath) `
                    -FailureDetail 'Archived binary was not installed.'
                Test-CheckCondition `
                    -Name "$($archiveCase.Name) marker exists" `
                    -Condition (Test-LinuxPathPresence -Path $fixture.MarkerPath) `
                    -FailureDetail 'Archive installation marker was not written.'
            } else {
                Test-NonzeroExitCode -Name "$($archiveCase.Name) exits nonzero" -Result $result
                Test-ResultText -Name "$($archiveCase.Name) reports failed status" -Result $result -ExpectedText 'Failed'
                Test-ResultText `
                    -Name "$($archiveCase.Name) reports missing executable" `
                    -Result $result `
                    -ExpectedText $archiveCase.ExpectedText
                Test-CheckCondition `
                    -Name "$($archiveCase.Name) writes no marker" `
                    -Condition (-not (Test-LinuxPathPresence -Path $fixture.MarkerPath)) `
                    -FailureDetail 'Marker was written after archive extraction failed.'
            }
        } finally {
            if ($null -ne $fixture) {
                Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
            }
        }
    }
}

function Test-LinuxPortableArchiveInstallFlow {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxDirectBinaryFixture -Layout $layout -SourceMode 'PortableArchive'
        $result = Invoke-LinuxDirectBinaryFixture `
            -Layout $layout `
            -Fixture $fixture `
            -ManifestContent (Get-LinuxPortableArchiveManifestContent -Url $fixture.SourceUrl)

        Test-ExitCode -Name 'DISPATCH-011 linux: portable_archive exits zero' -Result $result -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-011 linux: portable_archive branch is used' `
            -Result $result `
            -ExpectedText 'portable archive'
        Test-ResultText `
            -Name 'DISPATCH-011 linux: portable_archive reports version' `
            -Result $result `
            -ExpectedText 'archive-version'
        Test-CheckCondition `
            -Name 'DISPATCH-011 linux: portable_archive command exists' `
            -Condition (Test-LinuxPathPresence -Path $fixture.ToolPath) `
            -FailureDetail 'Portable archive command was not installed.'
        Test-CheckCondition `
            -Name 'DISPATCH-011 linux: portable_archive root content exists' `
            -Condition (Test-LinuxPathPresence -Path $fixture.PortableRootPath) `
            -FailureDetail 'Portable archive root content was not copied.'
        Test-CheckCondition `
            -Name 'DISPATCH-011 linux: portable_archive marker exists' `
            -Condition (Test-LinuxPathPresence -Path $fixture.MarkerPath) `
            -FailureDetail 'Portable archive marker was not written.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-LinuxGitHubReleaseAssetInstallFlow {
    $successLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $successFixture = $null
    try {
        $successFixture = Initialize-LinuxDirectBinaryFixture -Layout $successLayout -SourceMode 'GitHubRelease'
        $successResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $successLayout `
            -Fixture $successFixture `
            -ManifestContent (Get-LinuxGitHubReleaseManifestContent)

        Test-ExitCode -Name 'DISPATCH-010 linux: github_release_asset exits zero' -Result $successResult -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-010 linux: github_release_asset fetches release metadata' `
            -Result $successResult `
            -ExpectedText 'Fetching latest GitHub release metadata'
        Test-ResultText `
            -Name 'DISPATCH-010 linux: github_release_asset matches asset URL' `
            -Result $successResult `
            -ExpectedText 'Matched GitHub release asset URL'
        Test-ResultText `
            -Name 'DISPATCH-010 linux: github_release_asset reports version' `
            -Result $successResult `
            -ExpectedText 'direct-binary-version'
        Test-CheckCondition `
            -Name 'DISPATCH-010 linux: github_release_asset installed binary exists' `
            -Condition (Test-LinuxPathPresence -Path $successFixture.ToolPath) `
            -FailureDetail 'GitHub release asset binary was not installed.'
        Test-CheckCondition `
            -Name 'DISPATCH-010 linux: github_release_asset marker exists' `
            -Condition (Test-LinuxPathPresence -Path $successFixture.MarkerPath) `
            -FailureDetail 'GitHub release asset marker was not written.'
    } finally {
        if ($null -ne $successFixture) {
            Clear-LinuxRuntimeDirectory -Path $successFixture.RuntimePath
        }
    }

    $missingAssetLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $missingAssetFixture = $null
    try {
        $missingAssetFixture = Initialize-LinuxDirectBinaryFixture -Layout $missingAssetLayout -SourceMode 'GitHubNoAsset'
        $missingAssetResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $missingAssetLayout `
            -Fixture $missingAssetFixture `
            -ManifestContent (Get-LinuxGitHubReleaseManifestContent)

        Test-NonzeroExitCode -Name 'ARCHIVE-008 linux: missing GitHub release asset exits nonzero' -Result $missingAssetResult
        Test-ResultText `
            -Name 'ARCHIVE-008 linux: missing GitHub release asset diagnostic' `
            -Result $missingAssetResult `
            -ExpectedText 'has no asset matching'
        Test-ResultText `
            -Name 'ARCHIVE-008 linux: missing GitHub release asset failed status' `
            -Result $missingAssetResult `
            -ExpectedText 'Failed'
        Test-CheckCondition `
            -Name 'ARCHIVE-008 linux: missing GitHub release asset writes no marker' `
            -Condition (-not (Test-LinuxPathPresence -Path $missingAssetFixture.MarkerPath)) `
            -FailureDetail 'Marker was written after GitHub release asset lookup failed.'
    } finally {
        if ($null -ne $missingAssetFixture) {
            Clear-LinuxRuntimeDirectory -Path $missingAssetFixture.RuntimePath
        }
    }
}

function Test-LinuxCommandBackedInstallerFlow {
    $installerCases = @(
        [pscustomobject]@{
            Name = 'DISPATCH-001 linux: pip'
            Kind = 'pip'
            InstallText = "Installing 'sample-tool' with pip package"
            VersionText = 'python-version'
            TargetProperty = 'ToolPath'
            MarkerProperty = 'MarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-002 linux: python_user'
            Kind = 'python_user'
            InstallText = "Installing 'sample-tool' with pip package"
            VersionText = 'python-version'
            TargetProperty = 'ToolPath'
            MarkerProperty = 'MarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-003 linux: uv_tool'
            Kind = 'uv_tool'
            InstallText = "Installing 'sample-tool' with uv package"
            VersionText = 'uv-version'
            TargetProperty = 'ToolPath'
            MarkerProperty = 'MarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-004 linux: npm_global'
            Kind = 'npm_global'
            InstallText = "Installing 'sample-tool' with npm package"
            VersionText = 'npm-version'
            TargetProperty = 'ToolPath'
            MarkerProperty = 'MarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-005 linux: powershell_gallery'
            Kind = 'powershell_gallery'
            InstallText = "Installing 'sample-tool' from PowerShell Gallery package"
            VersionText = 'psgallery-version'
            TargetProperty = 'PowerShellModuleDirectory'
            MarkerProperty = 'PowerShellMarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-006 linux: brew'
            Kind = 'brew'
            InstallText = "Installing 'sample-tool' with Homebrew package"
            VersionText = 'brew-version'
            TargetProperty = 'FakeBinToolPath'
            MarkerProperty = 'FakeBinMarkerPath'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-016 linux: conda_forge'
            Kind = 'conda_forge'
            InstallText = "Installing 'sample-tool' with conda-forge package"
            VersionText = 'conda-version'
            TargetProperty = 'ToolPath'
            MarkerProperty = 'MarkerPath'
        }
    )

    foreach ($installerCase in $installerCases) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
        $fixture = $null
        try {
            $fixture = Initialize-LinuxDirectBinaryFixture -Layout $layout
            $result = Invoke-LinuxDirectBinaryFixture `
                -Layout $layout `
                -Fixture $fixture `
                -ManifestContent (Get-LinuxPackageInstallerManifestContent -Kind $installerCase.Kind)

            Test-ExitCode -Name "$($installerCase.Name) exits zero" -Result $result -ExpectedExitCode 0
            Test-ResultText `
                -Name "$($installerCase.Name) dispatches installer" `
                -Result $result `
                -ExpectedText $installerCase.InstallText
            Test-ResultText `
                -Name "$($installerCase.Name) reports version" `
                -Result $result `
                -ExpectedText $installerCase.VersionText
            $targetPath = $fixture.PSObject.Properties[$installerCase.TargetProperty].Value
            $markerPath = $fixture.PSObject.Properties[$installerCase.MarkerProperty].Value
            Test-CheckCondition `
                -Name "$($installerCase.Name) managed target exists" `
                -Condition (Test-LinuxPathPresence -Path $targetPath) `
                -FailureDetail 'Command-backed installer target was not created.'
            Test-CheckCondition `
                -Name "$($installerCase.Name) marker exists" `
                -Condition (Test-LinuxPathPresence -Path $markerPath) `
                -FailureDetail 'Command-backed installer marker was not written.'
        } finally {
            if ($null -ne $fixture) {
                Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
            }
        }
    }

    $missingPwshLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $missingPwshFixture = $null
    try {
        $missingPwshFixture = Initialize-LinuxDirectBinaryFixture -Layout $missingPwshLayout
        $missingPwshEnvironment = @{}
        foreach ($key in $missingPwshFixture.Environment.Keys) {
            $missingPwshEnvironment[$key] = $missingPwshFixture.Environment[$key]
        }
        $missingPwshEnvironment['CAT_TEST_ASSUME_MISSING_PWSH'] = '1'
        $missingPwshFixture.Environment = $missingPwshEnvironment
        $missingPwshResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $missingPwshLayout `
            -Fixture $missingPwshFixture `
            -ManifestContent (Get-LinuxPackageInstallerManifestContent -Kind 'powershell_gallery')

        Test-ExitCode -Name 'DISPATCH-005 linux: missing pwsh exits zero' -Result $missingPwshResult -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-005 linux: missing pwsh is skipped' `
            -Result $missingPwshResult `
            -ExpectedText 'requires pwsh on Linux'
        Test-ResultText `
            -Name 'DISPATCH-005 linux: missing pwsh summary status' `
            -Result $missingPwshResult `
            -ExpectedText 'Skipped'
    } finally {
        if ($null -ne $missingPwshFixture) {
            Clear-LinuxRuntimeDirectory -Path $missingPwshFixture.RuntimePath
        }
    }
}

function Test-WindowsPackageInstallerFlow {
    $installerCases = @(
        [pscustomobject]@{
            Name = 'DISPATCH-007 windows: winget'
            Kind = 'winget'
            InstallText = "Installing winget package 'cat-test-tool'"
            VersionText = 'winget-version'
        }
        [pscustomobject]@{
            Name = 'DISPATCH-008 windows: chocolatey'
            Kind = 'chocolatey'
            InstallText = "Installing Chocolatey package 'cat-test-tool'"
            VersionText = 'choco-version'
        }
    )

    foreach ($installerCase in $installerCases) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
        $fixture = Initialize-WindowsDispatchFixture
        $result = Invoke-WindowsDispatchFixture `
            -Layout $layout `
            -Fixture $fixture `
            -ManifestContent (Get-WindowsPackageInstallerManifestContent -Kind $installerCase.Kind)

        Test-ExitCode -Name "$($installerCase.Name) exits zero" -Result $result -ExpectedExitCode 0
        Test-ResultText `
            -Name "$($installerCase.Name) dispatches installer" `
            -Result $result `
            -ExpectedText $installerCase.InstallText
        Test-ResultText `
            -Name "$($installerCase.Name) reports version" `
            -Result $result `
            -ExpectedText $installerCase.VersionText
        Test-CheckCondition `
            -Name "$($installerCase.Name) managed command exists" `
            -Condition (Test-Path -LiteralPath $fixture.FakeBinToolPath -PathType Leaf) `
            -FailureDetail 'Package-backed Windows command was not created.'
        Test-CheckCondition `
            -Name "$($installerCase.Name) marker exists" `
            -Condition (Test-Path -LiteralPath $fixture.FakeBinMarkerPath -PathType Leaf) `
            -FailureDetail 'Package-backed Windows marker was not written.'
    }

    $failureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $failureFixture = Initialize-WindowsDispatchFixture
    Set-Content -LiteralPath (Join-Path -Path $failureFixture.FakeBinDirectory -ChildPath 'choco.cmd') -Value @(
        '@echo off'
        'if /I "%~1"=="install" exit /b 5'
        'exit /b 2'
    ) -Encoding ASCII
    $failureResult = Invoke-WindowsDispatchFixture `
        -Layout $failureLayout `
        -Fixture $failureFixture `
        -ManifestContent (Get-WindowsPackageInstallerManifestContent -Kind 'chocolatey')

    Test-NonzeroExitCode -Name 'DISPATCH-008 windows: chocolatey failure exits nonzero' -Result $failureResult
    Test-ResultText `
        -Name 'DISPATCH-008 windows: chocolatey failure is failed status' `
        -Result $failureResult `
        -ExpectedText 'Failed'
    Test-ResultText `
        -Name 'DISPATCH-008 windows: chocolatey failure includes command detail' `
        -Result $failureResult `
        -ExpectedText 'Command failed: choco install'
    Test-CheckCondition `
        -Name 'DISPATCH-008 windows: chocolatey failure writes no marker' `
        -Condition (-not (Test-Path -LiteralPath $failureFixture.FakeBinMarkerPath -PathType Leaf)) `
        -FailureDetail 'Marker was written after Chocolatey failed.'
}

function Test-WindowsArchiveAndDirectInstallerFlow {
    $portableLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $portableFixture = Initialize-WindowsDispatchFixture
    $portableResult = Invoke-WindowsDispatchFixture `
        -Layout $portableLayout `
        -Fixture $portableFixture `
        -ManifestContent (Get-WindowsPortableArchiveManifestContent -Url $portableFixture.PortableArchiveUrl)

    Test-ExitCode -Name 'DISPATCH-011 windows: portable_archive exits zero' -Result $portableResult -ExpectedExitCode 0
    Test-ResultText `
        -Name 'ARCHIVE-005 windows: seven_zip archive branch is used' `
        -Result $portableResult `
        -ExpectedText 'Extracting 7z archive'
    Test-ResultText `
        -Name 'DISPATCH-011 windows: portable_archive reports version' `
        -Result $portableResult `
        -ExpectedText 'portable-version'
    Test-CheckCondition `
        -Name 'DISPATCH-011 windows: portable_archive command exists' `
        -Condition (Test-Path -LiteralPath $portableFixture.PortableInstalledToolPath -PathType Leaf) `
        -FailureDetail 'Portable archive command was not installed.'
    Test-CheckCondition `
        -Name 'DISPATCH-011 windows: portable_archive root content exists' `
        -Condition (Test-Path -LiteralPath $portableFixture.PortableRootPath -PathType Leaf) `
        -FailureDetail 'Portable archive root content was not copied.'
    Test-CheckCondition `
        -Name 'DISPATCH-011 windows: portable_archive marker exists' `
        -Condition (Test-Path -LiteralPath $portableFixture.InstallMarkerPath -PathType Leaf) `
        -FailureDetail 'Portable archive marker was not written.'

    $zipLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $zipFixture = Initialize-WindowsDispatchFixture
    $zipResult = Invoke-WindowsDispatchFixture `
        -Layout $zipLayout `
        -Fixture $zipFixture `
        -ManifestContent (Get-WindowsDirectBinaryManifestContent -Url $zipFixture.ZipArchiveUrl -ArchiveKind 'zip')

    Test-ExitCode -Name 'ARCHIVE-013 windows: zip archive exits zero' -Result $zipResult -ExpectedExitCode 0
    Test-ResultText `
        -Name 'ARCHIVE-013 windows: zip archive branch is used' `
        -Result $zipResult `
        -ExpectedText 'Extracting zip archive'
    Test-ResultText `
        -Name 'ARCHIVE-013 windows: zip archive reports version' `
        -Result $zipResult `
        -ExpectedText 'zip-version'
    Test-CheckCondition `
        -Name 'ARCHIVE-013 windows: zip archive command exists' `
        -Condition (Test-Path -LiteralPath $zipFixture.PortableInstalledToolPath -PathType Leaf) `
        -FailureDetail 'Zip archive command was not installed.'
    Test-CheckCondition `
        -Name 'ARCHIVE-013 windows: zip archive marker exists' `
        -Condition (Test-Path -LiteralPath $zipFixture.InstallMarkerPath -PathType Leaf) `
        -FailureDetail 'Zip archive marker was not written.'

    $unsafeZipLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $unsafeZipFixture = Initialize-WindowsDispatchFixture
    $unsafeZipResult = Invoke-WindowsDispatchFixture `
        -Layout $unsafeZipLayout `
        -Fixture $unsafeZipFixture `
        -ManifestContent (Get-WindowsDirectBinaryManifestContent -Url $unsafeZipFixture.UnsafeZipArchiveUrl -ArchiveKind 'zip')

    Test-NonzeroExitCode -Name 'ARCHIVE-014 windows: unsafe zip archive exits nonzero' -Result $unsafeZipResult
    Test-ResultText `
        -Name 'ARCHIVE-014 windows: unsafe zip archive diagnostic' `
        -Result $unsafeZipResult `
        -ExpectedText 'Unsafe archive member'
    Test-ResultText `
        -Name 'ARCHIVE-014 windows: unsafe zip archive failed status' `
        -Result $unsafeZipResult `
        -ExpectedText 'Failed'
    Test-CheckCondition `
        -Name 'ARCHIVE-014 windows: unsafe zip archive writes no marker' `
        -Condition (-not (Test-Path -LiteralPath $unsafeZipFixture.InstallMarkerPath -PathType Leaf)) `
        -FailureDetail 'Marker was written after unsafe archive extraction failed.'

    $downloadFailureLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $downloadFailureFixture = Initialize-WindowsDispatchFixture
    $downloadFailureResult = Invoke-WindowsDispatchFixture `
        -Layout $downloadFailureLayout `
        -Fixture $downloadFailureFixture `
        -ManifestContent (Get-WindowsDirectBinaryManifestContent -Url $downloadFailureFixture.MissingDirectBinaryUrl)

    Test-NonzeroExitCode `
        -Name 'INSTALL-004 windows: failed direct_binary download exits nonzero' `
        -Result $downloadFailureResult
    Test-ResultText `
        -Name 'INSTALL-004 windows: failed installer status' `
        -Result $downloadFailureResult `
        -ExpectedText 'Failed'
    Test-ResultText `
        -Name 'ARCHIVE-009 windows: download failure uses staged download' `
        -Result $downloadFailureResult `
        -ExpectedText 'Downloading plain binary file'
    Test-CheckCondition `
        -Name 'ARCHIVE-009 windows: failed download publishes no target' `
        -Condition (-not (Test-Path -LiteralPath $downloadFailureFixture.PortableInstalledToolPath -PathType Leaf)) `
        -FailureDetail 'Final binary target was written after a failed download.'
    Test-CheckCondition `
        -Name 'ARCHIVE-009 windows: failed download writes no marker' `
        -Condition (-not (Test-Path -LiteralPath $downloadFailureFixture.InstallMarkerPath -PathType Leaf)) `
        -FailureDetail 'Marker was written after a failed download.'

    $installerLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $installerFixture = Initialize-WindowsDispatchFixture -IncludeDirectInstaller
    if (-not [string]::IsNullOrWhiteSpace($installerFixture.DirectInstallerWarning)) {
        Register-CheckWarning $installerFixture.DirectInstallerWarning
    }

    if ([string]::IsNullOrWhiteSpace($installerFixture.DirectInstallerUrl)) {
        Register-CheckWarning 'DISPATCH-012 windows skipped because the direct installer fixture is unavailable.'
        return
    }

    $installerResult = Invoke-WindowsDispatchFixture `
        -Layout $installerLayout `
        -Fixture $installerFixture `
        -ManifestContent (Get-WindowsDirectInstallerManifestContent -Url $installerFixture.DirectInstallerUrl)

    Test-ExitCode -Name 'DISPATCH-012 windows: direct_installer exits zero' -Result $installerResult -ExpectedExitCode 0
    Test-ResultText `
        -Name 'DISPATCH-012 windows: direct_installer runs installer' `
        -Result $installerResult `
        -ExpectedText 'Running installer'
    Test-ResultText `
        -Name 'DISPATCH-012 windows: direct_installer reports version' `
        -Result $installerResult `
        -ExpectedText 'installer-version'
    Test-CheckCondition `
        -Name 'DISPATCH-012 windows: direct_installer command exists' `
        -Condition (Test-Path -LiteralPath $installerFixture.InstalledToolPath -PathType Leaf) `
        -FailureDetail 'Direct installer command was not installed.'
    Test-CheckCondition `
        -Name 'DISPATCH-012 windows: direct_installer marker exists' `
        -Condition (Test-Path -LiteralPath $installerFixture.InstallMarkerPath -PathType Leaf) `
        -FailureDetail 'Direct installer marker was not written.'
}

function Test-LinuxSourceMakeInstallFlow {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxDirectBinaryFixture -Layout $layout -SourceMode 'SourceMake'
        $result = Invoke-LinuxDirectBinaryFixture `
            -Layout $layout `
            -Fixture $fixture `
            -ManifestContent (Get-LinuxSourceMakeManifestContent -Url $fixture.SourceUrl)

        Test-ExitCode -Name 'DISPATCH-014 linux: source_make exits zero' -Result $result -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-014 linux: source_make dispatches builder' `
            -Result $result `
            -ExpectedText "Installing 'sample-tool' from source"
        Test-ResultText `
            -Name 'DISPATCH-014 linux: source_make runs source build' `
            -Result $result `
            -ExpectedText 'Running source build'
        Test-ResultText `
            -Name 'DISPATCH-014 linux: source_make reports version' `
            -Result $result `
            -ExpectedText 'source-version'
        Test-CheckCondition `
            -Name 'DISPATCH-014 linux: source_make installed binary exists' `
            -Condition (Test-LinuxPathPresence -Path $fixture.ToolPath) `
            -FailureDetail 'source_make binary was not installed.'
        Test-CheckCondition `
            -Name 'DISPATCH-014 linux: source_make marker exists' `
            -Condition (Test-LinuxPathPresence -Path $fixture.MarkerPath) `
            -FailureDetail 'source_make marker was not written.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-LinuxSourceMakeFallbackFlow {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxDirectBinaryFixture -Layout $layout -SourceMode 'NoCompilerFallback'
        $result = Invoke-LinuxDirectBinaryFixture `
            -Layout $layout `
            -Fixture $fixture `
            -ManifestContent (
                Get-LinuxSourceMakeManifestContent `
                    -Url $fixture.SourceUrl `
                    -ToolId 'ghostscript' `
                    -Package 'sample-tool'
            )

        $ghostscriptToolPath = "$($fixture.PrefixPath)/coding-agent-toolchain/ghostscript/bin/sample-tool"
        $ghostscriptMarkerPath = "$($fixture.PrefixPath)/coding-agent-toolchain/ghostscript/.coding-agent-toolchain"

        Test-ExitCode -Name 'DISPATCH-015 linux: source_make fallback exits zero' -Result $result -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-015 linux: source_make fallback detects missing compiler' `
            -Result $result `
            -ExpectedText 'No C compiler found for Ghostscript'
        Test-ResultText `
            -Name 'DISPATCH-015 linux: source_make fallback uses conda_forge' `
            -Result $result `
            -ExpectedText "Installing 'ghostscript' with conda-forge package"
        Test-ResultText `
            -Name 'DISPATCH-015 linux: source_make fallback reports version' `
            -Result $result `
            -ExpectedText 'conda-version'
        Test-CheckCondition `
            -Name 'DISPATCH-015 linux: source_make fallback command exists' `
            -Condition (Test-LinuxPathPresence -Path $ghostscriptToolPath) `
            -FailureDetail 'Fallback conda-forge command was not installed.'
        Test-CheckCondition `
            -Name 'DISPATCH-015 linux: source_make fallback marker exists' `
            -Condition (Test-LinuxPathPresence -Path $ghostscriptMarkerPath) `
            -FailureDetail 'Fallback conda-forge marker was not written.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-LinuxAppImageInstallFlow {
    $routedLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $routedFixture = $null
    try {
        $routedFixture = Initialize-LinuxDirectBinaryFixture `
            -Layout $routedLayout `
            -SourceMode 'AppImage' `
            -TargetFileName 'sample-tool.AppImage'
        $routedResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $routedLayout `
            -Fixture $routedFixture `
            -ManifestContent (
                Get-LinuxDirectBinaryManifestContent `
                    -Url $routedFixture.SourceUrl `
                    -FileName 'sample-tool.AppImage'
            ) `
            -UseDefaultRoot

        Test-ExitCode -Name 'DISPATCH-018 linux: direct_binary AppImage exits zero' -Result $routedResult -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-018 linux: direct_binary AppImage is routed to extraction' `
            -Result $routedResult `
            -ExpectedText 'points to an AppImage'
        Test-ResultText -Name 'ARCHIVE-006 linux: routed AppImage version is reported' -Result $routedResult -ExpectedText 'appimage-version'
        Test-CheckCondition `
            -Name 'DISPATCH-018 linux: routed AppImage wrapper exists' `
            -Condition (Test-LinuxPathPresence -Path $routedFixture.DefaultToolPath) `
            -FailureDetail 'Routed AppImage wrapper was not created.'
        Test-CheckCondition `
            -Name 'ARCHIVE-006 linux: routed AppImage command symlink exists' `
            -Condition (Test-LinuxCommandLinkPresence -Path $routedFixture.CommandPath) `
            -FailureDetail 'Routed AppImage command symlink was not created.'
        Test-CheckCondition `
            -Name 'ARCHIVE-006 linux: routed AppImage marker exists' `
            -Condition (Test-LinuxPathPresence -Path $routedFixture.DefaultMarkerPath) `
            -FailureDetail 'Routed AppImage marker was not written.'
    } finally {
        if ($null -ne $routedFixture) {
            Clear-LinuxRuntimeDirectory -Path $routedFixture.RuntimePath
        }
    }

    $directLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-UnavailableManifestContent)
    $directFixture = $null
    try {
        $directFixture = Initialize-LinuxDirectBinaryFixture `
            -Layout $directLayout `
            -SourceMode 'AppImage' `
            -TargetFileName 'sample-tool.AppImage'
        $directResult = Invoke-LinuxDirectBinaryFixture `
            -Layout $directLayout `
            -Fixture $directFixture `
            -ManifestContent (
                Get-LinuxDirectBinaryManifestContent `
                    -Url $directFixture.SourceUrl `
                    -FileName 'sample-tool.AppImage' `
                    -Kind 'appimage_extract'
            ) `
            -UseDefaultRoot

        Test-ExitCode -Name 'DISPATCH-013 linux: appimage_extract exits zero' -Result $directResult -ExpectedExitCode 0
        Test-ResultText `
            -Name 'DISPATCH-013 linux: appimage_extract uses extraction branch' `
            -Result $directResult `
            -ExpectedText 'extracted AppImage'
        Test-ResultText -Name 'ARCHIVE-006 linux: direct AppImage version is reported' -Result $directResult -ExpectedText 'appimage-version'
        Test-CheckCondition `
            -Name 'DISPATCH-013 linux: appimage_extract wrapper exists' `
            -Condition (Test-LinuxPathPresence -Path $directFixture.DefaultToolPath) `
            -FailureDetail 'Direct AppImage wrapper was not created.'
        Test-CheckCondition `
            -Name 'DISPATCH-013 linux: appimage_extract command symlink exists' `
            -Condition (Test-LinuxCommandLinkPresence -Path $directFixture.CommandPath) `
            -FailureDetail 'Direct AppImage command symlink was not created.'
    } finally {
        if ($null -ne $directFixture) {
            Clear-LinuxRuntimeDirectory -Path $directFixture.RuntimePath
        }
    }
}

function Test-DefaultPathResolution {
    $windowsLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
    $windowsResult = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $windowsLayout `
        -Arguments @('-d', '-v', '-c', $windowsLayout.ManifestPath)
    $windowsDefaultRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) `
        -ChildPath 'CodingAgentToolchain'
    Test-ExitCode -Name 'PATH-001 windows: default root exits zero' -Result $windowsResult -ExpectedExitCode 0
    Test-ResultText -Name 'PATH-001 windows: default root uses LOCALAPPDATA' -Result $windowsResult -ExpectedText $windowsDefaultRoot

    $linuxLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
    $linuxConfigPath = Get-PlatformPathArgument -Platform 'linux' -Path $linuxLayout.ManifestPath
    $linuxHomePath = Get-BashHomePath
    $linuxResult = Invoke-IsolatedToolScript `
        -Platform 'linux' `
        -Layout $linuxLayout `
        -Arguments @('-d', '-v', '-c', $linuxConfigPath)
    Test-ExitCode -Name 'PATH-002 linux: default XDG root exits zero' -Result $linuxResult -ExpectedExitCode 0
    if (-not [string]::IsNullOrWhiteSpace($linuxHomePath)) {
        Test-ResultText `
            -Name 'PATH-002 linux: default XDG root uses HOME local share' `
            -Result $linuxResult `
            -ExpectedText "$linuxHomePath/.local/share/coding-agent-toolchain"
    }

    $xdgLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
    $xdgDataHome = Join-Path -Path $xdgLayout.Home -ChildPath 'xdg-data'
    New-Item -ItemType Directory -Path $xdgDataHome | Out-Null
    $xdgHomePath = ConvertTo-BashPath -Path $xdgLayout.Home
    $xdgDataHomePath = ConvertTo-BashPath -Path $xdgDataHome
    $xdgConfigPath = Get-PlatformPathArgument -Platform 'linux' -Path $xdgLayout.ManifestPath
    $xdgResult = Invoke-IsolatedToolScript `
        -Platform 'linux' `
        -Layout $xdgLayout `
        -Arguments @('-d', '-v', '-c', $xdgConfigPath) `
        -Environment @{
            HOME = $xdgHomePath
            XDG_DATA_HOME = $xdgDataHomePath
        }
    Test-ExitCode -Name 'PATH-003 linux: absolute XDG root exits zero' -Result $xdgResult -ExpectedExitCode 0
    Test-ResultText `
        -Name 'PATH-003 linux: absolute XDG root uses XDG_DATA_HOME' `
        -Result $xdgResult `
        -ExpectedText "$xdgDataHomePath/coding-agent-toolchain"

    $outsideXdgLayout = Initialize-IsolatedScriptLayout `
        -ManifestContent (Get-DryRunManifestContent)
    $outsideXdgDataHome = Join-Path `
        -Path $outsideXdgLayout.Root `
        -ChildPath 'outside-xdg-data'
    New-Item -ItemType Directory -Path $outsideXdgDataHome | Out-Null
    $outsideXdgHomePath = ConvertTo-BashPath -Path $outsideXdgLayout.Home
    $outsideXdgDataHomePath = ConvertTo-BashPath -Path $outsideXdgDataHome
    $outsideXdgConfigPath = Get-PlatformPathArgument `
        -Platform 'linux' `
        -Path $outsideXdgLayout.ManifestPath
    $outsideXdgResult = Invoke-IsolatedToolScript `
        -Platform 'linux' `
        -Layout $outsideXdgLayout `
        -Arguments @('-d', '-v', '-c', $outsideXdgConfigPath) `
        -Environment @{
            HOME = $outsideXdgHomePath
            XDG_DATA_HOME = $outsideXdgDataHomePath
        }
    Test-NonzeroExitCode `
        -Name 'PATH-019 linux: outside XDG root fails' `
        -Result $outsideXdgResult
    Test-ResultText `
        -Name 'PATH-019 linux: outside XDG root diagnostic' `
        -Result $outsideXdgResult `
        -ExpectedText 'XDG_DATA_HOME must point inside'
    $outsideXdgToolRoot = Join-Path `
        -Path $outsideXdgDataHome `
        -ChildPath 'coding-agent-toolchain'
    Test-CheckCondition `
        -Name 'PATH-019 linux: outside XDG root remains untouched' `
        -Condition (-not (Test-Path -LiteralPath $outsideXdgToolRoot)) `
        -FailureDetail "Unexpected outside XDG tool root '$outsideXdgToolRoot'."
}

function Test-PrefixPathValidation {
    foreach ($platform in @('windows', 'linux')) {
        $absoluteLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $absoluteConfigPath = Get-PlatformPathArgument -Platform $platform -Path $absoluteLayout.ManifestPath
        $absolutePrefix = Initialize-PlatformPrefixArgument -Platform $platform -Layout $absoluteLayout
        $absoluteEnvironment = @{}
        if ($platform -eq 'linux') {
            $absoluteEnvironment = @{
                HOME = ConvertTo-BashPath -Path $absoluteLayout.Home
            }
        }
        $absoluteResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $absoluteLayout `
            -Arguments @('-d', '-c', $absoluteConfigPath, '-p', $absolutePrefix) `
            -Environment $absoluteEnvironment
        Test-ExitCode -Name "PATH-004 ${platform}: valid absolute prefix exits zero" -Result $absoluteResult -ExpectedExitCode 0
        Test-ResultText `
            -Name "PATH-004 ${platform}: valid absolute prefix root" `
            -Result $absoluteResult `
            -ExpectedText 'coding-agent-toolchain'

        if ($platform -ne 'windows') {
            $outsideLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
            $outsideConfigPath = Get-PlatformPathArgument -Platform $platform -Path $outsideLayout.ManifestPath
            $outsideResult = Invoke-IsolatedToolScript `
                -Platform $platform `
                -Layout $outsideLayout `
                -Arguments @('-d', '-c', $outsideConfigPath, '-p', '/usr')
            Test-NonzeroExitCode -Name "PATH-007 ${platform}: outside prefix fails" -Result $outsideResult
            Test-ResultText `
                -Name "PATH-007 ${platform}: outside prefix diagnostic" `
                -Result $outsideResult `
                -ExpectedText '--prefix must point inside'
            continue
        }

        $relativeLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $relativeConfigPath = Get-PlatformPathArgument -Platform $platform -Path $relativeLayout.ManifestPath
        $relativeWorkingDirectory = Initialize-TemporaryPrefixDirectory
        New-Item -ItemType Directory -Path $relativeWorkingDirectory -Force | Out-Null
        $relativePrefixDirectory = Join-Path -Path $relativeWorkingDirectory -ChildPath 'relative-prefix'
        New-Item -ItemType Directory -Path $relativePrefixDirectory | Out-Null
        $relativeResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $relativeLayout `
            -Arguments @('-d', '-c', $relativeConfigPath, '-p', 'relative-prefix') `
            -WorkingDirectory $relativeWorkingDirectory
        Test-ExitCode -Name "PATH-005 ${platform}: valid relative prefix exits zero" -Result $relativeResult -ExpectedExitCode 0
        Test-ResultText `
            -Name "PATH-005 ${platform}: valid relative prefix root" `
            -Result $relativeResult `
            -ExpectedText 'coding-agent-toolchain'

        $userRootLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $userRootConfigPath = Get-PlatformPathArgument -Platform $platform -Path $userRootLayout.ManifestPath
        $userRootPrefix = $userRootLayout.Home
        $userRootResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $userRootLayout `
            -Arguments @('-d', '-c', $userRootConfigPath, '-p', $userRootPrefix) `
            -Environment @{ CAT_TEST_USER_PROFILE_ROOT = $userRootPrefix }
        Test-ExitCode -Name "PATH-006 ${platform}: user-root prefix exits zero" -Result $userRootResult -ExpectedExitCode 0
        Test-ResultText `
            -Name "PATH-006 ${platform}: user-root prefix stays under toolchain root" `
            -Result $userRootResult `
            -ExpectedText 'coding-agent-toolchain'

        $outsideLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $outsideConfigPath = Get-PlatformPathArgument -Platform $platform -Path $outsideLayout.ManifestPath
        $outsideResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $outsideLayout `
            -Arguments @('-d', '-c', $outsideConfigPath, '-p', 'C:\Windows')
        Test-NonzeroExitCode -Name "PATH-007 ${platform}: outside prefix fails" -Result $outsideResult
        Test-ResultText `
            -Name "PATH-007 ${platform}: outside prefix diagnostic" `
            -Result $outsideResult `
            -ExpectedText '--prefix must point inside'

        $missingLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $missingConfigPath = Get-PlatformPathArgument -Platform $platform -Path $missingLayout.ManifestPath
        $missingWorkingDirectory = Initialize-TemporaryPrefixDirectory
        $missingResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $missingLayout `
            -Arguments @('-d', '-c', $missingConfigPath, '-p', 'missing-prefix') `
            -WorkingDirectory $missingWorkingDirectory
        Test-NonzeroExitCode -Name "PATH-016 ${platform}: missing prefix fails" -Result $missingResult
        Test-ResultText `
            -Name "PATH-016 ${platform}: missing prefix diagnostic" `
            -Result $missingResult `
            -ExpectedText 'existing directory'
    }
}

function Test-PrefixPhysicalEscapeRejection {
    foreach ($platform in @('windows', 'linux')) {
        $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DryRunManifestContent)
        $configPath = Get-PlatformPathArgument -Platform $platform -Path $layout.ManifestPath
        $externalPrefix = Initialize-TemporaryPrefixDirectory
        $externalToolRoot = Join-Path -Path $externalPrefix -ChildPath 'coding-agent-toolchain'

        if ($platform -eq 'windows') {
            $userProfileRoot = $layout.Home
            $escapedPrefix = Join-Path -Path $userProfileRoot -ChildPath 'escaped-prefix'
            try {
                New-Item -ItemType Junction -Path $escapedPrefix -Target $externalPrefix -ErrorAction Stop | Out-Null
            } catch {
                Register-CheckWarning "PATH-018 windows skipped because link setup failed: $($_.Exception.Message)"
                if (Test-Path -LiteralPath $externalPrefix -PathType Container) {
                    Remove-Item -LiteralPath $externalPrefix -Recurse -Force -ErrorAction SilentlyContinue
                }
                continue
            }

            try {
                $result = Invoke-IsolatedToolScript `
                    -Platform $platform `
                    -Layout $layout `
                    -Arguments @('-d', '-c', $configPath, '-p', $escapedPrefix) `
                    -Environment @{ CAT_TEST_USER_PROFILE_ROOT = $userProfileRoot }
                Test-NonzeroExitCode -Name 'PATH-018 windows: linked prefix fails' -Result $result
                Test-ResultText `
                    -Name 'PATH-018 windows: linked prefix diagnostic' `
                    -Result $result `
                    -ExpectedText '--prefix must point inside'
                Register-CheckResult `
                    -Name 'PATH-018 windows: escaped target remains untouched' `
                    -Passed (-not (Test-Path -LiteralPath $externalToolRoot)) `
                    -Detail "Unexpected escaped target '$externalToolRoot'."
            } finally {
                if (Test-Path -LiteralPath $escapedPrefix) {
                    try {
                        [IO.Directory]::Delete($escapedPrefix)
                    } catch {
                        Register-CheckWarning "Could not remove PATH-018 junction '$escapedPrefix': $($_.Exception.Message)"
                    }
                }
                if (Test-Path -LiteralPath $externalPrefix -PathType Container) {
                    Remove-Item -LiteralPath $externalPrefix -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            continue
        }

        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            Register-CheckWarning 'PATH-018 linux skipped because bash is unavailable.'
            continue
        }

        $homePath = ConvertTo-BashPath -Path $layout.Home
        $escapedPrefix = Join-Path -Path $layout.Home -ChildPath 'escaped-prefix'
        $escapedPrefixPath = ConvertTo-BashPath -Path $escapedPrefix
        $externalPrefixPath = ConvertTo-BashPath -Path $externalPrefix
        $linkCommand = 'ln -s -- ' +
            (ConvertTo-BashSingleQuotedLiteral -Value $externalPrefixPath) + ' ' +
            (ConvertTo-BashSingleQuotedLiteral -Value $escapedPrefixPath)
        $linkResult = Invoke-CommandCapture -Command $bashCommand.Source -Arguments @('-lc', $linkCommand)
        if ($linkResult.ExitCode -ne 0) {
            Register-CheckWarning "PATH-018 linux skipped because a symlink could not be created: $($linkResult.Output)"
            continue
        }
        if (-not (Test-LinuxPathPresence -Path $escapedPrefixPath -SymbolicLink)) {
            Register-CheckWarning 'PATH-018 linux skipped because bash did not create a real symlink.'
            continue
        }

        $result = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $layout `
            -Arguments @('-d', '-c', $configPath, '-p', $escapedPrefixPath) `
            -Environment @{ HOME = $homePath }
        Test-NonzeroExitCode -Name 'PATH-018 linux: linked prefix fails' -Result $result
        Test-ResultText `
            -Name 'PATH-018 linux: linked prefix diagnostic' `
            -Result $result `
            -ExpectedText '--prefix must point inside'
        Register-CheckResult `
            -Name 'PATH-018 linux: escaped target remains untouched' `
            -Passed (-not (Test-Path -LiteralPath $externalToolRoot)) `
            -Detail "Unexpected escaped target '$externalToolRoot'."
    }
}

function Test-DirectDispatchAndInstall {
    Test-InstallNoopFlow
    Test-DispatchUnsupportedKind
    Test-DefaultPathResolution
    Test-PrefixPathValidation
    Test-PrefixPhysicalEscapeRejection
    Test-PathNoopStatus
    Test-LinuxInteropCommandPath
    Test-LinuxDirectBinaryInstallFlow
    Test-LinuxArchiveInstallFlow
    Test-LinuxPortableArchiveInstallFlow
    Test-LinuxGitHubReleaseAssetInstallFlow
    Test-LinuxCommandBackedInstallerFlow
    Test-WindowsPackageInstallerFlow
    Test-WindowsArchiveAndDirectInstallerFlow
    Test-LinuxSourceMakeInstallFlow
    Test-LinuxSourceMakeFallbackFlow
    Test-LinuxAppImageInstallFlow
}

function Get-DirectBinaryManifestContent {
    @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    version_args:
      - --version
    installers:
      windows:
        kind: direct_binary
        url: https://example.invalid/sample-tool.exe
        file_name: sample-tool.exe
      linux:
        kind: direct_binary
        url: https://example.invalid/sample-tool
        file_name: sample-tool
'@
}

function Get-SharedDirectoryManifestContent {
    @'
schema_version: 1
tools:
  - id: sample-tool
    executable: sample-tool
    installers:
      windows:
        kind: direct_binary
        url: https://example.invalid/sample-tool.exe
        file_name: sample-tool.exe
        install_dir_name: .
      linux:
        kind: unavailable
'@
}

function Initialize-WindowsMarkedToolDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrefixPath,

        [string]$DirectoryName = 'sample-tool',

        [switch]$SkipMarker
    )

    $toolRoot = Join-Path -Path $PrefixPath -ChildPath 'coding-agent-toolchain'
    $toolDirectory = Join-Path -Path $toolRoot -ChildPath $DirectoryName
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    if (-not $SkipMarker) {
        Set-Content `
            -LiteralPath (Join-Path -Path $toolDirectory -ChildPath '.coding-agent-toolchain') `
            -Value 'test marker' `
            -Encoding ASCII
    }

    return $toolDirectory
}

function Initialize-LinuxMarkedToolDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [switch]$UseUnmanagedCommand,

        [switch]$AddObsoleteProfileEntry
    )

    $runtimePath = Initialize-LinuxRuntimeDirectory
    $machineName = Get-BashMachineName
    $useUnmanagedValue = if ($UseUnmanagedCommand) { '1' } else { '0' }
    $addObsoleteValue = if ($AddObsoleteProfileEntry) { '1' } else { '0' }
    $setupScript = Join-Path -Path $Layout.Root -ChildPath 'setup-linux-removal.sh'
    $setupLines = @(
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        'runtime_path="$1"',
        'machine_name="$2"',
        'use_unmanaged="$3"',
        'add_obsolete="$4"',
        'home_path="${runtime_path}/home"',
        'xdg_data_home="${home_path}/xdg-data"',
        'tool_directory="${xdg_data_home}/coding-agent-toolchain/tools/linux-${machine_name}/sample-tool"',
        'tool_bin_directory="${tool_directory}/bin"',
        'command_directory="${home_path}/.local/bin"',
        'mkdir -p -- "${tool_bin_directory}" "${command_directory}"',
        'printf "%s\n" "test marker" >"${tool_directory}/.coding-agent-toolchain"',
        'managed_command="${tool_bin_directory}/sample-tool"',
        'printf "%s\n" "#!/usr/bin/env bash" "printf ''linux-remove-version\n''" >"${managed_command}"',
        'chmod 755 "${managed_command}"',
        'target_path="${managed_command}"',
        'if [[ "${use_unmanaged}" == "1" ]]; then',
        '  unmanaged_directory="${runtime_path}/unmanaged-bin"',
        '  mkdir -p -- "${unmanaged_directory}"',
        '  target_path="${unmanaged_directory}/sample-tool"',
        '  printf "%s\n" "#!/usr/bin/env bash" "printf ''unmanaged-version\n''" >"${target_path}"',
        '  chmod 755 "${target_path}"',
        'fi',
        'ln -s "${target_path}" "${command_directory}/sample-tool"',
        'if [[ "${add_obsolete}" == "1" ]]; then',
        '  obsolete_tool_directory="${tool_directory}"',
        '  if command -v cygpath >/dev/null 2>&1; then',
        '    obsolete_tool_directory="$(cd "${tool_directory}" && pwd -P)"',
        '  fi',
        '  printf "# coding-agent-toolchain PATH: %s/bin\n" "${obsolete_tool_directory}" >"${home_path}/.profile"',
        'fi'
    )
    [IO.File]::WriteAllText($setupScript, ($setupLines -join "`n") + "`n", [Text.Encoding]::ASCII)

    try {
        $bashCommand = Get-Command -Name bash -ErrorAction SilentlyContinue
        if ($null -eq $bashCommand) {
            throw 'bash is required for Linux removal fixtures.'
        }

        $setupResult = Invoke-CommandCapture `
            -Command $bashCommand.Source `
            -Arguments @((ConvertTo-BashPath -Path $setupScript), $runtimePath, $machineName, $useUnmanagedValue, $addObsoleteValue)
        if ($setupResult.ExitCode -ne 0) {
            throw "Could not initialize Linux removal fixture. Output: $($setupResult.Output)"
        }

        $homePath = "$runtimePath/home"
        $xdgDataHomePath = "$homePath/xdg-data"
        $commandDirectoryPath = "$homePath/.local/bin"
        $toolDirectoryPath = "$xdgDataHomePath/coding-agent-toolchain/tools/linux-$machineName/sample-tool"

        return [pscustomobject]@{
            RuntimePath = $runtimePath
            ToolDirectory = $toolDirectoryPath
            CommandPath = "$commandDirectoryPath/sample-tool"
            Environment = @{
                HOME = $homePath
                XDG_DATA_HOME = $xdgDataHomePath
                PATH = "${commandDirectoryPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            }
        }
    } catch {
        Clear-LinuxRuntimeDirectory -Path $runtimePath
        throw
    }
}

function Test-WindowsRemoveMarkedDirectory {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $prefixPath = Initialize-TemporaryPrefixDirectory
    $toolDirectory = Initialize-WindowsMarkedToolDirectory -PrefixPath $prefixPath
    $result = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $layout `
        -Arguments @('-r', '-c', $layout.ManifestPath, '-p', $prefixPath)

    Test-ExitCode -Name 'REMOVE-003 windows: marked directory removal exits zero' -Result $result -ExpectedExitCode 0
    Test-ResultText -Name 'REMOVE-003 windows: marked directory status' -Result $result -ExpectedText 'Removed'
    Test-CheckCondition `
        -Name 'REMOVE-003 windows: marked directory removed' `
        -Condition (-not (Test-Path -LiteralPath $toolDirectory)) `
        -FailureDetail 'Marked tool directory still exists after removal.'
}

function Test-LinuxRemoveMarkedDirectory {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxMarkedToolDirectory -Layout $layout
        $configPath = Get-PlatformPathArgument -Platform 'linux' -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript `
            -Platform 'linux' `
            -Layout $layout `
            -Arguments @('-r', '-v', '-c', $configPath) `
            -Environment $fixture.Environment

        Test-ExitCode -Name 'REMOVE-003 linux: marked directory removal exits zero' -Result $result -ExpectedExitCode 0
        Test-ResultText -Name 'REMOVE-003 linux: marked directory status' -Result $result -ExpectedText 'Removed'
        Test-CheckCondition `
            -Name 'REMOVE-003 linux: marked directory removed' `
            -Condition (-not (Test-LinuxPathPresence -Path $fixture.ToolDirectory)) `
            -FailureDetail 'Marked Linux tool directory still exists after removal.'
        Test-CheckCondition `
            -Name 'REMOVE-010 linux: managed command symlink removed' `
            -Condition (-not (Test-LinuxPathPresence -Path $fixture.CommandPath -SymbolicLink)) `
            -FailureDetail 'Managed Linux command symlink still exists after removal.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-WindowsRemoveRefusal {
    $missingMarkerLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $missingMarkerPrefix = Initialize-TemporaryPrefixDirectory
    $missingMarkerDirectory = Initialize-WindowsMarkedToolDirectory -PrefixPath $missingMarkerPrefix -SkipMarker
    $missingMarkerResult = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $missingMarkerLayout `
        -Arguments @('-r', '-c', $missingMarkerLayout.ManifestPath, '-p', $missingMarkerPrefix)
    Test-ExitCode -Name 'REMOVE-004 windows: marker-missing exits zero' -Result $missingMarkerResult -ExpectedExitCode 0
    Test-ResultText -Name 'REMOVE-004 windows: marker-missing skipped' -Result $missingMarkerResult -ExpectedText 'marker is missing'
    Test-CheckCondition `
        -Name 'REMOVE-004 windows: marker-missing directory remains' `
        -Condition (Test-Path -LiteralPath $missingMarkerDirectory) `
        -FailureDetail 'Directory without marker was removed.'

    $targetMissingLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $targetMissingPrefix = Initialize-TemporaryPrefixDirectory
    $targetMissingResult = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $targetMissingLayout `
        -Arguments @('-r', '-c', $targetMissingLayout.ManifestPath, '-p', $targetMissingPrefix)
    Test-ExitCode -Name 'REMOVE-005 windows: target-missing exits zero' -Result $targetMissingResult -ExpectedExitCode 0
    Test-ResultText -Name 'REMOVE-005 windows: target-missing skipped' -Result $targetMissingResult -ExpectedText 'directory does not exist'

    $sharedLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-SharedDirectoryManifestContent)
    $sharedPrefix = Initialize-TemporaryPrefixDirectory
    $sharedRoot = Initialize-WindowsMarkedToolDirectory -PrefixPath $sharedPrefix -DirectoryName '.'
    $sharedResult = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $sharedLayout `
        -Arguments @('-r', '-c', $sharedLayout.ManifestPath, '-p', $sharedPrefix)
    Test-ExitCode -Name 'REMOVE-007 windows: shared directory exits zero' -Result $sharedResult -ExpectedExitCode 0
    Test-ResultText -Name 'REMOVE-007 windows: shared directory refused' -Result $sharedResult -ExpectedText 'shared'
    Test-CheckCondition `
        -Name 'REMOVE-007 windows: shared directory remains' `
        -Condition (Test-Path -LiteralPath $sharedRoot) `
        -FailureDetail 'Shared directory was removed.'

    $physicalEscapeLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $physicalEscapePrefix = Initialize-TemporaryPrefixDirectory
    $physicalEscapeExternalRoot = Join-Path -Path $RepoRoot -ChildPath '.test-runtime'
    $physicalEscapeExternalPrefix = Join-Path `
        -Path $physicalEscapeExternalRoot `
        -ChildPath ('physical-escape-' + [guid]::NewGuid().ToString('N'))
    $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $profileRootPath = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd($trimCharacters)
    $externalPrefixPath = [IO.Path]::GetFullPath($physicalEscapeExternalPrefix).TrimEnd($trimCharacters)
    if ($externalPrefixPath.StartsWith("$profileRootPath$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        Register-CheckWarning 'SAFETY-007 windows skipped because the repository is under the user profile.'
        return
    }

    New-Item -ItemType Directory -Path $physicalEscapeExternalPrefix -Force | Out-Null
    $physicalEscapeExternalDirectory = Initialize-WindowsMarkedToolDirectory -PrefixPath $physicalEscapeExternalPrefix
    $physicalEscapeToolRoot = Join-Path -Path $physicalEscapePrefix -ChildPath 'coding-agent-toolchain'
    $physicalEscapeLink = Join-Path -Path $physicalEscapeToolRoot -ChildPath 'sample-tool'
    New-Item -ItemType Directory -Path $physicalEscapeToolRoot -Force | Out-Null
    try {
        New-Item `
            -ItemType Junction `
            -Path $physicalEscapeLink `
            -Target $physicalEscapeExternalDirectory `
            -ErrorAction Stop |
            Out-Null
    } catch {
        Register-CheckWarning "SAFETY-007 windows skipped because link setup failed: $($_.Exception.Message)"
        return
    }

    try {
        $physicalEscapeResult = Invoke-IsolatedToolScript `
            -Platform 'windows' `
            -Layout $physicalEscapeLayout `
            -Arguments @('-r', '-c', $physicalEscapeLayout.ManifestPath, '-p', $physicalEscapePrefix)
        Test-ExitCode `
            -Name 'SAFETY-007 windows: physical removal escape exits zero' `
            -Result $physicalEscapeResult `
            -ExpectedExitCode 0
        Test-ResultText `
            -Name 'SAFETY-007 windows: physical removal escape refused' `
            -Result $physicalEscapeResult `
            -ExpectedText 'outside the current user profile'
        Test-CheckCondition `
            -Name 'SAFETY-007 windows: escaped target remains' `
            -Condition (Test-Path -LiteralPath $physicalEscapeExternalDirectory) `
            -FailureDetail 'Physical removal escape target was removed.'
    } finally {
        if (Test-Path -LiteralPath $physicalEscapeLink) {
            try {
                [IO.Directory]::Delete($physicalEscapeLink)
            } catch {
                Register-CheckWarning "Could not remove SAFETY-007 junction '$physicalEscapeLink': $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $physicalEscapeExternalPrefix) {
            Remove-Item -LiteralPath $physicalEscapeExternalPrefix -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $physicalEscapeExternalRoot) -and
            (Get-ChildItem -LiteralPath $physicalEscapeExternalRoot -Force | Measure-Object).Count -eq 0) {
            Remove-Item -LiteralPath $physicalEscapeExternalRoot -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-LinuxRemoveUnmanagedCommand {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxMarkedToolDirectory -Layout $layout -UseUnmanagedCommand
        $configPath = Get-PlatformPathArgument -Platform 'linux' -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript `
            -Platform 'linux' `
            -Layout $layout `
            -Arguments @('-r', '-v', '-c', $configPath) `
            -Environment $fixture.Environment

        Test-ExitCode -Name 'REMOVE-011 linux: unmanaged command exits zero' -Result $result -ExpectedExitCode 0
        if (Test-BashHasCygpath) {
            Register-CheckResult `
                -Name 'REMOVE-011 linux: unmanaged command is left untouched' `
                -Passed (Test-LinuxCommandLinkPresence -Path $fixture.CommandPath) `
                -Detail 'Git Bash does not expose fixture links with native -L semantics.'
        } else {
            Test-ResultText `
                -Name 'REMOVE-011 linux: unmanaged command is left untouched' `
                -Result $result `
                -ExpectedText 'does not point into'
        }
        Test-CheckCondition `
            -Name 'REMOVE-011 linux: unmanaged command remains' `
            -Condition (Test-LinuxCommandLinkPresence -Path $fixture.CommandPath) `
            -FailureDetail 'Unmanaged Linux command symlink was removed.'
        Test-CheckCondition `
            -Name 'REMOVE-011 linux: payload directory still removed' `
            -Condition (-not (Test-LinuxPathPresence -Path $fixture.ToolDirectory)) `
            -FailureDetail 'Linux payload directory was not removed.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-LinuxRemoveObsoletePathEntry {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $fixture = $null
    try {
        $fixture = Initialize-LinuxMarkedToolDirectory -Layout $layout -AddObsoleteProfileEntry
        $configPath = Get-PlatformPathArgument -Platform 'linux' -Path $layout.ManifestPath
        $result = Invoke-IsolatedToolScript `
            -Platform 'linux' `
            -Layout $layout `
            -Arguments @('-r', '-c', $configPath) `
            -Environment $fixture.Environment

        Test-NonzeroExitCode -Name 'REMOVE-013 linux: obsolete PATH entry fails run' -Result $result
        Test-ResultText `
            -Name 'REMOVE-013 linux: obsolete PATH entry is listed' `
            -Result $result `
            -ExpectedText 'Obsolete PATH entries'
        Test-ResultText -Name 'REMOVE-013 linux: payload still removed' -Result $result -ExpectedText 'Removed'
        Test-CheckCondition `
            -Name 'REMOVE-013 linux: directory removed before obsolete PATH report' `
            -Condition (-not (Test-LinuxPathPresence -Path $fixture.ToolDirectory)) `
            -FailureDetail 'Linux payload directory was not removed before obsolete PATH report.'
    } finally {
        if ($null -ne $fixture) {
            Clear-LinuxRuntimeDirectory -Path $fixture.RuntimePath
        }
    }
}

function Test-RemoveDryRunUnsupportedAndPrefix {
    foreach ($platform in @('windows', 'linux')) {
        $dryRunLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
        $dryRunArguments = @('-d', '-r', '-c', (Get-PlatformPathArgument -Platform $platform -Path $dryRunLayout.ManifestPath))
        if ($platform -eq 'windows') {
            $dryRunPrefix = Initialize-TemporaryPrefixDirectory
            $null = Initialize-WindowsMarkedToolDirectory -PrefixPath $dryRunPrefix
            $dryRunArguments += @('-p', $dryRunPrefix)
        }

        $dryRunResult = Invoke-IsolatedToolScript -Platform $platform -Layout $dryRunLayout -Arguments $dryRunArguments
        Test-ExitCode -Name "REMOVE-012 ${platform}: dry-run remove exits zero" -Result $dryRunResult -ExpectedExitCode 0
        Test-ResultText -Name "REMOVE-012 ${platform}: dry-run remove status" -Result $dryRunResult -ExpectedText 'DryRun'

        $unsupportedResult = Invoke-DirectCliCase `
            -Platform $platform `
            -ManifestContent (Get-UnavailableManifestContent) `
            -Arguments @('-r')
        Test-ExitCode `
            -Name "REMOVE-014 ${platform}: unsupported platform remove exits zero" `
            -Result $unsupportedResult `
            -ExpectedExitCode 0
        Test-ResultText `
            -Name "REMOVE-014 ${platform}: unsupported platform remove skipped" `
            -Result $unsupportedResult `
            -ExpectedText 'Skipped'

        $outsidePrefix = if ($platform -eq 'windows') { 'C:\Windows' } else { '/usr' }
        $outsideLayout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
        $outsideConfigPath = Get-PlatformPathArgument -Platform $platform -Path $outsideLayout.ManifestPath
        $outsideResult = Invoke-IsolatedToolScript `
            -Platform $platform `
            -Layout $outsideLayout `
            -Arguments @('-r', '-c', $outsideConfigPath, '-p', $outsidePrefix)
        Test-NonzeroExitCode -Name "REMOVE-008 ${platform}: outside-root prefix refused" -Result $outsideResult
        Test-ResultText `
            -Name "REMOVE-008 ${platform}: outside-root prefix diagnostic" `
            -Result $outsideResult `
            -ExpectedText '--prefix must point inside'
    }
}

function Test-WindowsWhatIfRemove {
    $layout = Initialize-IsolatedScriptLayout -ManifestContent (Get-DirectBinaryManifestContent)
    $prefixPath = Initialize-TemporaryPrefixDirectory
    $toolDirectory = Initialize-WindowsMarkedToolDirectory -PrefixPath $prefixPath
    $result = Invoke-IsolatedToolScript `
        -Platform 'windows' `
        -Layout $layout `
        -Arguments @('-r', '-WhatIf', '-c', $layout.ManifestPath, '-p', $prefixPath)

    Test-ExitCode -Name 'REMOVE-015 windows: WhatIf removal exits zero' -Result $result -ExpectedExitCode 0
    Test-ResultText -Name 'REMOVE-015 windows: WhatIf removal skipped' -Result $result -ExpectedText 'Skipped'
    Test-CheckCondition `
        -Name 'REMOVE-015 windows: WhatIf directory remains' `
        -Condition (Test-Path -LiteralPath $toolDirectory) `
        -FailureDetail 'WhatIf removed the marked directory.'
}

function Test-DirectRemoval {
    Test-WindowsRemoveMarkedDirectory
    Test-LinuxRemoveMarkedDirectory
    Test-WindowsRemoveRefusal
    Test-LinuxRemoveUnmanagedCommand
    Test-LinuxRemoveObsoletePathEntry
    Test-RemoveDryRunUnsupportedAndPrefix
    Test-WindowsWhatIfRemove
}

function Invoke-MarkdownFallback {
    $markdownFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.md' -File)
    $hasError = $false
    foreach ($markdownFile in $markdownFiles) {
        $lines = [IO.File]::ReadAllLines($markdownFile.FullName)
        $fenceCount = 0
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex] -match '\s+$') {
                Register-CheckResult `
                    -Name "Markdown fallback: $($markdownFile.Name)" `
                    -Passed $false `
                    -Detail "Trailing whitespace at line $($lineIndex + 1)."
                $hasError = $true
            }

            if ($lines[$lineIndex] -match '^\s*```') {
                $fenceCount++
            }
        }

        if ($fenceCount % 2 -ne 0) {
            Register-CheckResult `
                -Name "Markdown fallback: $($markdownFile.Name)" `
                -Passed $false `
                -Detail 'Unclosed fenced code block.'
            $hasError = $true
        }
    }

    Register-CheckResult `
        -Name 'Markdown fallback checks' `
        -Passed (-not $hasError) `
        -Detail 'Fallback found Markdown syntax issues.'
}

function Invoke-YamlFallback {
    $yamlFiles = @(
        Get-RepositoryPath -RelativePath '.yamllint'
        Get-RepositoryPath -RelativePath '.markdownlint-cli2.yaml'
        Get-RepositoryPath -RelativePath 'config/tools.yaml'
        Get-RepositoryPath -RelativePath '.github/workflows/validation.yml'
        Get-RepositoryPath -RelativePath '.github/dependabot.yml'
    )
    $hasError = $false
    foreach ($yamlFile in $yamlFiles) {
        $lines = [IO.File]::ReadAllLines($yamlFile)
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex] -match "`t") {
                Register-CheckResult `
                    -Name "YAML fallback: $(Split-Path -Leaf $yamlFile)" `
                    -Passed $false `
                    -Detail "Tab indentation at line $($lineIndex + 1)."
                $hasError = $true
            }

            if ($lines[$lineIndex] -match '\s+$') {
                Register-CheckResult `
                    -Name "YAML fallback: $(Split-Path -Leaf $yamlFile)" `
                    -Passed $false `
                    -Detail "Trailing whitespace at line $($lineIndex + 1)."
                $hasError = $true
            }
        }
    }

    $null = Get-ManifestTool
    Register-CheckResult `
        -Name 'YAML fallback checks' `
        -Passed (-not $hasError) `
        -Detail 'Fallback found YAML formatting issues.'
}

function Invoke-PowerShellParserCheck {
    foreach ($relativePath in @('scripts/install-tools.ps1', 'tests/test-plan.ps1', 'tests/generate-combination-inventory.ps1')) {
        $tokens = $null
        $errors = $null
        $scriptPath = Get-RepositoryPath -RelativePath $relativePath
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        ) > $null

        $detail = ($errors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
        Register-CheckResult `
            -Name "STATIC-005 PowerShell parser: $relativePath" `
            -Passed ($errors.Count -eq 0) `
            -Detail $detail
    }
}

function Invoke-ScriptAnalyzerCheck {
    $scriptAnalyzer = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue
    if ($null -eq $scriptAnalyzer) {
        Register-CheckWarning 'STATIC-006 skipped because Invoke-ScriptAnalyzer is unavailable; parser check is fallback.'
        return
    }

    foreach ($relativePath in @('scripts/install-tools.ps1', 'tests/test-plan.ps1', 'tests/generate-combination-inventory.ps1')) {
        $scriptPath = Get-RepositoryPath -RelativePath $relativePath
        $findings = @(Invoke-ScriptAnalyzer -Path $scriptPath)
        $detail = ($findings | ForEach-Object { "$($_.RuleName): $($_.Message)" }) -join [Environment]::NewLine
        Register-CheckResult `
            -Name "STATIC-006 PSScriptAnalyzer: $relativePath" `
            -Passed ($findings.Count -eq 0) `
            -Detail $detail
    }
}

function Get-ManifestTool {
    $manifestPath = Get-RepositoryPath -RelativePath 'config/tools.yaml'
    $tools = [System.Collections.Generic.List[object]]::new()
    $currentTool = $null
    $currentPlatform = ''

    foreach ($rawLine in [IO.File]::ReadLines($manifestPath)) {
        $line = $rawLine.TrimEnd()
        if ($line -match '^  - id:\s*(.+)$') {
            $currentTool = [ordered]@{
                Id = ConvertFrom-ManifestScalar -Value $matches[1]
                WindowsKind = ''
                LinuxKind = ''
            }
            $tools.Add([pscustomobject]$currentTool)
            $currentPlatform = ''
            continue
        }

        if ($null -eq $currentTool) {
            continue
        }

        if ($line -match '^      (windows|linux):\s*$') {
            $currentPlatform = $matches[1]
            continue
        }

        if ($line -match '^        kind:\s*(.+)$') {
            $kind = ConvertFrom-ManifestScalar -Value $matches[1]
            if ($currentPlatform -eq 'windows') {
                $tools[$tools.Count - 1].WindowsKind = $kind
            } elseif ($currentPlatform -eq 'linux') {
                $tools[$tools.Count - 1].LinuxKind = $kind
            }
        }
    }

    return $tools.ToArray()
}

function Get-ManifestInstaller {
    $manifestPath = Get-RepositoryPath -RelativePath 'config/tools.yaml'
    $installers = [System.Collections.Generic.List[object]]::new()
    $currentToolId = ''
    $currentInstaller = $null

    foreach ($rawLine in [IO.File]::ReadLines($manifestPath)) {
        $line = $rawLine.TrimEnd()
        if ($line -match '^  - id:\s*(.+)$') {
            $currentToolId = ConvertFrom-ManifestScalar -Value $matches[1]
            $currentInstaller = $null
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentToolId)) {
            continue
        }

        if ($line -match '^      (windows|linux):\s*$') {
            $currentInstaller = [ordered]@{
                ToolId = $currentToolId
                Platform = $matches[1]
                Kind = ''
                Url = ''
                ReleaseTag = ''
                Sha256 = ''
            }
            $installers.Add([pscustomobject]$currentInstaller)
            continue
        }

        if ($null -eq $currentInstaller) {
            continue
        }

        if ($line -match '^        (kind|url|release_tag|sha256):\s*(.+)$') {
            $key = $matches[1]
            $value = ConvertFrom-ManifestScalar -Value $matches[2]
            switch ($key) {
                'kind' { $installers[$installers.Count - 1].Kind = $value }
                'url' { $installers[$installers.Count - 1].Url = $value }
                'release_tag' { $installers[$installers.Count - 1].ReleaseTag = $value }
                'sha256' { $installers[$installers.Count - 1].Sha256 = $value }
            }
        }
    }

    return $installers.ToArray()
}

function Get-TestPlanToolCoverage {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $coverageRows = [System.Collections.Generic.List[object]]::new()
    $pattern = '^\| `(?<Id>TOOL-\d{3})` \| `(?<Tool>[^`]+)` \| `(?<Windows>[^`]+)` \| `(?<Linux>[^`]+)` \| (?<Coverage>.+) \|$'
    foreach ($line in $testPlanText -split '\r?\n') {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }

        $coverageRows.Add([pscustomobject]@{
            Id = $match.Groups['Id'].Value
            Tool = $match.Groups['Tool'].Value
            WindowsKind = $match.Groups['Windows'].Value
            LinuxKind = $match.Groups['Linux'].Value
            RequiredCoverage = $match.Groups['Coverage'].Value
        })
    }

    return $coverageRows.ToArray()
}

function Get-ExpectedInstallerCoverageId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $coverageByKind = @{
        'appimage_extract' = @('DISPATCH-013')
        'brew' = @('DISPATCH-006')
        'chocolatey' = @('DISPATCH-008')
        'conda_forge' = @('DISPATCH-016')
        'direct_binary' = @('DISPATCH-009')
        'direct_installer' = @('DISPATCH-012')
        'github_release_asset' = @('DISPATCH-010')
        'npm_global' = @('DISPATCH-004')
        'pip' = @('DISPATCH-001')
        'portable_archive' = @('DISPATCH-011')
        'powershell_gallery' = @('DISPATCH-005')
        'python_user' = @('DISPATCH-002')
        'source_make' = @('DISPATCH-014')
        'unavailable' = @('MANIFEST-009', 'INSTALL-007')
        'uv_tool' = @('DISPATCH-003')
        'winget' = @('DISPATCH-007')
    }

    if (-not $coverageByKind.ContainsKey($Kind)) {
        return @()
    }

    return @($coverageByKind[$Kind])
}

function Get-TestPlanInstallerVerificationStrategy {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $strategies = @{}
    $pattern = '^\| `(?<Kind>[a-z_]+)` \| `(?<Strategy>[^`]+)` \|$'
    foreach ($line in $testPlanText -split '\r?\n') {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }

        $strategies[$match.Groups['Kind'].Value] = $match.Groups['Strategy'].Value
    }

    return $strategies
}

function Get-TestPlanId {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($testPlanText, '`([A-Z]+-\d{3})`')) {
        $null = $ids.Add($match.Groups[1].Value)
    }

    return $ids
}

function Expand-TestIdReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rangeMatch in [regex]::Matches($Text, '`([A-Z]+)-(\d{3})`\s+through\s+`\1-(\d{3})`')) {
        $prefix = $rangeMatch.Groups[1].Value
        $start = [int]$rangeMatch.Groups[2].Value
        $end = [int]$rangeMatch.Groups[3].Value
        for ($index = $start; $index -le $end; $index++) {
            $null = $ids.Add(('{0}-{1:D3}' -f $prefix, $index))
        }
    }

    foreach ($idMatch in [regex]::Matches($Text, '`([A-Z]+-\d{3})`')) {
        $null = $ids.Add($idMatch.Groups[1].Value)
    }

    return @($ids)
}

function Test-CombinationModel {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $section = Get-RegexMatchValue `
        -Text $testPlanText `
        -Pattern '## Combination Model(?<Section>.*?)## Combination Inventory Template' `
        -GroupName 'Section'
    $expectedAxes = @(
        'Platform',
        'Execution identity',
        'Command mode',
        'Option form',
        'PowerShell common option',
        'Verbose flag',
        'Dry-run flag',
        'Check-path flag',
        'Config path',
        'Tool entry shape',
        'Prefix',
        'Filesystem boundary',
        'Tool availability',
        'Installer kind',
        'Archive shape',
        'Download or release lookup',
        'Published command state',
        'Removal state',
        'Expected result'
    )

    foreach ($axis in $expectedAxes) {
        $axisPattern = "(?m)^\| $([regex]::Escape($axis)) \| (?<Values>[^|]+) \|"
        $axisMatch = [regex]::Match($section, $axisPattern)
        Test-CheckCondition `
            -Name "MATRIX-001 axis: $axis" `
            -Condition ($axisMatch.Success -and -not [string]::IsNullOrWhiteSpace($axisMatch.Groups['Values'].Value)) `
            -FailureDetail 'Missing axis or empty value list.'
    }

    $coverageContractPresent = $section -match 'direct_test' -and
        $section -match 'equivalent:<test-id>' -and
        $section -match 'invalid:<reason>' -and
        $section -match 'not_applicable:<reason>'
    Test-CheckCondition `
        -Name 'MATRIX-003 accepted coverage statuses documented' `
        -Condition $coverageContractPresent `
        -FailureDetail 'Coverage contract does not list every accepted status form.'

    $generatedInventoryBoundaryPresent = $testPlanText -match
        'without requiring\s+routine runs to persist or exhaustively validate every generated row'
    Test-CheckCondition `
        -Name 'MATRIX-005 generated inventory boundary documented' `
        -Condition $generatedInventoryBoundaryPresent `
        -FailureDetail 'TEST_PLAN.md claims or omits the generated inventory boundary.'
}

function Test-InventoryTemplate {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $section = Get-RegexMatchValue `
        -Text $testPlanText `
        -Pattern '## Combination Inventory Template(?<Section>.*?)## Required Direct Tests' `
        -GroupName 'Section'
    $expectedColumns = @(
        'ID',
        'Platform',
        'Mode',
        'Options',
        'Config',
        'Prefix',
        'Tool State',
        'Installer',
        'File State',
        'Expected',
        'Coverage'
    )
    $headerPattern = '\| ' + (($expectedColumns | ForEach-Object { [regex]::Escape($_) }) -join ' \| ') + ' \|'
    Test-CheckCondition `
        -Name 'MATRIX-002 inventory template columns' `
        -Condition ([regex]::IsMatch($section, $headerPattern)) `
        -FailureDetail 'Combination inventory template does not expose the required columns.'
    Test-CheckCondition `
        -Name 'MATRIX-003 example coverage status' `
        -Condition ($section -match '\| `MATRIX-EXAMPLE` .* \| `direct_test` \|') `
        -FailureDetail 'Inventory example does not use an accepted Coverage value.'
}

function Test-GeneratedInventory {
    $relativePath = 'tests/generate-combination-inventory.ps1'
    $generatorPath = Get-RepositoryPath -RelativePath $relativePath
    $generatorExists = Test-Path -LiteralPath $generatorPath -PathType Leaf
    Test-CheckCondition `
        -Name 'MATRIX-007 generator exists' `
        -Condition $generatorExists `
        -FailureDetail 'The generated matrix inventory script is missing.'

    if (-not $generatorExists) {
        return
    }

    $powerShellCommand = Get-PowerShellCommandName
    $countResult = Invoke-CommandCapture `
        -Command $powerShellCommand `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $generatorPath, '-CountOnly')
    Test-ExitCode `
        -Name 'MATRIX-007 generator count exits zero' `
        -Result $countResult `
        -ExpectedExitCode 0

    [long]$combinationCount = 0
    $countText = $countResult.Output.Trim()
    $countParsed = [long]::TryParse($countText, [ref]$combinationCount)
    Test-CheckCondition `
        -Name 'MATRIX-007 generator count is positive' `
        -Condition ($countParsed -and $combinationCount -gt 0) `
        -FailureDetail "Generator count output was not a positive integer: '$countText'."

    $inventoryResult = Invoke-CommandCapture `
        -Command $powerShellCommand `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $generatorPath, '-Limit', '2')
    Test-ExitCode `
        -Name 'MATRIX-007 generator sample exits zero' `
        -Result $inventoryResult `
        -ExpectedExitCode 0

    $lines = @($inventoryResult.Output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Test-CheckCondition `
        -Name 'MATRIX-007 generated line count' `
        -Condition ($lines.Count -eq 3) `
        -FailureDetail "Expected one header and two rows, but got $($lines.Count) lines."

    if ($lines.Count -lt 2) {
        return
    }

    $rows = @($lines | ConvertFrom-Csv)
    $expectedColumns = @(
        'ID',
        'Platform',
        'Mode',
        'Options',
        'Config',
        'Prefix',
        'Tool State',
        'Installer',
        'File State',
        'Expected',
        'Coverage'
    )
    $actualColumns = @($rows[0].PSObject.Properties.Name)
    $missingColumns = @($expectedColumns | Where-Object { $actualColumns -notcontains $_ })
    Test-CheckCondition `
        -Name 'MATRIX-007 generated columns' `
        -Condition ($missingColumns.Count -eq 0) `
        -FailureDetail "Generated CSV is missing columns: $($missingColumns -join ', ')."

    $rowShapeValid = $rows.Count -eq 2 -and
        $rows[0].ID -eq 'MATRIX-GEN-000000000001' -and
        $rows[1].ID -eq 'MATRIX-GEN-000000000002' -and
        -not [string]::IsNullOrWhiteSpace($rows[0].Platform) -and
        -not [string]::IsNullOrWhiteSpace($rows[0].Coverage)
    Test-CheckCondition `
        -Name 'MATRIX-007 generated row shape' `
        -Condition $rowShapeValid `
        -FailureDetail 'Generated rows do not use stable IDs or required values.'

    $invalidCoverageRows = @($rows | Where-Object { $_.Coverage -notmatch '^not_applicable:.+' })
    Test-CheckCondition `
        -Name 'MATRIX-007 generated coverage status' `
        -Condition ($invalidCoverageRows.Count -eq 0) `
        -FailureDetail 'Generated rows do not use an accepted placeholder Coverage status.'
}

function Test-ReferenceIntegrity {
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'
    $knownIds = Get-TestPlanId
    $referencedIds = Expand-TestIdReference -Text $testPlanText
    foreach ($referencedId in $referencedIds) {
        Test-CheckCondition `
            -Name "MATRIX-004 reference: $referencedId" `
            -Condition ($knownIds.Contains($referencedId)) `
            -FailureDetail 'Referenced test ID is not defined in TEST_PLAN.md.'
    }
}

function Test-CanonicalManifestCoverage {
    $manifestTools = @(Get-ManifestTool)
    $coverageRows = @(Get-TestPlanToolCoverage)
    Test-CheckCondition `
        -Name 'MATRIX-006 canonical tool count' `
        -Condition ($manifestTools.Count -eq $coverageRows.Count) `
        -FailureDetail "Manifest has $($manifestTools.Count) tools but TEST_PLAN.md covers $($coverageRows.Count)."

    $tsxIndex = [array]::FindIndex($manifestTools, [Predicate[object]] { param($tool) $tool.Id -eq 'tsx' })
    $localActionIndex = [array]::FindIndex($manifestTools, [Predicate[object]] { param($tool) $tool.Id -eq 'local-action' })
    Test-CheckCondition `
        -Name 'TOOL order: tsx before local-action' `
        -Condition ($tsxIndex -ge 0 -and $localActionIndex -ge 0 -and $tsxIndex -lt $localActionIndex) `
        -FailureDetail 'local-action requires the tsx command to be available before its version check runs.'

    foreach ($tool in $manifestTools) {
        $matchingRows = @($coverageRows | Where-Object { $_.Tool -eq $tool.Id })
        Test-CheckCondition `
            -Name "TOOL coverage row: $($tool.Id)" `
            -Condition ($matchingRows.Count -eq 1) `
            -FailureDetail 'Canonical tool must have exactly one TOOL-* coverage row.'

        if ($matchingRows.Count -ne 1) {
            continue
        }

        $row = $matchingRows[0]
        $windowsKind = if ([string]::IsNullOrWhiteSpace($tool.WindowsKind)) { 'unavailable' } else { $tool.WindowsKind }
        $linuxKind = if ([string]::IsNullOrWhiteSpace($tool.LinuxKind)) { 'unavailable' } else { $tool.LinuxKind }
        Test-CheckCondition `
            -Name "TOOL Windows kind: $($tool.Id)" `
            -Condition ($row.WindowsKind -eq $windowsKind) `
            -FailureDetail "Expected '$windowsKind' but TEST_PLAN.md says '$($row.WindowsKind)'."
        Test-CheckCondition `
            -Name "TOOL Linux kind: $($tool.Id)" `
            -Condition ($row.LinuxKind -eq $linuxKind) `
            -FailureDetail "Expected '$linuxKind' but TEST_PLAN.md says '$($row.LinuxKind)'."

        $coverageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($coverageId in (Expand-TestIdReference -Text $row.RequiredCoverage)) {
            $null = $coverageIds.Add($coverageId)
        }

        foreach ($kind in @($windowsKind, $linuxKind) | Sort-Object -Unique) {
            $expectedCoverageIds = @(Get-ExpectedInstallerCoverageId -Kind $kind)
            Test-CheckCondition `
                -Name "TOOL expected coverage kind: $($tool.Id) $kind" `
                -Condition ($expectedCoverageIds.Count -gt 0) `
                -FailureDetail "Installer kind '$kind' has no MATRIX-006 coverage mapping."

            foreach ($expectedCoverageId in $expectedCoverageIds) {
                Test-CheckCondition `
                    -Name "TOOL coverage reference: $($tool.Id) $expectedCoverageId" `
                    -Condition ($coverageIds.Contains($expectedCoverageId)) `
                    -FailureDetail "TEST_PLAN.md must reference '$expectedCoverageId' for installer kind '$kind'."
            }
        }
    }
}

function Test-SupplyChainVerificationContract {
    $strategies = Get-TestPlanInstallerVerificationStrategy
    $allowedStrategies = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($strategy in @('trusted_upstream', 'checksum', 'signature')) {
        $null = $allowedStrategies.Add($strategy)
    }

    foreach ($documentedKind in $strategies.Keys) {
        Test-CheckCondition `
            -Name "SUPPLY-001 strategy value: $documentedKind" `
            -Condition ($allowedStrategies.Contains($strategies[$documentedKind])) `
            -FailureDetail "Installer kind '$documentedKind' has unsupported strategy '$($strategies[$documentedKind])'."
    }

    $manifestKinds = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tool in (Get-ManifestTool)) {
        foreach ($kind in @($tool.WindowsKind, $tool.LinuxKind)) {
            if ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'unavailable') {
                continue
            }

            $null = $manifestKinds.Add($kind)
        }
    }

    foreach ($kind in $manifestKinds) {
        Test-CheckCondition `
            -Name "SUPPLY-001 strategy documented: $kind" `
            -Condition ($strategies.ContainsKey($kind)) `
            -FailureDetail "Canonical installer kind '$kind' has no verification strategy."
    }

    $artifactKinds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($kind in @('appimage_extract', 'direct_binary', 'direct_installer', 'github_release_asset', 'portable_archive', 'source_make')) {
        $null = $artifactKinds.Add($kind)
    }

    foreach ($installer in (Get-ManifestInstaller)) {
        if ([string]::IsNullOrWhiteSpace($installer.Kind) -or -not $artifactKinds.Contains($installer.Kind)) {
            continue
        }

        Test-CheckCondition `
            -Name "SUPPLY-002 checksum present: $($installer.ToolId) $($installer.Platform)" `
            -Condition ($installer.Sha256 -match '^[0-9a-fA-F]{64}$') `
            -FailureDetail 'Schema v2 artifact installers must define a 64-character SHA256.'

        $hasFixedSelector = (-not [string]::IsNullOrWhiteSpace($installer.Url)) -or
            (-not [string]::IsNullOrWhiteSpace($installer.ReleaseTag))
        Test-CheckCondition `
            -Name "SUPPLY-003 fixed selector present: $($installer.ToolId) $($installer.Platform)" `
            -Condition $hasFixedSelector `
            -FailureDetail 'Artifact installers must pin either url or release_tag.'

        foreach ($selector in @($installer.Url, $installer.ReleaseTag)) {
            if ([string]::IsNullOrWhiteSpace($selector)) {
                continue
            }

            Test-CheckCondition `
                -Name "SUPPLY-003 no moving selector: $($installer.ToolId) $($installer.Platform)" `
                -Condition ($selector -notmatch '(^|/)(latest|stable|master)(/|$)') `
                -FailureDetail "Artifact selector '$selector' must not use latest, stable, or master."
        }

        if ($installer.Kind -eq 'github_release_asset') {
            Test-CheckCondition `
                -Name "SUPPLY-003 release tag present: $($installer.ToolId) $($installer.Platform)" `
                -Condition (-not [string]::IsNullOrWhiteSpace($installer.ReleaseTag)) `
                -FailureDetail 'GitHub release assets must pin release_tag.'
        }
    }
}

function Test-DocumentationConsistency {
    $readmeText = Get-RepositoryText -RelativePath 'README.md'
    $windowsScriptText = Get-RepositoryText -RelativePath 'scripts/install-tools.ps1'
    $linuxScriptText = Get-RepositoryText -RelativePath 'scripts/install-tools.sh'
    $testPlanText = Get-RepositoryText -RelativePath 'TEST_PLAN.md'

    $expectedOptions = @(
        '-v',
        '--verbose',
        '-d',
        '--dry-run',
        '-c',
        '--config',
        '-p',
        '--prefix',
        '--check-path',
        '-r',
        '--remove',
        '-h',
        '--help'
    )
    foreach ($option in $expectedOptions) {
        $markdownOption = '`' + $option + '`'
        $markdownOptionWithValue = '`' + $option + ' '
        $readmeHasOption = $readmeText.Contains($markdownOption) -or
            $readmeText.Contains($markdownOptionWithValue)
        Test-CheckCondition `
            -Name "DOC-001 README option: $option" `
            -Condition $readmeHasOption `
            -FailureDetail 'README.md does not document this public option.'
        Test-CheckCondition `
            -Name "DOC-001 Windows option: $option" `
            -Condition ($windowsScriptText.Contains($option)) `
            -FailureDetail 'Windows installer script does not expose this option text.'
        Test-CheckCondition `
            -Name "DOC-001 Linux option: $option" `
            -Condition ($linuxScriptText.Contains($option)) `
            -FailureDetail 'Linux installer script does not expose this option text.'
    }

    $installerParagraph = Get-RegexMatchValue `
        -Text $readmeText `
        -Pattern 'Supported installer kinds are (?<Kinds>.*?)\.' `
        -GroupName 'Kinds'
    $readmeKinds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($kindMatch in [regex]::Matches($installerParagraph, '`([a-z_]+)`')) {
        $null = $readmeKinds.Add($kindMatch.Groups[1].Value)
    }

    $manifestKinds = @(Get-ManifestTool |
        ForEach-Object { $_.WindowsKind; $_.LinuxKind } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    foreach ($kind in $manifestKinds) {
        Test-CheckCondition `
            -Name "DOC-002 README installer kind: $kind" `
            -Condition ($readmeKinds.Contains($kind)) `
            -FailureDetail 'README.md installer-kind list omits a manifest kind.'
    }

    foreach ($kind in $readmeKinds) {
        $singleQuotedKind = "'$kind'"
        $doubleQuotedKind = [char]34 + $kind + [char]34
        $markdownKind = '`' + $kind + '`'
        $scriptMentionsKind = $windowsScriptText.Contains($singleQuotedKind) -or
            $windowsScriptText.Contains($doubleQuotedKind) -or
            $linuxScriptText.Contains($singleQuotedKind) -or
            $linuxScriptText.Contains($doubleQuotedKind)
        Test-CheckCondition `
            -Name "DOC-002 dispatch mention: $kind" `
            -Condition $scriptMentionsKind `
            -FailureDetail 'No platform script mentions this documented installer kind.'
        Test-CheckCondition `
            -Name "DOC-002 test-plan dispatch: $kind" `
            -Condition ($testPlanText.Contains($markdownKind)) `
            -FailureDetail 'TEST_PLAN.md does not cover this documented installer kind.'
    }

    foreach ($pathTestId in @('PATH-001', 'PATH-002', 'PATH-003', 'PATH-004', 'REMOVE-003')) {
        $markdownTestId = '`' + $pathTestId + '`'
        Test-CheckCondition `
            -Name "DOC default/removal coverage: $pathTestId" `
            -Condition ($testPlanText.Contains($markdownTestId)) `
            -FailureDetail 'TEST_PLAN.md is missing a path or removal coverage anchor required by README.md.'
    }
}

function Invoke-StaticCheck {
    Invoke-ExternalCheck `
        -Name 'STATIC-001 Markdown lint' `
        -Command 'markdownlint-cli2' `
        -Arguments @('**/*.md') `
        -Fallback { Invoke-MarkdownFallback }
    Invoke-ExternalCheck `
        -Name 'STATIC-002 YAML lint' `
        -Command 'yamllint' `
        -Arguments @(
            '.yamllint'
            '.markdownlint-cli2.yaml'
            'config/tools.yaml'
            '.github/workflows/validation.yml'
            '.github/dependabot.yml'
        ) `
        -Fallback { Invoke-YamlFallback }
    Invoke-ExternalCheck `
        -Name 'STATIC-008 EditorConfig check' `
        -Command 'editorconfig-checker' `
        -Arguments @('.') `
        -Fallback {
            Register-CheckWarning 'EditorConfig fallback is limited to git diff --check.'
            Invoke-ExternalCheck `
                -Name 'STATIC-008 fallback whitespace check' `
                -Command 'git' `
                -Arguments @('diff', '--check')
        }
    Invoke-ExternalCheck `
        -Name 'STATIC-003 Bash syntax' `
        -Command 'bash' `
        -Arguments @('-n', 'scripts/install-tools.sh')
    Invoke-ExternalCheck `
        -Name 'STATIC-007 shfmt' `
        -Command 'shfmt' `
        -Arguments @('-d', '-i', '2', 'scripts/install-tools.sh') `
        -Fallback {
            Register-CheckWarning 'shfmt fallback is limited to preserving the current Bash style.'
        }
    Invoke-ExternalCheck `
        -Name 'STATIC-004 ShellCheck' `
        -Command 'shellcheck' `
        -Arguments @('scripts/install-tools.sh') `
        -Fallback {
            Register-CheckWarning 'ShellCheck fallback is limited to bash -n.'
            Invoke-ExternalCheck `
                -Name 'STATIC-004 fallback Bash syntax' `
                -Command 'bash' `
                -Arguments @('-n', 'scripts/install-tools.sh')
        }
    Invoke-PowerShellParserCheck
    Invoke-ScriptAnalyzerCheck
}

function Invoke-TestPlanCheck {
    $sections = [ordered]@{
        'Static and structural checks' = @(
            { Invoke-StaticCheck }
            { Test-CombinationModel }
            { Test-InventoryTemplate }
            { Test-GeneratedInventory }
            { Test-ReferenceIntegrity }
            { Test-CanonicalManifestCoverage }
            { Test-SupplyChainVerificationContract }
            { Test-DocumentationConsistency }
        )
        'Script parser checks' = @(
            { Test-DirectCliParsing }
            { Test-DirectManifestParsing }
        )
        'Installer behavior checks' = @(
            { Test-DirectDispatchAndInstall }
        )
        'Removal behavior checks' = @(
            { Test-DirectRemoval }
        )
    }

    foreach ($section in $sections.GetEnumerator()) {
        foreach ($check in $section.Value) {
            & $check
        }
    }

    Write-Output ''
    Write-Output "Checks run: $Script:CheckCount"
    Write-Output "Warnings: $($Script:Warnings.Count)"
    Write-Output "Failures: $($Script:Failures.Count)"

    if ($Script:Warnings.Count -gt 0) {
        Write-Output ''
        Write-Output 'Warnings:'
        foreach ($warning in $Script:Warnings) {
            Write-Output "  $warning"
        }
    }

    if ($Script:Failures.Count -gt 0) {
        Write-Output ''
        Write-Output 'Failures:'
        foreach ($failure in $Script:Failures) {
            Write-Output "  $failure"
        }
        $Script:ExitCode = 1
    }
}

Push-Location -LiteralPath $RepoRoot
try {
    Invoke-TestPlanCheck
} finally {
    Pop-Location
    Clear-RuntimeDirectory
}
exit $Script:ExitCode
