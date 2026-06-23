<#
.SYNOPSIS
Generates the combination inventory described by TEST_PLAN.md.

.DESCRIPTION
The generator reads the Combination Model table from TEST_PLAN.md and emits a
CSV inventory that uses the documented Combination Inventory Template columns.
Routine validation calls it with a small -Limit and -CountOnly so the repository
does not need to store or exhaustively print the full cartesian matrix.
#>
[CmdletBinding()]
param(
    [string]$TestPlanPath = '',

    [ValidateRange(1, 10000)]
    [int]$Limit = 50,

    [switch]$All,

    [switch]$CountOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TestPlanPath)) {
    $scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    } else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $TestPlanPath = Join-Path -Path (Split-Path -Parent $scriptDirectory) -ChildPath 'TEST_PLAN.md'
}
function ConvertFrom-MarkdownValueList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ValueCell
    )

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($rawValue in ($ValueCell -split ',')) {
        $value = ($rawValue -replace '`', '').Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $values.Add($value)
    }

    return $values.ToArray()
}

function Get-CombinationAxis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $testPlanText = [IO.File]::ReadAllText($resolvedPath)
    $sectionMatch = [regex]::Match(
        $testPlanText,
        '## Combination Model(?<Section>.*?)## Combination Inventory Template',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $sectionMatch.Success) {
        throw 'Could not find the Combination Model section in TEST_PLAN.md.'
    }

    $axes = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($sectionMatch.Groups['Section'].Value -split '\r?\n')) {
        $rowMatch = [regex]::Match($line, '^\| (?<Axis>[^|]+) \| (?<Values>[^|]+) \|')
        if (-not $rowMatch.Success) {
            continue
        }

        $axisName = $rowMatch.Groups['Axis'].Value.Trim()
        if ($axisName -eq 'Axis' -or $axisName -match '^-+$') {
            continue
        }

        $values = @(ConvertFrom-MarkdownValueList -ValueCell $rowMatch.Groups['Values'].Value)
        if ($values.Count -eq 0) {
            throw "Combination axis '$axisName' has no values."
        }

        $axes.Add([pscustomobject]@{
            Name = $axisName
            Values = $values
        })
    }

    if ($axes.Count -eq 0) {
        throw 'Combination Model does not define any axes.'
    }

    return $axes.ToArray()
}

function Get-ProductCount {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Axis
    )

    [long]$count = 1
    foreach ($axis in $Axis) {
        $count *= [long]$axis.Values.Count
    }

    return $count
}

function ConvertTo-CsvField {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = [string]$Value
    if ($text -match '[,"\r\n]') {
        return '"' + $text.Replace('"', '""') + '"'
    }

    return $text
}

function ConvertTo-CsvLine {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Value
    )

    return (($Value | ForEach-Object { ConvertTo-CsvField -Value $_ }) -join ',')
}

function Get-AxisValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Selection,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Selection.ContainsKey($Name)) {
        throw "Generated combination is missing axis '$Name'."
    }

    return $Selection[$Name]
}

function Get-InventoryRow {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Selection,

        [Parameter(Mandatory = $true)]
        [long]$Ordinal
    )

    $options = @(
        "identity=$(Get-AxisValue -Selection $Selection -Name 'Execution identity')"
        "option=$(Get-AxisValue -Selection $Selection -Name 'Option form')"
        "powershell=$(Get-AxisValue -Selection $Selection -Name 'PowerShell common option')"
        "verbose=$(Get-AxisValue -Selection $Selection -Name 'Verbose flag')"
        "dry_run=$(Get-AxisValue -Selection $Selection -Name 'Dry-run flag')"
        "check_path=$(Get-AxisValue -Selection $Selection -Name 'Check-path flag')"
    ) -join '; '
    $fileState = @(
        "boundary=$(Get-AxisValue -Selection $Selection -Name 'Filesystem boundary')"
        "archive=$(Get-AxisValue -Selection $Selection -Name 'Archive shape')"
        "lookup=$(Get-AxisValue -Selection $Selection -Name 'Download or release lookup')"
        "published=$(Get-AxisValue -Selection $Selection -Name 'Published command state')"
        "removal=$(Get-AxisValue -Selection $Selection -Name 'Removal state')"
    ) -join '; '

    return [ordered]@{
        ID = 'MATRIX-GEN-{0:D12}' -f $Ordinal
        Platform = Get-AxisValue -Selection $Selection -Name 'Platform'
        Mode = Get-AxisValue -Selection $Selection -Name 'Command mode'
        Options = $options
        Config = Get-AxisValue -Selection $Selection -Name 'Config path'
        Prefix = Get-AxisValue -Selection $Selection -Name 'Prefix'
        'Tool State' = Get-AxisValue -Selection $Selection -Name 'Tool availability'
        Installer = Get-AxisValue -Selection $Selection -Name 'Installer kind'
        'File State' = $fileState
        Expected = Get-AxisValue -Selection $Selection -Name 'Expected result'
        Coverage = 'not_applicable:generated_inventory_candidate'
    }
}

$script:Axes = @(Get-CombinationAxis -Path $TestPlanPath)
$script:Columns = @(
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
$script:Limit = $Limit
$script:All = [bool]$All
$script:RowsWritten = [long]0
$script:Selection = @{}

$totalCount = Get-ProductCount -Axis $script:Axes
if ($CountOnly) {
    Write-Output $totalCount
    return
}

Write-Output (ConvertTo-CsvLine -Value $script:Columns)

function Write-InventoryRow {
    param(
        [Parameter(Mandatory = $true)]
        [int]$AxisIndex
    )

    if ((-not $script:All) -and $script:RowsWritten -ge $script:Limit) {
        return
    }

    if ($AxisIndex -eq $script:Axes.Count) {
        $script:RowsWritten++
        $row = Get-InventoryRow -Selection $script:Selection -Ordinal $script:RowsWritten
        $values = foreach ($column in $script:Columns) {
            $row[$column]
        }
        Write-Output (ConvertTo-CsvLine -Value @($values))
        return
    }

    $axis = $script:Axes[$AxisIndex]
    foreach ($value in $axis.Values) {
        $script:Selection[$axis.Name] = $value
        Write-InventoryRow -AxisIndex ($AxisIndex + 1)
        if ((-not $script:All) -and $script:RowsWritten -ge $script:Limit) {
            break
        }
    }

    $null = $script:Selection.Remove($axis.Name)
}

Write-InventoryRow -AxisIndex 0
